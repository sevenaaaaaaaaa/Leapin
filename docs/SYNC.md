# 设备身份与同步（P2）

> 2026-11-09。对应 docs/ROADMAP-v3.md 第 5 节 P2：设备身份 + 同步 + 只读远端面板。
> 本文写「怎么做的、为什么这样做、边界在哪」，验收数字见 docs/VERIFICATION.md `0.5。

## 0. 范围

**已交付**：Ed25519 设备身份、content-addressed 配置版本、局域网配对与签名同步、设备级 override、只读 Web 面板、tfctl 子命令、单元测试与双存储端到端脚本。

**未交付（明确不做）**：App 内同步页、自动后台同步、局域网发现（Bonjour）、云端 E2EE、设备权限 scope 的执行（记录但未强制）、iOS 客户端。P4+ 需要 Network Extension 签名，本期只做设计。

## 1. 三条不变量

1. **版本只增不改**：版本 id = 规范化 JSON 的 SHA-256；同一内容永远同一 id，写入是幂等的，不存在「覆盖」。
2. **冲突不靠合并，靠指针**：每台设备写自己的 `pointers/<device>.json`（LWW：先比 `updatedAtMs`，同毫秒再比设备 id 打破平局）。谁也不会改别人的指针。
3. **本机 override 永不外传**：用户把某台设备固定在某个版本时，只写本机 `override.json`，不参与同步。

这样做的代价是「不做三方合并」——两台设备同时改同一份配置时，较新的版本生效，旧版本仍在历史里可回滚。这是刻意选择：静默覆盖比「丢一次改动」更伤信任。

## 2. 设备身份

- 密钥：Ed25519（CryptoKit `Curve25519.Signing`），只持久化 32 字节 seed。
- 默认存登录钥匙串：service `com.touchflow.device`，account `identity.ed25519`。
- CLI/CI 无钥匙串权限时回落到 `$TF_PROFILE_ROOT/device/device.key`（目录 0700、文件 0600、原子写）；测试用内存实现，绝不碰真实钥匙串。
- `deviceID` = SHA-256(公钥) 前 16 字节的 hex（32 字符）。
- `fingerprint` = 同一摘要前 8 字节，按 4 个 hex 一组：`0b22-21b8-7708-9a61`。
- 配对时只交换**公钥**与指纹；私钥永不离开本机，也不进日志。

```bash
tfctl device               # 设备 ID / 指纹 / 名称 / 公钥
tfctl device --json
```

指纹用于带外核对（两台设备各自读屏）：配对握手本身不防「中间人替换公钥」，指纹比对是最后一道人工校验。

## 3. 版本存储

`ProfileContent` 只包含会影响行为的字段：name、general、dns、adblock、outbounds、groups、rules、ruleProviders、proxyProviders。

**排除**：profile 的本地 UUID、`sourcePath`、磁盘文件名。因此同一个订阅在英国导入与在国内导入会得到同一个版本 id；本机 UUID 由版本 id 前 32 个 hex 确定性派生（`ProfileSyncService.stableUUID`），重复 apply 不会产生重复配置。

目录（`$TF_PROFILE_ROOT/sync/`）：

| 路径 | 内容 | 权限 |
| --- | --- | --- |
| `versions/content/<sha256>.json` | 规范化配置内容 | 0600 |
| `versions/meta/<sha256>.json` | 名称、规则数、字节数、时间、来源设备、父版本 | 0600 |
| `pointers/<deviceID>.json` | 该设备当前指针（LWW） | 0600 |
| `override.json` | 本机固定版本（不同步） | 0600 |
| `applied-version` | 本机实际加载的版本 id | 0600 |
| `peers/<deviceID>.json` | 已配对设备、公钥、最近可见时间、scopes | 0600 |
| `panel-token` | 只读面板令牌 | 0600（目录 0700） |
| `device-name` | 展示名（可手改） | — |
| `device/device.key` | 钥匙串不可用时的 seed 回落 | 0600 |

Mutations：`put`（本地新版本，幂等）、`ingest`（对端版本，先重算 hash 再落盘，不匹配即拒绝）、`setPointer`（单调，旧时间戳不回退）、`merge(pointers:)`、`setOverride`。

## 4. 线路协议

明文 HTTP/1.1，局域网内，每请求一条连接（`Connection: close`）。没有 TLS：P2 的目标是「同一 WiFi 下两台自己的机器」，而不是跨公网。

| 方法 | 路径 | 鉴权 |
| --- | --- | --- |
| GET | `/v1/info` | 无（只返回公钥/名称/指纹） |
| POST | `/v1/pair` | 6 位配对码 |
| GET | `/v1/manifest` | Ed25519 签名 |
| GET | `/v1/versions/<64-hex>` | Ed25519 签名 |
| POST | `/v1/announce` | Ed25519 签名 |
| GET | `/panel`、`/panel.json` | 面板令牌（query 或 Bearer） |
| 其它方法 | `/panel*` | 405（面板只读） |

签名信封覆盖 `TF-SYNC-1\nMETHOD\nPATH\nSHA256(body)\nTIMESTAMP_MS\nNONCE`，请求头 `X-TF-Device` / `X-TF-Timestamp` / `X-TF-Nonce` / `X-TF-Signature`。服务端：

- 时间戳容差 ±300 秒（`stale_timestamp` → 401）；
- nonce 缓存 600 秒、上限 8192 条，重复即 `replay` → 409；
- 只接受 `peers/` 里已登记公钥的签名；
- 配对码 6 位、300 秒有效、只成功一次；比较为常量时间；
- 请求体上限 4 MiB，响应上限 8 MiB；announce 内联内容上限 3 MiB，超出则等对端下次 pull。

## 5. 一次收敛

`SyncClient.syncOnce()`：

1. `GET /v1/manifest` 拉对端版本元数据与指针；
2. 拉取本地缺失的版本（`/v1/versions/<id>`，逐个校验 hash）；
3. `merge` 对端指针；
4. `POST /v1/announce` 发布本地指针与版本列表；对端返回它缺的版本 id；
5. 若对端缺内容且体积在 3 MiB 内，第二次 announce 直接内联推送，并再 merge 一次指针。

因此两台设备各执行一次 `sync pull` 即可收敛；脚本实测配对 + 拉取 + 应用 **0.19 s**（阈值 5 s）。

## 6. CLI

```bash
tfctl device [--json]                          # 设备身份
tfctl sync status [--json]                     # 版本数、生效版本、已应用、已配对
tfctl sync versions                            # 全量历史（* = 来源指针，▶ = 生效）
tfctl sync record [--profile file.surge]       # 把当前/指定配置记为新版本
tfctl sync serve [--port N] [--lan] [--no-panel]   # 启动同步服务，打印端口/配对码/面板链接
tfctl sync pair <host:port> --code NNNNNN      # 首次配对（单次、5 分钟）
tfctl sync pull <host:port>                    # 拉取 + 收敛 + 自动应用生效版本
tfctl sync apply [--version <id>]              # 应用指定/生效版本
tfctl sync override <id>|--clear               # 本机固定版本 / 取消
tfctl sync peers                               # 列出已配对设备
tfctl sync unpair <id|名称>                    # 解除配对（撤销该设备签名权限）
tfctl sync panel [--rotate] [--port N] [--json]   # 只读面板链接与令牌
```

退出即停；`serve` 是前台进程，Ctrl-C 停止（SIGINT handler 保证 listener 关闭）。

## 7. 只读面板

`tfctl sync serve` 默认同时开启，`--no-panel` 关闭。

- URL：`http://<host>:<port>/panel?token=<64-hex>`；也接受 `Authorization: Bearer <token>`。
- 令牌：32 字节 CSPRNG，hex 编码；文件 `$TF_PROFILE_ROOT/sync/panel-token`（0600，目录 0700）。
- 每次请求重新读令牌文件，因此 `tfctl sync panel --rotate` **即时生效**，无需重启服务。
- 内容：设备名/ID/指纹、版本历史（id 前缀、名称、规则数、来源设备、时间、生效标记）、每台设备指针、已配对设备与最近可见时间。**不含规则、出站、DNS 配置、凭据。**
- 纯静态 HTML + 内联 CSS：无脚本、无外链、无表单；所有插值 HTML-escape；任何写方法 405。
- 风险：令牌放在 URL 里会进浏览器历史/代理日志；只读且可轮换，属于可接受的折中。面板默认只绑定 127.0.0.1，`--lan` 才绑 0.0.0.0。

## 8. 攻击面与限制

| 风险 | 现状 | 缓解 / 后续 |
| --- | --- | --- |
| 局域网明文 | 接受 | 同 WiFi 自用；跨网需 Cloud E2EE（未做） |
| 配对码爆破 | 6 位 / 300s / 单次 | 无速率限制（每次尝试都走完整握手）；后续加失败退避 |
| 公钥替换（MITM） | 配对只交换公钥 | 人工比对指纹；后续可加 SAS |
| 已配对设备被滥用 | 所有 peer 都有读写同步权 | `scopes` 已记录但未强制；P2 后续做授权 scope |
| 面板令牌泄漏 | URL/历史 | 只读、无配置内容、可即时轮换 |
| 版本内容损坏 | ingest 重算 hash | 不匹配拒绝，不会半写 |
| 无后台同步 | 手动 pull | 下一期做守护进程/菜单栏定时 |

## 9. 复现

```bash
swift build --scratch-path .build
swift test --scratch-path .build
TFCTL=.build/debug/tfctl ./scripts/sync-e2e.sh
```

`scripts/sync-e2e.sh` 用两个隔离的 `TF_PROFILE_ROOT` 建两台设备（A/B），验证：首版本、配对、5 秒内收敛、离线改动、重连推送、override、错误配对码、面板鉴权/只读/元数据。所有密钥走 0600 文件（`TF_SYNC_FILE_KEY=1`），不碰真实钥匙串。
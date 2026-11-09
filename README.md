# Leapin · 一跃

> One leap. No detour. —— 一跃即达，不必绕路。

融合 Surge / Clash 能力的 macOS 网络工具：规则分流、去广告、抓包、SSH、NAS 快速挂载、从 App 列表或截图学习分流规则，并把隐私保护做进默认行为。

> v1 为 macOS 原生 App（SwiftUI）+ 跨平台核心库（SwiftPM）。iOS 版需要 NetworkExtension 权限，暂未打包。
>
> **v1.8 起由 TouchFlow 更名为 Leapin**；旧数据目录、设备身份与 CA 会自动迁移（见 [docs/BRAND.md](docs/BRAND.md)）。

## 界面

原生 SwiftUI，单窗口 + 菜单栏常驻，浅色/深色自适应。自绘设计系统（`Sources/LeapinApp/Design/Theme.swift`）：
半透明面板 + 细发丝线、墨色阶与朱红强调、等宽数字与网络元数据；侧栏常驻运行状态与端口，
顶栏固定系统代理开关，总览页一眼看到端点、命中规则与最近连接。

- **总览**：状态 hero + 5 个指标 + 本地端点 + 分流解释器 + 最近连接
- **分流规则**：规则列表 + 策略组/出站/规则集侧栏，支持搜索与右键删除
- **去广告**：规则统计、引擎开关、命中测试、过滤列表与白名单
- **抓包**：请求列表 / 详情双栏（明文 HTTP 与命中拦截的请求都会记录）、HTTPS 解密开关、HAR 导出
- **SSH**：深色终端面板、密码经 askpass 传入、可选记住密码
- **NAS**：Bonjour 发现 + 手动主机、SMB 挂载与会话内挂载说明
- **智能学习**：粘贴 App 列表或拖入截图 → OCR → 建议规则 → 一键写入
- **隐私**：健康度评分环 + 加固清单 + 跟踪器发现
- **配置**：导入 Clash/Surge/JSON、导出、切换
- **设置**：端口 / DNS / 抓包 / 日志，保存即应用

## 功能

| 能力 | 说明 |
| --- | --- |
| 本地代理 | `127.0.0.1:7890` 混合端口（HTTP CONNECT + SOCKS5 + 普通 HTTP）；另开 `7891`（仅 HTTP）、`7892`（仅 SOCKS5），端口可在设置中改（等价 Clash/Surge 的 mixed + 独立端口） |
| 本地 DNS | `127.0.0.1:5354`（DoH/DoT/UDP 上游、hosts、正负缓存、可选 Fake-IP、广告域名直接 NXDOMAIN） |
| 规则分流 | Clash / Surge 语法；DOMAIN / DOMAIN-SUFFIX / DOMAIN-KEYWORD / DOMAIN-REGEX / IP-CIDR / GEOIP / PROCESS-NAME / RULE-SET / MATCH；`no-resolve`、策略组 select/url-test/fallback/load-balance |
| 去广告 | ABP 子集（`||domain^`、`@@` 例外、`$third-party`）+ hosts 语法 + 跟踪器名单 + cosmetic 选择器；内置起步名单，可加订阅 |
| 抓包 | HTTP 明文抓取；可选 HTTPS MITM（本地 CA + HTTP/1.1）；一键导出 HAR，敏感头自动脱敏 |
| SSH | 系统 `ssh -tt` 交互式会话；密码走 `SSH_ASKPASS` 临时脚本，可选存钥匙串 |
| NAS | Bonjour 自动发现（`_smb._tcp` 等）；SMB 挂载与 Finder 打开；凭据只进钥匙串 |
| 智能学习 | 粘贴 App 列表 / 拖入截图 → Vision OCR → 应用识别 → 生成分流规则建议，勾选应用 |
| 隐私 | DoH / DoT / Fake-IP DNS、日志与 HAR 脱敏、Keychain、隐私审计评分、系统代理一键开关 |

## 安装与运行

```bash
# 1) 构建 App 与 CLI（无需任何第三方依赖，不需要开发者账号）
./scripts/build-app.sh

# 2) 启动
open dist/Leapin.app
```

首次使用：

1. 打开 App → 总览 → **启动**。
2. 打开 **系统代理**（自动执行 `networksetup` 设置 HTTP/HTTPS/SOCKS 代理）。
3. 需要抓 HTTPS 时：设置 → 开启 **HTTPS 解密** → 总览点 **安装 CA** → 在“钥匙串访问”中把 `Leapin Root CA` 加入“系统”并设为“始终信任”（这一步必须手动确认，App 不会静默信任根证书）。
4. 不需要时随时关闭系统代理；App 退出不会留下系统代理设置（可在总览/菜单栏关闭）。

## 命令行 leapin

```bash
BIN=dist/Leapin.app/Contents/MacOS/leapin

$BIN run                       # 前台启动代理
$BIN rules api.spotify.com     # 解释命中哪条规则、走哪个出站
$BIN adblock doubleclick.net   # 检查广告拦截
$BIN dns example.com           # 用当前 DNS 配置解析
$BIN import ./my-clash.yaml    # 导入 Clash / Surge / JSON
$BIN export clash              # 导出 Clash YAML
$BIN proxy on|off|status       # 系统代理
$BIN profiles                  # 列出配置
$BIN device                    # 本机设备 ID / Ed25519 指纹
$BIN sync status               # 配置版本历史与生效版本
$BIN sync serve --lan          # 局域网同步服务（打印配对码与只读面板链接）
$BIN sync pair 192.0.2.9:7901 --code 123456   # 首次配对
$BIN sync pull 192.0.2.9:7901                 # 拉取并收敛
$BIN sync panel                # 只读面板链接与令牌（--rotate 轮换）
```

控制面（默认 `127.0.0.1:7900`，token 在 `$LEAPIN_PROFILE_ROOT/control-token`）：

```bash
TOKEN=$(cat "${LEAPIN_PROFILE_ROOT:-$HOME/Library/Application Support/Leapin}/control-token")
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7900/v1/status
curl -sN -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:7900/v1/events?since=0"
```

细节见 [docs/CONTROL-PLANE.md](docs/CONTROL-PLANE.md) 与 [docs/SYNC.md](docs/SYNC.md)。

## 目录

```
Sources/LeapinCore            模型、协议、YAML 子集、日志脱敏、Keychain
Sources/LeapinPolicy          规则解析/分流/策略组/去广告
Sources/LeapinNet             代理服务器、出站协议、DNS、MITM、HAR
Sources/LeapinIntegrations    SSH、NAS、OCR 学习、系统代理、隐私审计
Sources/LeapinControl         控制面 HTTP/SSE/鉴权/审计
Sources/LeapinSync            设备身份、版本存储、局域网同步、只读面板
Sources/LeapinRuntime         引擎装配、配置存储、导入导出
Sources/LeapinApp             SwiftUI 界面
Sources/leapin                    命令行
docs/ARCHITECTURE.md             契约与设计
```

## 隐私设计

- 配置文件不保存任何密码；SSH / NAS 密码只在内存或用户明确选择后写入钥匙串。
- 日志、HAR、抓包详情统一经过 `Redactor`：`Authorization` / `Cookie` / `token=` / `user:pass@` 等全部替换为 `<redacted>`。
- 默认 DNS 走 DoH（`https://1.1.1.1/dns-query`，回退 DoT），可切系统 DNS。
- 默认不开 HTTPS 解密；开启后仅对 `mitmHosts` 匹配的站点签发证书，CA 私钥保存在 `~/Library/Application Support/Leapin/ca`（0600）。
- 可与 Little Snitch / LuLu（进程级出站）、NextDNS（网络级 DoH）叠加使用，互不冲突。

## 已知限制（v1）

- 不做 TUN/utun 全局接管：只提供本地代理端口 + 系统代理，未走代理的 App 需要手动配置或使用 Proxifier 类工具。
- HTTPS MITM 仅 HTTP/1.1，HTTP/2 站点会回落到 1.1 或直连；不做证书固定（pinning）绕过。
- 不支持 VMess / VLESS / Hysteria / WireGuard；支持 DIRECT / HTTP / SOCKS5 / Shadowsocks(AEAD) / Trojan。
- 抓包不做 pcap 级重组，不解析 WebSocket 帧。
- NAS 挂载使用系统 `mount_smb`，需要 macOS 允许的 SMB 共享与凭据。
- 无自签公证：`dist/Leapin.app` 为 ad-hoc 签名，首次打开如被 Gatekeeper 拦截，右键 → 打开。
- 同步是局域网明文 HTTP + 手动 `leapin sync pull`：同一 WiFi 下两台自己的机器可用；没有后台自动同步、没有云端 E2EE、没有 iOS 客户端。
- 只读面板只出元数据（版本/指针/设备），不含规则与凭据；令牌在 URL 里，可随时 `sync panel --rotate`。

## 验证情况

真实跑过的构建、测试（205 条通过 / 1 skip）、控制面 e2e（22/22）、同步 e2e（36/36）、端到端代理（10/10）、
系统代理开关与 GUI 截图记录见 [`docs/VERIFICATION.md`](docs/VERIFICATION.md)，
其中包括**明确未做端到端验证**的项目（真实双机 LAN、MITM 安装 CA、真实 SSH/NAS 设备等）。

```bash
./scripts/smoke.sh          # 真实网络端到端：明文 / CONNECT / SOCKS5 / 独立端口 / 规则 / 去广告 / DNS
./scripts/control-e2e.sh    # 控制面：token / SSE / 策略切换 / 传输中 diff reload / 审计
./scripts/sync-e2e.sh       # 双存储同步：配对 / 收敛 / 离线改动 / override / 只读面板
```

## 开发

```bash
swift build                       # 全部 target
swift test                        # 全部测试
swift build --target LeapinPolicy   # 单模块
./scripts/build-app.sh debug      # debug 版 App
```

契约见 `docs/ARCHITECTURE.md`；各模块能力与降级说明见 `docs/policy.md`、`docs/net.md`、`docs/integrations.md`。
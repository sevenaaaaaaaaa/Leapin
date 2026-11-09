# Leapin 路线图 v3 · 从「代理客户端」到「可控的流量网关」

> 2026-11-05。取代 docs/PLAN-v2.md 的定位部分（那份是 v1.1 五项提升的交付报告，保留作历史）。
> 本文回答三个问题：我们和 Surge 的差距到底在哪、哪些必须补、按什么顺序补才不会白烧。

## 0. 先修正上一版判断里的错

上一轮我把 Tailscale、Ponte、MTProto、Gateway VM、同步、授权归为「不该抄」。
这是把「现在做不起」误当成「不该做」。它们是能力，不是装饰，必须做；
但每一条都有前置依赖，顺序错了就是烧钱换一个半成品。

同时确认三条**不对称优势**，它们决定我们不该做「另一个 Surge」：

1. **控制面**：Surge 的 External Controller 是给脚本用的；我们把控制面做成产品（远端面板 + 多端同步 + 审计）。
2. **可解释性**：Surge 的 rule explain 是事后 CLI 查询；我们让每条连接天生带「为什么」。
3. **品味**：Surge 的界面是功能性的，审美停留在「系统控件排整齐」。这是我们唯一能低成本领先的维度。

## 1. 定位

**单机原生的代理与流量网关，带一个可自托管的多端控制面；把「为什么这么走」做成看得见的东西。**

- 不做 Electron、不做脚本宿主主循环、不引第三方依赖（本机无 github.com）。
- 一切能力先落在 Control 层，再由 Surface 呈现——这样 macOS / 远端面板 / 未来的 iOS 共用同一套动作语义。

## 2. 三层架构（后续所有工作的骨架）

| 层 | 负责 | 现状 |
| --- | --- | --- |
| Engine（数据面） | listeners、dialer、DNS、MITM、规则匹配、重写、TUN（未来） | 已有：HTTP/SOCKS5、4 协议、DNS+FakeIP、MITM、HAR、规则引擎、索引化匹配（P3）。缺：UDP relay、TUN |
| Control（控制面） | 状态机、动作 API、事件流、审计、设备身份 | 已有：P1 action API + SSE + token 鉴权 + 审计 + diff reload。缺：设备身份、同步 |
| Surface（呈现） | macOS App / 远端面板 / iOS（未来） | macOS 已有；其余为 0 |

**硬规则**：Surface 不得直接改 Engine 状态，只能发 Control 的 action。
没有这条，「远端控制」和「多端同步」永远做不干净。

## 3. Surge 优势 → 我们的版本（差异化，不是克隆）

| # | Surge 的做法 | 我们的做法 | 差异点 | 依赖 | 阶段 |
| --- | --- | --- | --- | --- | --- |
| 1 | 规则线性扫描 + CLI explain | 后缀 Trie + Aho-Corasick + IP radix + rule-set 二级索引；每条连接常驻 ruleChain | 10 万规则 p95 < 2ms；实时 explain 而非事后查询 | 无 | P3 |
| 2 | 全功能 JavaScript 重写 | JavaScriptCore 沙箱（超时 / 内存 / 权限清单 / 前后 diff）+ 声明式重写覆盖 90% | 脚本可观测、可撤销；崩溃不影响隧道 | 无（JSC 为系统框架） | P3 |
| 3 | 本地 DNS 劫持 / MitM / 抓包 | 已有底座，补：DoQ/DoH3、通配排除、DNS 全链路 trace | 每次解析能看到「哪条规则、哪个上游、耗时、缓存」 | 无 | P1 |
| 4 | External Controller（HTTP API） | REST + SSE 事件流 + scope token + 全量审计 | 面板与 CLI 共用一套动作；写操作可追溯 | 无 | P1 |
| 5 | iCloud / Dropbox 文件同步 | content-addressed profile 版本 + 设备级 override + 局域网直连（TLS pin）+ 云端 E2EE 兜底 | 版本只增不改 → 永不冲突；选择用 LWW，但每台设备可 override | 设备身份 | P2 |
| 6 | 原生 + NE，省电 | 同路线；把性能预算写进 CI（bench gate） | 空闲 RSS、每千连接增量、CPU idle 作为合并门槛 | 无 | 持续 |
| 7 | Tailscale 集成 | userspace WireGuard + control 协议，作为「内网直连」入口 | 与规则/策略同一套语义，不额外造一套 | P4 之后更稳 | P5 |
| 8 | Gateway VM + DHCP | TUN/VIF → 网关两段式 | 先全流量接管，再谈给别的设备当网关 | NE 签名 | P4 |
| 9 | Ponte / MTProto 服务端 | 需要 STUN/TURN + 账号体系 + 运营 | 服务型产品，等账号与授权就绪 | 授权体系 | P6 |
| 10 | License / 授权 | device identity + 签名许可 + 权限 scope | 授权同时是「谁可以控制我」的答案 | 设备身份 | P2 |

## 4. 两个硬前提（不解决，后面全卡）

### A. 签名与 Network Extension
现状：ad-hoc 签名、无 entitlements 文件（`**/*.entitlements** 为空）。
后果：TUN/VIF、网关、iOS 全部依赖 Developer ID + Network Extension entitlement + 系统扩展。
**决策点**：是否投入开发者账号并把构建从「本机自用」升级为「可分发」。
在此之前，P4 之后的能力只能做设计，不能做交付。

### B. 设备身份
同步、授权、远端控制都依赖同一个问题：**这是哪台设备、它被允许做什么**。
最小实现：Ed25519 密钥对 + 设备指纹 + 局域网配对待确认 + 权限 scope（只读 / 可切策略 / 可改配置）。
顺序必须是 设备身份 → 控制面 → 同步 → 授权，反过来做会反复返工。

## 5. 分期与验收

| 期 | 内容 | 工期 | 验收（可测） |
| --- | --- | --- | --- |
| **P0** | 诚实性：AUTO 真测速或改名；PROCESS/SRC-IP 接上或隐藏；导入报告单列「不可拨协议」；ruleChain 数据结构 | 1 周 | 导入一个含 7 种协议的订阅，报告明确写「4 个可用 / 3 个不可拨」；任意连接可读出命中链 |
| **P1** ✅ | 控制面：动作 API + SSE + token + 审计；CLI 扩 rule explain / dns trace / http probe；局部 reload（diff apply） | 2 周 | 改一条规则不断开现有连接；远端 curl 能列连接、能切策略、能重载 |
| **P2** ✅ 核心（iOS 客户端 / App 内同步页未做） | 设备身份 + 同步 + 只读远端面板 | 3 周 | 两台设备 5s 内收敛同一 profile 版本；离线改动不丢；iPhone 切节点不影响 Mac（无 iOS 客户端，未验证） |
| **P3**（索引/诊断 ✅，脚本沙箱未做） | 规则超越 + 脚本沙箱 + 编辑器诊断 | 3 周 | 10 万规则 p95 < 2ms；编辑器能报「这条规则永不命中」；脚本超时 50ms 强制中断 |
| **P4**（仅设计） | TUN/VIF 全流量接管 → 网关 + DHCP；设计见 docs/P4-DESIGN.md | 4–6 周 | 不遵守系统代理的进程也被接管；断网回滚原子完成（需 NE 签名，本期只设计） |
| **P5** | Tailscale 策略 | 4 周 | tailnet 内域名/IP 走规则系统 |
| **P6** | Ponte / MTProto / 授权商业化 | 依赖基础设施 | 另行立项 |

## 6. 品味：把「审美超过能力」变成可执行标准

- **动效只表达因果**：数据在流动、状态在切换、动作被确认。不做 hover 装饰。
- **每个数字可溯源**：任何统计点开都能看到它的来源连接。
- **三处签名器件**：流量地震仪（已有）→ 连接河流图（实时连接的生命周期）→ 同步状态轨（设备间版本推进）。
- **每屏一个主角**，其余信息降为脚注级。
- **反例清单**：渐变按钮、彩虹统计卡、无信息价值的玻璃与光斑、装饰性骨架屏。
- 评审沿用现有 8 维流程，交付线 6.5、获奖线 8.0；每次大改必须重跑。

## 7. 风险

1. **TUN 会动系统路由**：必须有原子回滚（参考 stop 回滚系统代理的既有做法），否则一次崩溃用户就断网。
2. **同步冲突会摧毁信任**：先做「版本只增不改」，再谈合并；宁可不合并，也不静默覆盖。
3. **脚本沙箱性能**：JSC 冷启动约 200ms，需要常驻 context 池 + 每次执行硬超时。
4. **无第三方依赖**：WireGuard Noise、STUN、CRDT 都得自研。量都不大（Noise 约 800 行，STUN 约 300 行），但要预留时间。
5. **不要同时开三条战线**：控制面没通之前做同步会返工；签名没解决之前做 TUN 会空转。

## 8. 度量（写进 CI，不靠感觉）

- 规则匹配 p95 < 2ms @ 10 万条；装载 < 300ms
- 远端控制往返 < 150ms（局域网）
- 同步收敛 < 5s；冲突 0 丢失
- 空闲 RSS < 80MB；每千连接增量 < 30MB；空闲 CPU ≈ 0%
- explain 覆盖率 100%（每条连接都能说出为什么）

## 9. P0 交付（2026-11-05，已完成）

| 项 | 交付 | 证据 |
| --- | --- | --- |
| AUTO 真测速 | `HealthProber` 每 15s 对 url-test/fallback 成员做 TCP 握手，结果进 `LPHealth`；`PolicyResolver` 用 180s 内实测延迟选最快，50ms 容差滞回 | 规则页显示「当前 DIRECT / 最快 DIRECT 698 ms」，停代理回落「未运行 / 尚未测速」 |
| PROCESS 接上 | 新增 C target `CLeapinProc`（libproc 枚举 ESTABLISHED TCP）+ `ProcessAttributor`（1s 快照、缓存 256） | 抓包详情与总览显示 `curl`；`PROCESS-NAME` 规则参与裁决 |
| SRC-IP 接上 | `ConnectionMeta.sourceIP` 由 `ClientOrigin` 贯穿到 `RouteDecision` | `SRC-IP-CIDR` 单测命中；抓包详情显示客户端地址 |
| 规则链 | `RuleChain`/`RuleChain.Step` 常驻 `RouteDecision.chain`，rule-set 成员各成一步，MATCH 标 final | 抓包详情「第 9 / 9 条 · FINAL,PROXY · 兜底 MATCH」 |
| 不可拨协议 | `ImportReport.notDialable` + `annotateDialability`；导入报告与 `validate()` 双向提示 | `HonestyTests` vmess 不可拨 / 导入计数；报告页 amber 提示条 |

测试：132 全绿（Core 1 / Policy 51 / Net 69 / Integrations 11）；smoke 7/7。
未做：真实 ss/vmess 节点测速（本机无服务器）、MITM 隧道内按 URL 重算链（当前为主机级）、UDP 连接的进程归属。

## 10. P1 / P3 交付（2026-11-05，索引与诊断完成；脚本沙箱未做）

| 项 | 交付 | 证据 |
| --- | --- | --- |
| 控制面 API | `ControlServer`（Network.framework，127.0.0.1:7900）：GET status/connections/policies/audit/events(SSE)，POST policies/select、reload、explain、dns/trace、http/probe | `scripts/control-e2e.sh` 22/22；curl status/connections/select/reload/events 全部通过 |
| token 鉴权 + 审计 | `$LEAPIN_PROFILE_ROOT/control-token`（0700 目录 / 0600 文件 / 64 hex / 原子写）；`control-audit.jsonl` >5MB 轮转，记录 method/remote/allowed/action/status/path | e2e：无 token 401、错 token 401、权限 600、被拒请求与 reload 均落审计 |
| 局部 diff reload | `POST /v1/reload` 按 diff 应用，监听器不变；慢速下载贯穿 reload 不断流 | e2e：120000B 传输中 reload，`restarted=false`，连接保留；新规则立即生效 |
| CLI 三件套 | `leapin rules`（explain / --diagnose / --measure）、`dns --trace`、`http-probe`（3 跳重定向、逐跳地址、不走系统代理） | smoke 10/10；dns trace 输出 source/upstream/elapsedMs/cacheTTL；HTTPProbeTests 6 条本地测试 |
| 配置局部 diff | Clash / Surge 双向导入导出 `control-port` / `control-allow-lan`；GeneralConfig 宽容解码 | 导入导出测试与 e2e 实测 |
| 规则索引 | 后缀反向标签 Trie + 精确域名字典 + AC 关键字 + IPv4/IPv6 前缀树 + PROCESS 字典；alwaysCheck 兜底 negate/AND/OR/NOT/GEOIP/REGEX | `RuleIndexDifferentialTests`：320 组随机规则集 × 12 meta（3840+ 次）与线性参考全字段一致 |
| 10 万规则性能 | release 下 decide 走索引，首命中即停 | rules=100001、load=99.6ms、**p95=0.006ms**、p99=0.009ms（阈值 2ms / 300ms）；leapin release 复核 p95=0.001ms |
| 永不命中诊断 | `RuleEngine.diagnostics()` 五类（duplicate/shadowed/unreachable/never-match/rule-set-missing）；RulesView 侧栏 + 行徽标 + AddRuleSheet 预检 | `RuleDiagnosticsTests` 15 条；`leapin rules --diagnose` 输出 #2 与被 #1 遮蔽 |

测试：178 条（Core 1 / Policy 75 / Net 75 / Integrations 11 / Control 16），0 failures；control-e2e 22/22；smoke 10/10。
未做 / 未验证：JavaScript 脚本沙箱（P3 第三项）未开始；编辑器诊断未做真实窗口目视取证；`diagnostics()` 不递归 RULE-SET 成员；
遮蔽只判定可证明场景；control 热重载不含监听器级变更（MITM/capture/bypass 需重启）。

P2 已完成（见 §11）。下一期：P4 设计（docs/P4-DESIGN.md）——TUN/VIF 全流量接管、路由原子回滚、网关 + DHCP；
实现需要 Developer ID + Network Extension entitlement，本机 ad-hoc 签名下只做设计不交付。
P3 剩余：JavaScript 脚本沙箱（JSC 常驻 context + 50ms 硬超时）。

## 11. P2 交付（2026-11-09）

| 项 | 交付 | 证据 |
| --- | --- | --- |
| 设备身份 | Ed25519（CryptoKit），只存 32 字节 seed；默认登录钥匙串，回落 0600 文件；`deviceID` = SHA-256(公钥) 前 16 字节，`fingerprint` 按 4-hex 分组 | `leapin device`；DeviceIdentityTests 5 条（签名/篡改/±300s/0600/重载稳定） |
| 版本模型 | content-addressed（规范化 JSON 的 SHA-256，排除本地 UUID 与 sourcePath）；只增不改；`ingest` 重算 hash 拒绝损坏内容 | ProfileVersionStoreTests 6 条；e2e 首版本 + 离线版本 |
| 指针与 override | 每设备 LWW 指针（updatedAtMs → deviceID 破平局，单调）；本机 override 永不同步 | 单测 monotonic/tie-break/override；e2e override 固定回 v1 且 A 不受影响 |
| 局域网同步 | 明文 HTTP/1.1：`/v1/info`、`/v1/pair`、`/v1/manifest`、`/v1/versions/<id>`、`/v1/announce`；Ed25519 签名信封（method+path+bodyHash+ts+nonce），±300s + nonce 缓存，重放 409；配对码 6 位/300s/单次/常量时间 | SyncTransportTests 8 条；`scripts/sync-e2e.sh` 36/36；配对→拉取→应用 0.19s（阈值 5s） |
| 只读远端面板 | `GET /panel`（HTML）+ `/panel.json`；令牌 32 字节 CSPRNG（0600、目录 0700、每请求重读、`--rotate` 即时生效）；只出元数据不出规则/凭据；无脚本无外链；写方法 405 | SyncPanelTests 5 条；e2e 面板 10 项断言（401/405/0600/不含规则值/版本数/生效版本） |
| CLI | `leapin device`、`sync status/versions/record/serve/pair/pull/apply/override/peers/unpair/panel` | e2e 全流程；`leapin sync --help` |
| 修复的真实缺陷 | `PeerRegistry.upsert/touch` 持有 NSLock 时重入 `peer(deviceID:)` → 首次配对死锁、全量测试挂起；改 `peerLocked` + 3s 回归测试 | `sample` 栈指向 `PeerRegistry.upsert`；tests 201 passed 全绿 |

未做：App 内同步页与面板开关（当前入口是 `leapin sync serve`，前台进程、无后台自动同步）、真实双机 LAN 验证、
iPhone 浏览器渲染取证、配对码失败退避、`SyncPeer.scopes` 强制、云端 E2EE；
路线图 P2 验收里的「iPhone 切节点不影响 Mac」未验证（没有 iOS 客户端，只读面板不能切换节点；设备级 override 只验证了本机固定版本）。详见 docs/SYNC.md §8。

## 12. P4 设计交付（2026-11-09，仅设计）

- 文档：docs/P4-DESIGN.md（11 章）。覆盖签名/entitlement 前置、packet tunnel + "够用 TCP 栈"取舍、
  VIF 与 DNS/Fake-IP 语义、路由接管与原子回滚、网关 + DHCP、Control action/SSE/审计扩展、性能预算、风险与分阶段验收。
- 事实核查：仓库无 entitlements、无 NE/TUN 代码、`FakeIPPool.host(for:)` 无调用方、DNS 只绑 127.0.0.1、
  fake-IP 对 AAAA 回 A、SSE 只有 `flow` —— 这些是 P4 开工前必须补的断链。
- 实现前三大风险：① 付费账号 + development profile 激活 NE、扩展写 sysctl/pf 的权限；② "够用 TCP 栈"与 DNS 应答核心；
  ③ NE 路由在扩展被杀/断电/升级时是否随接口消失（macOS 14/15/26 三档实测）。
- 需拍板的两项 P1 接口变更：SSE 回放缓冲泛化（ControlServer.swift:186-192/247-251）、
  审计改 Engine 单写者 + `ControlAuditRecord` 可选字段（ControlContract.swift:186-209）。
- 交付边界：P4/P5/P6 **零实现**；等 Developer ID + NE entitlement 到位后才进入 P4a。

## 13. 改名：TouchFlow → Leapin（v1.8，2026-11-10）

- 品牌：`LEAPIN` / `Leapin` / `leapin`；中文「一跃」；口号 `One leap. No detour.`。理由与用法见 docs/BRAND.md。
- 范围：Swift 模块/类型、`TF`→`LP`、`tfctl`→`leapin`、bundle id `com.leapin.app`、App `Leapin.app`、
  数据目录、钥匙串 service、URL scheme、环境变量 `TF_*`→`LEAPIN_*`。
- 兼容：旧数据目录一次性复制（保留旧目录）、设备身份自动迁移（deviceID 不变）、旧命名广告列表迁移、
  旧 CA 继续沿用（CN 暂保留 `TouchFlow Root CA`，避免用户重装证书）。
- 验证：fresh build 0 warning；205 passed / 1 skipped；sync-e2e 36/36、control-e2e 22/22、smoke 10/10；
  `dist/Leapin.app` 的 bundle id / executable / 签名已核对。详见 docs/VERIFICATION.md §0.6。
- 后续：工作区目录仍叫 `TouchFlow`（会话 cwd，未动）；GitHub 仓库名与推送待定；真实钥匙串凭据迁移未验证。

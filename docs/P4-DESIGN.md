# TouchFlow P4 设计：TUN/VIF 全流量接管 → 网关 + DHCP

> 状态：**仅设计，未实现**。本文不修改任何代码，仓库内 TUN/Network Extension 实现为 0。
> 依据：`docs/ROADMAP-v3.md`（P4 目标与 §8 度量）、`docs/ARCHITECTURE.md`（三层与硬规则）、
> `docs/net.md`（数据面现状）、`docs/CONTROL-PLANE.md`（动作/SSE/审计契约）、`docs/perf.md`（基线数字）。
> 结论先行：**本期 P4 的瓶颈不是写隧道，而是签名/entitlement 与"够用的用户态 TCP"。**
> 在没有 Developer ID + Network Extension entitlement 之前，P4 只能做到"可编译、可单测、不可激活"。

## 0. 现状核查（设计的事实基础）

| 事实 | 证据 | 对设计的影响 |
| --- | --- | --- |
| ad-hoc 签名，无任何 entitlements 文件 | `scripts/build-app.sh:32-34`（`codesign --sign -`）；仓库内 `**/*.entitlements` 为 0 个 | 系统扩展无法激活，NE 全链路不可测 |
| 无 TUN/NE 代码 | `grep -r "NEPacketTunnel\|NetworkExtension" Sources` = 0 | P4 从零开始，不是改造 |
| 平台下限 macOS 14，包内无扩展 target | `Package.swift:6`、`Package.swift:18-37` | 需要新增扩展 target + bundle 组装脚本 |
| 系统代理回滚有先例但会静默失败 | `Sources/TouchFlowRuntime/TouchFlowEngine.swift:200-209`、`:215-228`（失败时保留 `systemProxyActive`，调用方忽略返回值） | TUN 回滚必须升级为"逐项结果 + 显式 UI + 审计" |
| Fake-IP 只有分配，没有反查消费方 | `Sources/TouchFlowNet/DNS/FakeIPPool.swift:38` `ip(for:)` 有调用；`:60` `host(for:)` 在 `Sources/` 内 **0 调用** | TUN 数据面必须补上"假 IP → 域名"这一跳，否则 fake-IP 模式在 TUN 下不可用 |
| DNS 服务只绑 127.0.0.1 | `Sources/TouchFlowNet/DNS/FakeIPPool.swift:139`、`:171`（`requiredLocalEndpoint` 固定 127.0.0.1） | TUN 的 DNS 不能直接复用该监听，需抽应答核心 |
| DNS fake-IP 对 AAAA 查询也回 A 记录 | `Sources/TouchFlowNet/DNS/FakeIPPool.swift:321-330` | 现状缺陷，TUN 下会放大；P4a 前修（Engine 层，不在本文实现） |
| SSE 事件类型写死 `event: flow` | `Sources/TouchFlowControl/ControlServer.swift:247-251`；回放缓冲是 `[ControlEvent]` `:186-192` | 新增 tunnel/routes 事件需要通用帧类型 |
| 控制面动作表是显式 switch + 方法白名单 | `Sources/TouchFlowControl/ControlServer.swift:325-419`、`:777-787` | 新动作必须同时改两处，否则 404/405 |
| 控制面后台调用默认 10s 超时 | `Sources/TouchFlowControl/ControlServer.swift:435-439` | tunnel start/stop 不能阻塞在该超时内，需异步受理 |
| 审计记录是固定字段 | `Sources/TouchFlowControl/ControlContract.swift:186-209` | 需要追加可选字段（向后兼容）承载 tunnel 取证 |
| Surface 目前直接调 Engine 方法 | `Sources/TouchFlowApp/TouchFlowApp.swift:75`、`:279-282` 等 | 隧道动作必须走 Control action，不能再加直连方法 |

## 1. 目标与非目标

### 1.1 P4 目标（以可测为准）

1. 本机**不认系统代理的进程**也被接管（路线图 §5 P4 验收原话）：`curl --noproxy '*'`、`nc`、`git`、任意 App 的 TCP 出站都经过 TouchFlow 的规则与出站。
2. 单机模式（P4a）可独立开关，开关一次不改变用户对"网络是否正常"的感知；停用/崩溃后**默认路由回到原接口**。
3. 可选网关（P4b）：让**用户显式指定的专用接口**上的设备经本机出网，且默认关闭、失败可回滚。
4. 新增能力全部以 Control action 暴露，Surface 只发动作（承接 `docs/ROADMAP-v3.md` §2 硬规则）。

### 1.2 非目标（本期明确不做）

- 不做完整用户态 TCP/IP 栈（见 1.3 取舍）；不做 SACK/拥塞控制研究、不做 IPv6 完整栈、不做 QUIC 代理。
- 不做内核扩展、不注入进程、不做 pf 透明代理重定向（需要非公开的透明 socket 语义，需验证，不纳入）。
- 不做 Tailscale（P5）、不做 Ponte/MTProto/授权（P6）、不做 iOS。
- 不做 App Store 版本（沙箱与特权助手冲突，见 §8）。
- 不做默认 kill switch：我们的失败模式是"回到直连"，不是"保持封锁"；若未来提供，必须显式 opt-in 并单独评估。
- 不自动修改路由器、不写 `/etc/bootpd.plist`、不替用户决定家庭网络拓扑。

### 1.3 关键取舍：要不要写"完整" TCP/IP 栈

| 方案 | 能否达成 P4 目标 | 成本 | 结论 |
| --- | --- | --- | --- |
| A. packet tunnel + 完整用户态栈（TCP 拥塞控制/SACK/分片/IPv6） | 能 | 8–12k 行 + 数月弱网调优；无第三方依赖可借（路线图 §7.4） | 不做。4–6 周工期不成立 |
| B. app-proxy-provider（拿 `NEAppProxyFlow` 字节流，不写栈） | 理论上能，但 macOS 上是否可用于非 MDM 个人设备**需验证**；按文档语义面向 per-app VPN，通常要配置描述文件下发 | 低 | 作为备选调研，不作默认路径 |
| C. pf 把流量重定向到本地透明代理端口 | 大概率不行：macOS 用户态缺透明 socket 语义，**需验证** | 中 | 不纳入 |
| D. packet tunnel + **"够用栈"**（只服务本机→扩展这一段） | 能 | 2.5–3.5k 行 | **选它** |

D 的关键论证：TUN 里的 TCP 只跨 **本地 VIF**（RTT < 1ms、丢包近似 0、路径无中间盒），真正的公网传输由 `OutboundDialer` 的系统 socket 承担（`Sources/TouchFlowNet/Outbound/OutboundDialer.swift`）。
因此栈只需要：三次握手/序号确认、固定接收窗口、RTO 重传、MSS 协商、IPv4 分片重组、半关闭与 RST；
不需要慢启动调参、不需要 SACK/DSACK、不需要应对公网乱序。代价是端到端语义被"TCP 拆分"改变（应用测到的 RTT 是本地 RTT），需在文档与 UI 说明。

## 2. 前置条件清单

### 2.1 账号与证书

| 项 | 用途 | 备注 |
| --- | --- | --- |
| Apple Developer Program（付费） | 申请 NE entitlement、创建 development/Developer ID profile | 个人或组织；组织需 D-U-N-S。免费账号不含 NE |
| Developer ID Application 证书 | 站外分发（本项目的唯一现实路径） | 配合 hardened runtime + 公证 |
| development provisioning profile | **开发期唯一可激活 NE 的路径**，无需公证 | 必须在 P4 第一周打通，否则后续全空转 |
| App Group（如 `group.com.touchflow.app`） | App 与扩展共享配置快照/会话标记 | 需 `com.apple.security.application-groups` |
| NE entitlement | `com.apple.developer.networking.networkextension` | App 与扩展都要有；Developer ID 路径需 Apple 单独批准，**审批周期需验证** |

### 2.2 entitlement 取舍

| 值 | 能力 | 代价 | 结论 |
| --- | --- | --- | --- |
| `packet-tunnel-provider` | L3 全流量接管（含不认系统代理的进程） | 必须自己处理 IP 包与 TCP；需要完整签名链 | **P4 主线** |
| `app-proxy-provider` | 按 flow 给字节流，理论上不用写栈 | macOS 上大概率受 MDM/描述文件约束，覆盖范围与可用性**需验证** | 备选调研，不排期 |
| `dns-proxy-provider` | 只接管 DNS | 不接管 TCP，达不成 P4 目标 | 仅可作 P4-lite 过渡，需验证与 tunnel 共存 |

### 2.3 打包与首次授权流程

1. App 内嵌扩展：`TouchFlow.app/Contents/Library/SystemExtensions/<bundle-id>.systemextension`（SwiftPM 不产出该形态，需脚本组装，参照 `scripts/build-app.sh` 现有组装逻辑扩展）。
2. App 用 `OSSystemExtensionRequest.activationRequest` 提交激活 → 用户在「系统设置 → 通用 → 登录项与扩展 → 网络扩展」批准（macOS 14/15/26 的入口位置需逐版本验证）。
3. `NETunnelProviderManager` 保存 VPN 配置 → 系统弹「TouchFlow 想要添加 VPN 配置」→ 允许。
4. 才能 `startVPNTunnel`。任一环节被拒，状态必须是可读的 `failed(reason)`，不是无声无息。
5. 升级：提升扩展与 App 的 `CFBundleVersion`，对已安装旧版本发起替换激活；是否需要二次审批**需验证**。升级前先停隧道，安装后跑 1 分钟冒烟再删旧副本。

### 2.4 公证与升级路径

- 签名：`codesign --options runtime --entitlements <plist> --sign "Developer ID Application: …"`，对 App 与内嵌扩展分别签。
- 公证：`xcrun notarytool submit --wait` → `xcrun stapler staple`；`spctl -a -vvv` 复验。
- 升级纪律：同一 bundle id + 递增版本；换 Team ID / bundle id 会让旧扩展变孤儿，需先发 `deactivationRequest`（**需验证**孤儿扩展的实际表现）。
- 回滚：保留上一个已公证版本，新版本冒烟（启动→curl→停止→路由复原）不过就回退，不允许"边用边修"。

### 2.5 无签名 / 自签的边界

| 能测（不需要 NE） | 不能测 | 折中（dev-only，禁止进发布） |
| --- | --- | --- |
| 包解析/构造、TCP 状态机（内存 pipe 注入 IP 包） | 系统扩展安装/审批/替换 | 付费账号 + development profile：**唯一**能完整验证 NE 的路径 |
| DNS 应答核心、Fake-IP 分配与反查 | `packetFlow` 真实读写、`setTunnelNetworkSettings` 的路由语义 | root 手工建 utun + 双半默认路由（`0.0.0.0/1`+`128.0.0.0/1`）让开发构建读真实流量（当前 macOS 上是否仍可由 root 创建 utun **需验证**），`#if DEBUG` + `TF_TUN_DEV=1`，带 trap 清理 |
| 路由快照/差分/恢复（只读采集 + 测试机手工注入恢复） | 扩展进程是否具备写 sysctl/pf 的权限 | `pfctl -n -f` 干跑校验规则语法（不 `-e`） |
| DHCP 编解码与租约状态机（回环 UDP） | 公证后的 Gatekeeper 首次启动路径 | 用 `tfctl` 子命令做无 UI 的包路径压测 |
| 控制面 action/SSE/审计（沿用 `docs/VERIFICATION.md` §0.4 的 178 条测试做法） | 升级迁移与审批状态机 | — |

自签（`codesign --sign "TouchFlow Dev"`）**不能**解锁 NE：NE 校验 Team ID 与 provisioning profile，自签没有 Team ID，激活会失败（具体错误码**需验证**）。自签只让 Keychain/TCC 身份稳定，与本任务无关。

### 2.6 开工检查表（全绿才进入 P4a-0）

- [ ] 付费账号 + NE entitlement 已获批（或至少 development profile 可用）
- [ ] 空壳 provider 能激活/停用，路由随接口出现/消失
- [ ] `route -n get default` 在停止后 2s 内回到原接口（10 次）
- [ ] 扩展内 `id`/`sysctl -w` 权限结论明确（决定 P4b 是否需要特权助手）
- [ ] 配置快照与 App Group 读写通路可用

## 3. 架构设计

### 3.1 进程与信任边界

| 进程 | 职责 | 禁止 |
| --- | --- | --- |
| App（现有 `TouchFlowEngine`） | Profile、系统代理、DNS 127.0.0.1 监听、Control 7900、快照/审计单写者 | 不处理 IP 包 |
| 扩展（新 `TouchFlowTunnel`） | `packetFlow` 读写、TCP/UDP 处理、出站拨号 | 不监听任何 TCP 端口、不写审计文件、不读 `$TF_PROFILE_ROOT` |
| Control（App 内） | 动作/SSE/审计/鉴权 | 不自作主张改系统状态 |

扩展与 App 是**两个进程**：扩展拿不到 `@MainActor` 的 `TouchFlowEngine`（`TouchFlowEngine.swift:36-38`），也不该读 `ProfileStore`（`ProfileStore.swift:23-38` 的 Application Support 路径在沙箱下不可达）。因此：

- App 启动隧道前，把**已解析的运行时快照**（含已合并的 rule-set）写入 App Group；扩展只读该快照，版本/hash 不匹配就拒绝启动。
- 命令走 `NETunnelProviderSession.sendProviderMessage`（start/stop/reload/stats），响应体限长 JSON。
- 遥测走 1Hz 的 provider message 轮询 + 扩展侧 `os_log`；必须留痕的事件写 App Group 的环形文件，由 App 消费。
- 规则集 10 万条时扩展内建 `RuleEngine` 约 0.7s（`docs/perf.md` §1），需计入启动预算；必要时应把预编译索引落盘（**待验证**）。

### 3.2 数据路径（P4a，IPv4 TCP）

```
App 字节 → utun → packetFlow.readPackets → IPv4 解析
  → 目的地址是 VIF / fake-IP? → DNS 或反查域名
  → ConnectionMeta(host, port, network, sourceIP, destinationIP) → RouterBox.decide
  → 命中 REJECT/blocker → RST
  → TCP 栈与客户端完成握手/收发
  → OutboundDialer.connect(via: decision.outbound, host:, port:)（绑定物理接口）
  → BytePump 语义的字节搬运 → packetFlow.writePackets → utun
```

### 3.3 VIF 与网络设置

| 项 | P4a | P4b |
| --- | --- | --- |
| IPv4 地址 | `10.77.0.1/30`（不占用 fake-IP 的 `198.18.0.0/15`） | `10.77.0.1/24`（DHCP 池 `10.77.0.100-199`） |
| IPv6 | 不下发地址；`::/0` 进 included 后由数据面**快速失败**（ICMPv6 unreachable），避免静默泄漏 | 同左，DHCPv6/RA 不做 |
| DNS | `dnsSettings.servers = [10.77.0.1]`，由数据面应答 | 同左 |
| MTU | 1500（VIF 本地，不需要按公网 PMTU 调） | 1500 |
| 路由 | `includedRoutes = 0/0`，`excludedRoutes = 回环 + 本机 LAN 子网 + 组播/广播 + 其它 utun 子网` | 追加专用接口子网 |

注意：`DNSServer` 绑死 127.0.0.1（`FakeIPPool.swift:139`），**不能**直接作为 VIF 的 DNS 后端。设计上把 `DNSServer.answer(raw:)`（`:316-338`）的纯逻辑抽成 `DNSResponderCore`，由 127.0.0.1 监听与 TUN 数据面共用；这样 Fake-IP/blocker/上游链只有一份实现。

### 3.4 与现有模块的复用边界

| 现有件 | 复用方式 | 结论 |
| --- | --- | --- |
| `RouterBox`/`ResolverBox`/`BlockerBox`（`Sources/TouchFlowRuntime/ControlWiring.swift:14/33/52`） | 直接注入数据面，热切换语义不变 | 直接用 |
| `OutboundDialer` | `connect(via:host:port:)` 原样调用 | 直接用，**但需新增"绑定物理接口"能力**，否则扩展自身出站会被自己的默认路由抓回（回环） |
| `BytePump`（`Sources/TouchFlowNet/Proxy/BytePump.swift`） | 作为"TCP 栈 ↔ upstream"的搬运与空闲超时 | 复用逻辑，需 `ByteStream` 适配层 |
| `ProxyServer`（`Sources/TouchFlowNet/Proxy/ProxyServer.swift:13`） | 依赖 NWListener + HTTP/SOCKS 嗅探，TUN 下没有这些语义 | **不复用**，系统代理路径保持不变 |
| `DNSServer` | 监听绑 127.0.0.1 | 抽 `DNSResponderCore` 后复用 |
| `FakeIPPool` | 需单实例共享（DNS 分配 + 数据面反查） | 改造：由 Engine 持有并注入两处 |
| `ProcessAttributor` | TUN 下用 5 元组（源端口）反查 PID，与现状同源 | 复用，命中率受 1s 快照限制 |
| `MITMHandler` | 期望 `ByteStream` + CONNECT 语义 | P4 不做；后续可在栈上套 `ByteStream` 适配再评估 |
| `SystemProxy`（`Sources/TouchFlowIntegrations/System/SystemProxy.swift:47-89`） | 与 TUN 共存，纳入统一停止序列 | 保留 |
| `HealthProber` | 出站健康检查 | 直接用 |

### 3.5 TCP / UDP / ICMP 策略

| 协议 | P4a | 说明 |
| --- | --- | --- |
| TCP | 最小栈 + 代理 | IPv4；不做 SACK；窗口固定 64KB（可后续调）；半关闭必须保留（`docs/net.md` 记录过半关闭踩坑） |
| UDP:53 | 内部应答 | 走 `DNSResponderCore`；TCP:53 同样应答 |
| UDP 其它 | 默认丢弃并回 ICMP port unreachable | 明确失败优于挂起；QUIC 应用会回退 TCP（可观测） |
| ICMP echo | 只答 VIF 自身 | 对公网 ping 不伪造成功，超时是诚实结果 |
| IPv6 | 快速失败 | `::/0` 进 included，数据面回 ICMPv6 unreachable（必要时 v6 RST），避免应用等 30s；若实现成本超预期，退化为不下发 IPv6 设置（旁路）并在 UI 明示泄漏 |

P4a 的 UDP 明确短板要写进 UI 与 `docs`：`docs/net.md` §2 已声明 ss/trojan 只做 TCP，SOCKS5 UDP ASSOCIATE 未实现，因此"经代理的 UDP"在 P4a 无处可去，只能直接失败。

### 3.6 DNS 劫持与 Fake-IP 的语义一致性

- DNS 设置指向 VIF 后，所有进程的解析都进数据面；`dnsSettings.servers` 是系统级语义，不依赖应用配合。
- Fake-IP 链路必须闭环：DNS 应答 `198.18.x.y` → 客户端连该地址 → 数据面用**同一个** `FakeIPPool` 反查域名 → 用域名做规则裁决与 SNI。
  现状 `host(for:)` 无调用方（§0），这一步是 P4a 的硬前置。
- 未命中反查（池已回收/客户端用字面 IP）：按 IP 裁决并记 `tunnel.fakeip-unmapped`，不猜域名。
- `fakeIPFilter` 当前未参与 `DNSServer.answer`（`FakeIPPool.swift:321-330`），TUN 下必须生效，否则内网域名会被假 IP 化。
- 已知语义差异（要写进 explain）：fake-IP 连接在解析前拿不到真实 IP，`IP-CIDR` 类规则对它不生效；P4a 只做单相裁决，P4b 再评估"域名未命中→解析后二次裁决"。

## 4. 路由接管与原子回滚

### 4.1 谁拥有路由（本设计的核心结论）

**P4a 不手工写系统路由。** 默认路由与分流路由全部通过 `NEPacketTunnelNetworkSettings` 的 `includedRoutes/excludedRoutes` 交给系统安装：接口销毁时路由随之消失，原子性由系统保证。这比 `route add` 少一个数量级的失败面，也是路线图 §7.1 的正解。

手工 `route` 只保留两种用途：
1. dev-only 实验（§2.5），发布构建不存在；
2. P4b 若实测需要 LAN 侧特殊路由，必须走"快照 + CAS 恢复"，且只删除"接口名 == 我们的 utun"的条目，绝不整表覆盖。

### 4.2 快照内容

采集：`route -n get default -inet/-inet6`、`netstat -rn -f inet/-f inet6`、`ifconfig -a`、`sysctl net.inet.ip.forwarding net.inet6.ip6.forwarding`、`pfctl -s info`（enabled 状态）、`pfctl -s Anchors`、`scutil --dns`、`scutil --nc list`。

格式：JSON + 整体 SHA-256；字段含 `schemaVersion/snapshotId/takenAt/osBuild/routesV4/routesV6/interfaces/sysctls/pf/dnsResolvers/vpnConfigs`。
落盘：`$TF_PROFILE_ROOT/tunnel/snapshots/<ts>-<hash8>.json`，沿用 `ProfileStore.save` 的原子写习惯（`Sources/TouchFlowRuntime/ProfileStore.swift:59-65`）。保留最近 10 份 + 1 份手工标记的 last-good。
快照只读；恢复必须引用 `snapshotId`，不允许"按当前状态猜"。

### 4.3 启动顺序（失败即回退）

1. 预检：entitlement/审批状态、其它 VPN/utun、快照写成功、配置快照 hash 匹配。
2. 原子写 `session.json`（`phase:"installing"` + sessionId + snapshotId）并 fsync。
3. `saveToPreferences` → `startVPNTunnel`。
4. 扩展内先 `setTunnelNetworkSettings`（路由在此生效），再启动数据面，回 "running"。
5. App 校验：默认路由指向 utun（full 模式）、resolver 指向 VIF、canary 请求被隧道处理。
6. 写 `phase:"running"` + 审计 `tunnel.start`。
任一步失败 → `stopVPNTunnel` → 进入 4.4 恢复 → 状态 `failed`。

### 4.4 停止顺序（与系统代理一致）

1. 写 `phase:"stopping"`（先落盘，崩溃后可恢复）。
2. `stopVPNTunnel`（系统撤路由）。
3. 校验默认路由已离开 utun、resolver 复原、canary 直连成功。
4. P4b 若动过全局状态：按逆序 CAS 恢复（DHCP 监听 → pf anchor → sysctl），逐项校验。
5. 写 `phase:"disabled"` + 审计 `tunnel.stop`（含每步耗时）。
6. 再走系统代理回滚与监听器拆除。**新顺序：TUN → 系统代理 → 监听器**；现有 `TouchFlowEngine.stop()`（`Sources/TouchFlowRuntime/TouchFlowEngine.swift:200-209`）是"系统代理 → 监听器"，需插入 TUN 步骤而不是改写它。

### 4.5 崩溃与断电

- 扩展被杀：接口销毁 → 路由应由系统回收（**需在 macOS 14/15/26 实测**）。App 发现 `session.json.phase != disabled` 且 provider 不活跃 → 自动 `recover`（幂等），审计 `tunnel.recovered`。
- 断电/强制重启：`session.json` 残留；启动时只读核对，只修"与快照不一致且确认是我们改的"项，CAS 写入；不做整表恢复。
- launchd 看门狗：P4a 不需要（NE 自身有重连与回收）。P4b 的 sysctl/pf/DHCP 残留用"用户级检测 + 前台确认修复"，**不自动改系统状态**——防二次伤害优先于自愈速度。
- 不启用 on-demand（避免隧道反复自启）；扩展崩溃后的默认重启行为**需验证**。

### 4.6 回滚失败的显式 UI 与审计

- 状态 `rollback-failed`，附 `failedItems[{item, expected, actual, error}]`。
- UI：全局常驻 banner（不是 toast）：重试恢复 / 查看快照 diff / 复制诊断；修复前 `POST /v1/tunnel/start` 返回 409 `rollback_failed`。
- SSE：`tunnel.status` 推 `state:"rollback-failed"` + `failedItems`，连上来的面板与 CLI 立刻同屏。
- 审计：`tunnel.rollback-failed`，`outcome:"failed"`，detailJSON 含 failedItems + snapshotId + osBuild。**即使 Control 服务已停也必须落盘** → 审计单写者归 Engine。
- 恢复动作本身也审计（`routes.restore`，ok/partial/failed），便于事后判断"是回滚失败还是回滚后又坏"。

## 5. 网关 + DHCP（P4b）

### 5.1 方向与"不做 NAT"的取舍

LAN 客户端 → en0 →（`net.inet.ip.forwarding=1`）→ 默认路由 utun → 扩展 → 用户态代理 → 物理接口出网 → 合成回包写回 packetFlow → 内核按路由送回 en0。

因为我们在用户态**终止并重建**连接，NAT 是"天然发生"的：不需要内核 NAT 状态表（连接状态由我们的代理维护），也不需要 pf NAT。代价：
- 需要对不支持的协议主动回 ICMP unreachable/RST，否则客户端表现为超时；
- 源地址语义、TCP 序号空间由我们维护（与 P4a 同一套栈）；
- 单台 Mac 成为所有客户端流量的单点，性能与稳定性门槛更高。

二层说明：utun 是 L3 点对点接口，没有 ARP/Ethernet，因此**不存在 VIF 上的二层转发**；二层只发生在 LAN 侧原生链路（ARP/DHCP 广播），我们不做桥接、不做混杂模式。这也意味着 DHCP 必须在真实以太网接口上应答，而不是在 VIF 上。
若实测发现转发必须依赖 pf（例如内核转发路径对我们的合成包有限制，**需验证**），则 P4b 降级为"仅专用接口 + 明确不支持"，不冒险改全局防火墙。

### 5.2 DHCP 范围与安全门

默认关闭，只在用户显式选择的**专用接口**上启用：

- 启动前被动监听 3s，发现任何 DHCPOFFER → 拒绝启动（防 rogue DHCP 冲突家庭网络）。
- 接口承载本机默认路由（en0）→ 硬拒绝。
- 池：与接口同网段的 /24 子集（默认 `10.77.0.100-199`），不分配网络/广播/网关地址；租约 30 分钟；只实现 DISCOVER/OFFER/REQUEST/ACK/NAK/RELEASE，不做 DDNS/BOOTP/PXE。
- 绝不修改路由器、不写 `/etc/bootpd.plist`、不启用系统"互联网共享"（后者是否可作替代**需验证**，初版不用）。

### 5.3 路由边界

- full 模式：included `0/0`；excluded = 回环、本机 LAN 子网、组播/广播、mDNS、其它 utun 子网。
- 网关模式：excluded 追加专用接口子网；DHCP 是链路层广播，不经过 IP 路由，因此不受 TUN 影响；DNS 指向 VIF，经 TUN 由扩展应答。
- 冲突：其它 VPN 已占默认路由 → 拒绝 full；split 模式改用 includedRoutes 白名单。

### 5.4 防止把家庭网络搞坏的检查清单

| 检查 | 判定 | 动作 |
| --- | --- | --- |
| 目标接口是否为默认路由接口 | 是 | 拒绝启动 |
| 该接口是否已有 DHCP server | 是 | 拒绝启动并说明 |
| 是否检测到其它 VPN 连接 | 是 | full 模式拒绝，提示改 split |
| 是否要改路由器/系统网络服务 | 永不 | — |
| 退出时 sysctl/pf 是否恢复 | 值仍等于我们设置的值才写回（CAS） | 不等则只报告 |
| 断电后客户端是否失联 | 租约 30min，客户端会重试 | 文档说明，不做"永久租约" |

## 6. 控制面与可观测

### 6.1 新增 action

| 方法 | 路径 | 语义 | 超时语义 |
| --- | --- | --- | --- |
| GET | `/v1/tunnel/status` | 只读；state/sessionId/vif/dns/routes/entitlement/lastError | 快 |
| POST | `/v1/tunnel/start` | 受理后立即返回 `{accepted,sessionId}`，进度走 SSE | 不占 10s 后台上限 |
| POST | `/v1/tunnel/stop` | 同上，返回后 SSE 推最终结果 | 同上 |
| GET | `/v1/routes/snapshot` | 读快照（`?id=latest`） | 快 |
| POST | `/v1/routes/restore` | 仅 tunnel 非运行时可用，返回逐项结果 | ≤15s |
| POST | `/v1/tunnel/recover` | 幂等清理残留 | ≤15s |
| GET | `/v1/tunnel/entitlement` | 签名/entitlement/审批状态，供 UI 引导 | 快 |

落地位置：`ControlBackend` 协议（`Sources/TouchFlowControl/ControlContract.swift:255-264`）加方法；`ControlServer` 的路由 switch（`:325-419`）、`actionName`（`:762-771`）、`allowedMethods`（`:777-787`）三处同步登记，否则 404/405。start/stop 必须"受理即返回"，不能踩 `callBackend` 的 10s 超时（`:435-439`）。

### 6.2 SSE 事件

| event | 频率 | data |
| --- | --- | --- |
| `flow` | 每条连接 | 现有 `ControlEvent`，**帧格式不变** |
| `tunnel.status` | 状态变化 | state/previous/cause/sessionId/since/failedItems |
| `tunnel.metrics` | 1s（可关） | pps/bps/conns/rssBytes |
| `routes.snapshot` | 快照生成 | snapshotId/takenAt/defaultRoute/hash |
| `routes.restore` | 每次恢复 | snapshotId/ok/failedItems |
| `dhcp.lease` | P4b 每条租约 | mac/ip/hostname/action/reason |

兼容性：`event: flow` 不变，老客户端忽略未知事件名即可；`id:` 沿用同一单调 seq，`?since=` 语义不变。回放缓冲从 `[ControlEvent]` 泛化为 `[SSEFrame(name,data)]`（`ControlServer.swift:186-192/247-251`）。

### 6.3 审计字段

现有 `ControlAuditRecord`（`Sources/TouchFlowControl/ControlContract.swift:186-209`）保持字段不变，**追加可选**：`kind`（control/tunnel/routes/dhcp）、`sessionId`、`snapshotId`、`outcome`（ok/partial/failed）、`detailJSON`。可选字段用 `decodeIfPresent` 解码，旧行不受影响。
单写者：Engine 持有 `AuditLog`，ControlServer 委托它写；扩展**永不**写该文件（避免多进程交错）。

### 6.4 Surface 约束与状态机

- 视图只发 action：即使 App 与 Engine 同进程，也走同一 `ControlBackend`（本地门面），保证远端面板/iOS 未来同语义。禁止再往 `TouchFlowEngine` 上加"给视图用的隧道方法"。
- 状态机：`disabled → installing → starting → running → stopping → disabled`，另有 `failed(reason)` 与 `rollback-failed(failedItems)`；`running` 下可有 `degraded`（DNS 正常、UDP 降级）。状态与 `EngineState`（`Sources/TouchFlowRuntime/TouchFlowEngine.swift:9-23`）分开，因为代理可以运行而隧道未启动。
- `ControlStatus` 只**追加** `tunnelState` 字段，不改既有字段，避免破坏 `/v1/status` 消费者。

## 7. 性能预算与验收标准

| 指标 | 门槛 | 来源 | 测量方法 |
| --- | --- | --- | --- |
| 空闲 RSS（App+扩展） | < 80MB；扩展单进程 < 45MB | 路线图 §8（合并值）；拆分值为本文提出 | 预热 2min 后静置 5min，`footprint -p`/`vmmap -summary` 1Hz 取中位数，3 轮 |
| 每千连接增量 | < 30MB | 路线图 §8 | 10 轮 × 100 条空闲连接（保持 60s），测 RSS 斜率，取线性回归 |
| 空闲 CPU | < 1%（5min 中位数） | 路线图 §8「≈0%」量化 | `top -pid <pid> -l 60 -s 5 -stats cpu` |
| 隧道建连到可上网 | p95 < 800ms | 本文提出 | `POST start` 到 canary 成功，20 次 |
| 正常停止到路由复原 | p95 < 500ms | 本文提出 | 停止到默认路由离开 utun |
| 异常退出的路由复原 | ≤ 2s | 本文提出（§5 只写"原子完成"） | `kill -9` 扩展，10 次，取最大 |
| 回滚残留 | 0 项 | 本文提出 | `route/sysctl/pf/DHCP/扩展配置` 逐项对比快照 |
| DNS 缓存命中 | p95 < 2ms | 本文提出（对照 `docs/perf.md` §4 的 16ms） | `tfctl dns --trace` × 200 |
| DNS 首查 | p95 < 150ms | 本文提出（对照 37ms 基线） | 同上，冷缓存 |
| Fake-IP 应答 | p95 < 1ms | 本文提出 | 解析侧计时 200 次 |
| 单流吞吐（direct，LAN 对端） | ≥ 200Mbps 且 ≥ 系统代理基线 60% | 本文提出，实现后校准 | 对端 `python3 -m http.server` + `curl --noproxy '*' -o /dev/null`，3 次取中位 |
| 新建连接额外时延 | p95 ≤ 15ms（相对系统代理） | 本文提出 | 同目标 200 次建连对比 |
| 规则 explain 覆盖率 | 100% | 路线图 §8 | 任取 200 条 TUN 连接，均可读出 chain |

测量约束（诚实说明）：吞吐必须有**第二台设备**做 origin，本机自连会命中本地投递而不进隧道；现有 `scripts/bench.sh` 的 origin 在 18080 本机，不能直接复用。上述"本文提出"的门槛在 P4a-2 结束时用实测数据替换，替换结果写回本文件，不留在口头。

## 8. 风险与缓解

| # | 风险 | 触发场景 | 缓解 |
| --- | --- | --- | --- |
| 1 | TUN 抢路由导致断网 | 启动即 full 接管、扩展异常 | 路由交给 NE settings；excluded 覆盖 LAN/回环/mDNS；启动 5s 内未 running 自动停；§4.6 回滚失败 UI；不手工写默认路由 |
| 2 | 与其它 VPN 客户端冲突 | 用户同时开 Tailscale/WireGuard/公司 VPN | 预检其它 utun 与 `scutil --nc list`；full 模式拒绝；提示改 split；文档写"同一时刻只能有一个默认路由接管者" |
| 3 | macOS 版本差异 | 14/15/26 的扩展审批入口、sleep/wake、扩展替换行为不同 | 三档真机矩阵；关键 API 分支用 `#available`；每条差异先写"需验证"再测 |
| 4 | 签名/公证/审批 | entitlement 被拒、profile 过期、公证失败 | P4 第 1 周先打通 development profile；保留上一公证版本；审批提前量按 2–4 周估（**需验证**） |
| 5 | App Store 沙箱 | 未来想上架 | 本期不做 App Store：沙箱下特权助手/pf/DHCP/MITM CA 均不可行；Developer ID 直装是唯一路径 |
| 6 | TCP 栈正确性 | 重传/零窗口/分片边界 | 只做 IPv4；不支持即 RST 不挂起；用系统代理路径做字节级对照；长稳测试沿用 `docs/perf.md` §5 的 500 并发模型 |
| 7 | 性能不达标 | 每包一次 Data 拷贝、扩展进程开销 | 缓冲区池化、16KB 分块、尽早测 RSS/吞吐；不达标先降连接上限而不是糊过去 |
| 8 | 配置快照不一致 | 扩展读到旧规则/旧出站 | snapshot hash + sessionId 校验；reload 走 provider message；不匹配拒绝启动 |
| 9 | 泄漏（DNS/IPv6） | 应用绕过 DNS 设置、IPv6 直连 | VIF 内应答 DNS；IPv6 快速失败；启动自检 canary 域名；UI 明示"已接管" |
| 10 | 回滚逻辑自身出错 | 误删别人的路由/sysctl | 只删"接口名是我们"的路由；sysctl/pf 用 CAS（旧值匹配才写）；恢复前先出 diff |

## 9. 分阶段落地建议

每阶段都以"能测的验收项"结束；未列出的能力一律视为**当前未实现**。

### P4a-0（约 1 周）扩展骨架 + 控制面状态机（无数据面）

- 交付：`TouchFlowTunnel` target（空 provider）、App Group 快照、`/v1/tunnel/*` 动作、`tunnel.status` SSE、审计可选字段、只读隧道面板。
- 验收：development profile 下能激活/停用；`includedRoutes` 只含测试网段（禁止 0/0）；启动后默认路由指向 utun ≤ 2s，停止后复原 ≤ 500ms；`kill -9` 后路由复原 ≤ 2s 且审计有 `tunnel.failed`；注入一次恢复失败 → banner + `rollback-failed` 审计可复现。
- 未实现：任何 IP 包处理（此时是黑洞，所以只允许测试网段）。

### P4a-1（约 1.5 周）DNS + Fake-IP 闭环

- 交付：`DNSResponderCore` 抽取、VIF DNS 应答、Fake-IP 反查接入数据面、blocker 生效、`fakeIPFilter` 生效、IPv6 快速失败。
- 验收：`curl --noproxy '*' http://<被拦截域名>` 得到 403/阻断；`dig` 命中 VIF；广告域名返回配置的 blockResponse；fake-IP 反查命中率 100%（有映射时）；抓包确认无 IPv6 出站；DNS p95 达标。
- 未实现：除 DNS 外的 TCP/UDP 转发。

### P4a-2（约 2 周）TCP 全接管

- 交付：最小 TCP 栈、`OutboundDialer` 绑物理接口、`BytePump` 适配、`ProcessAttributor` 5 元组归属、规则链在 TUN 连接上可见。
- 验收：`curl/nc/git/ssh` 走 TUN 成功；10 个常用 App 冒烟；1000 空闲连接 RSS 增量 < 30MB；吞吐与建连时延达标；每条连接可 explain；1 小时长稳 FD/RSS 收敛。
- 未实现：UDP（除 DNS）、ICMP 隧道、MITM over TUN。

### P4a-3（约 1 周）UDP/ICMP 与硬化

- 交付：UDP 按 outbound 能力降级（direct 可 relay；ss/trojan 明确失败）、ICMP echo 本机、失败码统一、UI 降级提示。
- 验收：QUIC 应用可观测到回退 TCP；UDP 失败是"快速失败"不是挂起；500 并发随机中断后进程存活、FD 收敛；`docs/perf.md` §5 的断言在本路径复跑通过。
- 未实现：UDP over 代理、SACK/拥塞控制优化、IPv6 数据面。

### P4b（约 2 周）网关 + DHCP（依赖特权助手）

- 交付：专用接口选择、DHCP（默认关）、转发、租约/拒绝事件、全局状态快照与 CAS 恢复、特权助手最小权限接口。
- 验收：见 §5.4 清单逐条可测；断电重启后无 sysctl/pf/DHCP 残留；在含 DHCP server 的接口上启动被拒绝且提示可读；不使用 DHCP 时家庭 LAN 无任何改动。
- 未实现：NAT/pf 方案、同网段抢 DHCP、IPv6 RA/DHCPv6、多网段策略。

### P5 / P6 前置（只做门禁，不排期）

- P5（Tailscale）：Tailscale 自己就是 utun + 默认路由，与本设计正面竞争。P4 必须先把"其它 utun 检测 + split 模式"做对，否则 P5 一定返工。P5 需要自研 userspace WireGuard（路线图 §7.4 估 ~800 行）与"分流而非抢占"的策略。
- P6（Ponte/MTProto/授权）：依赖设备身份（P2）+ 控制面 scope + 服务端。P4 的审计字段与 action 语义是它的地基；本期只保证"不挡住它"。
- 未实现：以上全部。

## 10. 当前明确未实现

TUN/VIF、NEPacketTunnelProvider、系统扩展打包、entitlement/公证、路由快照与恢复、网关、DHCP、`tunnel.*`/`routes.*` action 与 SSE、审计新字段——**均未实现**。
仓库现状：无 entitlements 文件、无 tunnel target、无 NE 代码、Fake-IP 反查无调用方、SSE 只有 `flow`。
本文的所有数字门槛（除标注"路线图 §8"与 `docs/perf.md` 的基线外）都是**待实测校准的提议值**。

## 11. 开工前需要拍板的两个 P1 接口变更（本文不实施）

这两处会改到 P1 已交付代码，但不做就无法承载 tunnel 事件与回滚取证。建议在 P4a-0 开工前单独评审：

1. **SSE 帧泛化**：`ControlServer.sseFrame(_:)` 把 `event: flow` 写死，回放缓冲是 `[ControlEvent]`
   （`Sources/TouchFlowControl/ControlServer.swift:186-192`、`:247-251`）。P4 需要 `tunnel.status` / `routes.changed`
   等新事件类型，必须先把回放缓冲与帧构造抽成通用事件（保留 `flow` 的线上格式不变）。
2. **审计单写者 + 可选字段**：现在审计由 `ControlServer.appendAudit` 直接写文件，字段固定
   （`Sources/TouchFlowControl/ControlContract.swift:186-209`）。P4 的回滚失败、路由快照、DHCP 拒绝需要
   结构化取证并保证与动作同序；建议改为 Engine 单一写者、`ControlAuditRecord` 追加可选字段（向后兼容旧读取方）。

两项都**未实现**；本文只记录取舍与影响面。

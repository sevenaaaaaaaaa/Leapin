# 手机独立运行（iOS / Android）

> 结论先说：iOS 与 Android 都要能**不依赖 Mac** 跑代理。Mac 是配置源与联动对象，
> 不是运行前提。2026-11-20 之前仓库里写的「移动端只是控制台」，是当时的实现状态
> 被当成了产品定位，已改正（见 CLAUDE.md「移动端定位」）。

## 已经证实的部分（M1，2026-11-20）

共享引擎 `LeapinNet` / `LeapinPolicy` 在 iOS 上**能编译、能跑、能转发真实流量**：

- 模拟器截图：App 内 `ProxyServer` 监听 `127.0.0.1:51003`，经它取 `https://example.com`
  返回 HTTP 200 / 577 字节（走的是 CONNECT → 上游 TLS → 双向泵）。
- 证据来源：工具页「本机代理引擎」卡片；DEBUG 下可用
  `LEAPIN_MOBILE_LOCAL_PROXY=1` 启动时自动跑一次自检。
- 这条路径与桌面端是同一份代码（`Sources/LeapinNet`、`Sources/LeapinPolicy`），
  不是为手机写的简化版。

也就是说：**引擎早就能在手机上跑**，缺的是「系统把流量交给它」这一层。

## 三层结构

| 层 | 做什么 | iOS | Android |
| --- | --- | --- | --- |
| 接管层 | 抓系统流量（TUN），把 TCP/UDP 流转成到本地代理的连接 | NetworkExtension Packet Tunnel Provider | `VpnService` |
| 转译层 | TUN 包 ↔ 代理连接（tun2socks） | 内嵌 hev-socks5-tunnel（MIT）或自写最小栈 | 同上，JNI 调用 |
| 引擎层 | 规则分流、DNS、出站（DIRECT/REJECT/SS/VMess/…） | 现有 Swift 引擎（已验证） | 见下 |

Android 的引擎层有两种选择，二选一：

1. **复用桌面已有的 mihomo 托管内核**：打包 arm64 Android 版，`VpnService` 提供 TUN，
   mihomo 直接跑 tun 模式。代价是规则语义与桌面 mihomo 模式一致，Swift 引擎不参与。
2. **Kotlin 侧实现代理管线**：规则引擎与出站协议要重写一遍，工作量最大，但语义与 iOS 完全一致。

建议先走 1（最快让 Android 独立可用），把 2 作为长期收敛方向。

## 签名与分发（唯一的硬门槛，不是工程选择）

- iOS 的 NetworkExtension 需要 `com.apple.developer.networking.networkextension`
  entitlement（`packet-tunnel-provider`）。**免费 Apple ID 签名装不上这个扩展**，
  AltStore/Sideloadly 用免费账号签的包会直接启动失败。要有它，必须付费开发者账号
  （个人 $99/年或团队账号）。没有账号时，iOS 只能做到「App 在前台时自己监听
  127.0.0.1」，也就是 M1 的状态。
- Android 没有对应门槛：`VpnService` 属于普通能力，侧载 APK 即可用，只需在
  首次启动时让用户点一次「允许建立 VPN 连接」。

## 里程碑

- **M1（已完成）**：引擎跑在手机上，回环代理 + 自检。桌面/手机同源。
- **M2（iOS 接管）**：新增 `LeapinTunnel` 扩展 target；TUN → tun2socks → 现有引擎；
  主 App 用 `NETunnelProviderManager` 装载配置；规则/出口来自本地配置，Mac 在线时同步。
  前置：付费团队 ID 写进 project.yml 的 `DEVELOPMENT_TEAM`。
- **M3（Android 接管）**：`VpnService` + mihomo 内核；配置由 App 自己的文件提供，
  Mac 只负责同步，不作为运行前提。
- **M4（同步与联动）**：配置双向同步（版本只增不改，冲突按设备 override）；手机离线时
  用本地快照，恢复后合并；Mac 端「手机连接」卡保留，用于下发与观测。

## 页面如何随之变化

M1 之后工具页就是「手机自己」的入口，而不是「没有 Mac 时的备胎」：

| 页面 | M1 | M2/M3 之后 |
| --- | --- | --- |
| 工具 | 本机网络 / DNS / HTTP 探测 / 本机代理自检 | 增加「启动 VPN」主按钮与接管状态 |
| 状态 | 已配对时显示 Mac 快照 | 显示**本机引擎**状态；Mac 快照变成第二张卡 |
| 连接 | Mac 的连接列表 | 本机实时连接（引擎自己产出 FlowEvent） |
| 策略 | Mac 的分组 | 本机规则与分组，Mac 在线时显示「已同步」 |
| 诊断 | 经 Mac 探测 | 本机解释 / DNS 溯源 / 探测，Mac 变成可选的对照 |

## 验证口径

- 引擎：`swift test`（桌面同款用例）+ 真机自检（经 127.0.0.1 取 example.com）。
- 接管：iOS 用 `NETunnelProviderManager` 装载后抓 `nettop` 确认流量进入扩展；
  Android 用 `VpnService` 启动后确认 `ip rule` 指向 tun，且断网时规则仍生效。
- 不使用「能编译」当作「能运行」的证据。

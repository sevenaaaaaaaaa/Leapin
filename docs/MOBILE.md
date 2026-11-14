# Leapin Mobile（iOS / iPadOS）

手机端控制台：在同一个 Wi-Fi 下查看并操作你 Mac 上的 Leapin。

- Bundle ID：`app.leapin.mobile`
- 最低系统：iOS / iPadOS 17.0
- 产物：`dist/LeapinMobile-1.0-unsigned.ipa`（未签名，见「安装」）
- 源码：`Mobile/LeapinMobile/`（Xcode 工程，不参与 SwiftPM 包）
- 工程描述：`Mobile/project.yml`（xcodegen 生成 `.xcodeproj`，不提交）

## 这一版做什么，不做什么

**做**：读取 Mac 控制面（`/v1/status`、`/v1/connections`、`/v1/policies` 等），在手机上显示运行状态、活动连接、策略组，执行重载规则、切换策略组、分流判定、DNS 追踪、HTTP 探测。

**不做**：手机上的系统级代理或 VPN。那需要 NetworkExtension（Packet Tunnel Provider）权限，只能在 Apple 开发者账号 + 描述文件里开启，并且请求权限的载体必须是同一个 Team 签名的主 App 与网络扩展两个 target。当前仓库没有开发者账号配置，所以这一版把手机端定位成**控制台 / 诊断端**，手机流量不经过它。

这也是 `README` 里「iOS 版需要 NetworkExtension 权限，暂未打包」的落地方式：先交付可用的控制台，网络接管留给有开发者账号的版本。

## 架构

```
Mobile/LeapinMobile/
  LeapinMobileApp.swift       App 入口、Tab 容器、错误横幅
  Control/ConsoleEndpoint.swift  地址解析 + Keychain 存令牌
  Control/ControlClient.swift    /v1 客户端（Bearer 鉴权）
  State/ConsoleStore.swift       单一状态源、5 秒轮询、动作封装
  Design/MobileTheme.swift       与桌面端同一套色板/排版 tokens
  Views/                         Setup / Dashboard / Connections / Policies / Diagnostics / Settings
```

移动端通过 SwiftPM 依赖 `LeapinCore`（Keychain、共享模型）与 `LeapinControl`（`ControlStatus`、`ControlConnection`、`ControlPolicyGroup`、`DNSTrace`、`HTTPProbeResult` 等 wire 模型），因此**契约只有一份**：控制面加字段不会出现手机端解析不到的问题。

## 为支持 iOS 改动的共享代码

`Package.swift` 早已声明 `.iOS(.v17)`，但有三处 macOS 专有调用挡住了编译。三处都改成平台条件编译，**macOS 行为不变**：

| 文件 | 原问题 | 处理 |
| --- | --- | --- |
| `Sources/CLeapinProc/proc.c` | 依赖 `libproc`（macOS 独有） | 非 macOS 编译为空实现：返回 0，表示「读不到」 |
| `Sources/LeapinNet/Support/ProcessAttribution.swift` | 同上 | `ProcessAttributor.process()` 在 iOS 直接返回 `nil`（沙箱读不到别人的 socket），`refreshLocked()`/`lookup()` 仅在 macOS 编译 |
| `Sources/LeapinNet/Capture/CertificateAuthority.swift` | 用 `Process` 调 openssl | iOS 不支持启动子进程，调用即抛错；手机端不做 TLS 解密 |
| `Sources/LeapinNet/Probe/ProxyPathProbe.swift` | `kCFNetworkProxiesHTTPS*` 在 iOS 标记 unavailable | iOS 只设置 HTTP 代理键，CONNECT 覆盖 https |

含义说清楚：**进程归属（这个连接是哪个 App 的）在 iOS 上永远为空**，这是系统沙箱限制，不是 bug。

## 构建

```bash
./Mobile/build-ios.sh          # Release 构建 + 打包 dist/LeapinMobile-1.0-unsigned.ipa
./Mobile/build-ios.sh debug    # Debug 构建（不打包）
./Mobile/build-ios.sh sim      # 只构建模拟器版本
```

需要：Xcode（验证于 27.0 / iOS SDK 27.0）、`xcodegen`（`brew install xcodegen`）。

脚本做的事：`xcodegen generate` → `xcodebuild -destination 'generic/platform=iOS'`（`CODE_SIGNING_ALLOWED=NO`）→ 把 `Leapin.app` 放进 `Payload/` 打包成 `.ipa`。

## 安装（未签名 IPA）

`dist/LeapinMobile-1.0-unsigned.ipa` 没有签名，不能直接双击安装。用任一自签工具导入，并用**你自己的 Apple ID** 签名：

1. **AltStore / SideStore**：把 IPA 传到手机，AltStore 里 + → 选择该文件 → 用你的 Apple ID 签名安装。
2. **Sideloadly**（Mac 或 Windows）：连上手机，拖入 IPA，填 Apple ID，Start。
3. 免费 Apple ID 签名的 App **7 天过期**，重签一次即可；付费开发者账号为 1 年。

首次打开需要在手机上确认「信任」：设置 → 通用 → VPN 与设备管理 → 开发者 App。

## 配对 Mac

1. 在 Mac 上启动控制面并允许局域网访问：

   ```bash
   leapin run          # 或者用桌面 App 打开「连接网络」；控制面默认 127.0.0.1:7900
   ```

   控制面默认只监听回环地址。要在手机上连，需要让它监听局域网（`ControlConfiguration.allowLAN = true`，桌面端对应设置项）或在同一台机器上做端口转发。**当前 CLI 没有暴露 `--lan` 开关给控制面**（`leapin sync serve --lan` 是同步服务，不是控制面），这一项在桌面端用设置界面打开。
2. 取令牌：

   ```bash
   cat "$HOME/Library/Application Support/Leapin/control-token"
   ```

3. 手机 App 首次打开：填 Mac 的局域网 IP、端口 `7900`、粘贴令牌 → 连接。令牌存进系统钥匙串，不会写进 `UserDefaults`。

## 验证记录（2026-11-14）

| 项目 | 结果 |
| --- | --- |
| iOS 设备构建（Release, arm64, unsigned） | 成功，产物 `Leapin.app` → `dist/LeapinMobile-1.0-unsigned.ipa`（1.0 MB） |
| Release 二进制不含调试注入 | `strings` 检查 `LEAPIN_MOBILE_TOKEN` = 0 处 |
| 模拟器构建 + 启动 | 成功，四个 Tab 均渲染（截图见 `docs/mobile/`） |
| 客户端 ↔ 真实控制面 | 用 App 内同一份 `ControlClient` 直连本机 `leapin run` 起的控制面，6/6 通过：`status`（engine=running, rules=4）、`connections`、`policies`、`explain`（policy=DIRECT）、`dns/trace`（source=upstream, 4 条 A/AAAA）、`http/probe`（status=200, tls=true） |
| 已连接界面 | 截图 `dashboard.png`：8 条活动连接、4 条规则、103 条去广告规则 |
| macOS 侧未被破坏（编译级） | `proc.c` 在 macOS SDK 下编译后仍引用 `proc_listallpids`/`proc_pidinfo`/`proc_pidpath`，iOS SDK 下 0 引用（空实现）；`ProcessAttribution.swift`、`ProxyPathProbe.swift`、`CertificateAuthority.swift` 用 macOS 14 SDK 类型检查通过 |

**未验证**：真实 iPhone/iPad 安装（需要你的 Apple ID 签名）、跨设备局域网（模拟器走的是宿主回环）、NetworkExtension 接管（本版不含）、Release 配置的运行时（Release 构建产物已验证打包与内容，但模拟器服务在收尾阶段卡在 `simctl install` 超时，未能跑起来；Debug 配置的运行时已完整验证）。

## 已知限制

- 控制面默认只听回环；手机连不上时先确认 Mac 端已允许局域网监听，以及 macOS 防火墙放行 7900。
- `NSAppTransportSecurity` 允许明文 HTTP：控制面是局域网明文 + Bearer 令牌，为连局域网 IP 必须如此。不要在公网暴露 7900。
- 策略组为空时（当前配置只有 4 条规则、没有 proxy-group），策略页显示空状态，这是真实状态。
- 手机端不缓存历史：连接列表是 Mac 当前窗口的最近 60 条。会话聚合与 HAR 导出仍在桌面端。

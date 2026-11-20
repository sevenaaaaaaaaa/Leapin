# Leapin 仓库规则

> 这份文件是本仓库的工作约定。任何 agent 或协作者在这里动手前先读它。

## 发布是四件事，缺一不算发完

用户对「发布」的定义是固定的。每次发布必须同时完成：

1. **构建三个平台**：macOS（App + CLI）、iOS（未签名 IPA）、Android（已签名 APK）。
2. **更新本机 App**：把 `/Applications/Leapin.app` 换成新构建，并核对版本号确实变了。
3. **打 tag 发布**：`v<版本>` 推上去，等 CI 构建并把产物挂到 GitHub Release。
4. **把三个安装包交给用户**：`Leapin-<版本>-macOS.zip`、`LeapinMobile-<版本>-unsigned.ipa`、`LeapinMobile-Android-<版本>.apk`，并说明各自怎么装。

只做构建不更新本机、或发版了却没把包交出来，都算没发完。

一条命令走完全部：`./scripts/release.sh <版本> [--yes]`。
步骤细节与坑：`docs/RELEASE.md`。

## 版本号规则

| 改动性质 | 位 | 例子 |
| --- | --- | --- |
| 修 bug、文案 | patch | 1.10.0 → 1.10.1 |
| 新平台 / 新功能 | minor | 1.9.0 → 1.10.0 |
| 破坏兼容 | major | 谨慎 |

手机端（iOS / Android）各有自己的版本号，当前都是 1.0。

## 构建的硬约束

- **桌面端必须用 Xcode 26+**：`Sources/LeapinApp` 用了 Liquid Glass（`glassEffect` / `GlassEffectContainer`），旧 SDK 编译期缺符号，`#available` 不解决问题。
- **SwiftPM 在 `.build` 里会偶发卡死**：改用 `--scratch-path /tmp/xxx --disable-sandbox` 重来，不要对同一路径反复重试。
- **Android 签名密钥不入库**：`Android/leapin-release.jks` 与 `keystore.properties` 已在 `.gitignore`；CI 用仓库 secrets（`ANDROID_KEYSTORE_*`）取同一把密钥，换密钥会导致 APK 无法覆盖升级。
- **CI 只在 `macos-26` 上能编过桌面端**（同上 Liquid Glass 原因）。

## 改动与提交

- 不主动 `git commit` 或 `git push`，除非用户明确要求。
- `dist/` 与 `Mobile/LeapinMobile.xcodeproj/`、`Android/app/build/` 都是产物，不入库。
- 提交信息用英文，`<type>: <what>`，正文写清为什么和验证到哪一步。

## 移动端定位

iOS 与 Android **必须能独立运行**：手机自己跑代理引擎、自己按规则分流，Mac 只是一个可选的配置源与联动对象，不是运行前提。

- 共享引擎（LeapinNet / LeapinPolicy）已经能编译并在 iOS 真机/模拟器上运行：App 内可直接监听 127.0.0.1 并按 SIP004 / HTTP / SOCKS5 转发，工具页有自检（经本机代理取 example.com 得到 HTTP 200）。
- 系统级接管：Android 走 `VpnService`（无额外签名门槛）；iOS 走 NetworkExtension 的 Packet Tunnel Provider，**需要付费开发者账号的 network-extension entitlement**，免费签名装不上——这是苹果的签名限制，不是工程判断。
- 配置同步与联动：Mac 的配置 / 规则 / 出口可以下发到手机，手机上改的分组也能回传；连不上 Mac 时手机用自己的本地配置继续跑。
- 「控制台」只是手机的一个页面集合，不再是它的定位。

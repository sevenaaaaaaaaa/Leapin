# Leapin Mobile（Android）

手机端控制台：在同一个 Wi-Fi 下查看并操作你 Mac 上的 Leapin。与 iOS 版功能对齐，共用同一份 `/v1` 控制契约。

- 包名：`app.leapin.mobile`
- 最低系统：Android 8.0（API 26），targetSdk 34
- 产物：`dist/LeapinMobile-Android-<版本>.apk`（用发布密钥签名，可直接侧载）
- 源码：`Android/`（Kotlin + Jetpack Compose）

## 做什么，不做什么

**做**：读取 Mac 控制面（`/v1/status`、`/v1/connections`、`/v1/policies`、`/v1/explain`、`/v1/dns/trace`、`/v1/http/probe`），显示运行状态、活动连接、策略组，执行重载规则、切换策略组、分流判定、DNS 追踪、HTTP 探测。

**不做**：手机上的系统级 VPN。那需要 `VpnService` + 用户手动授权 + 前台服务，是另一个量级的工程（对应 iOS 的 NetworkExtension）。这一版同样只做控制台。

## 结构

```
Android/
  settings.gradle.kts / build.gradle.kts / gradle.properties
  gradle/wrapper/                 Gradle 8.9 wrapper
  app/build.gradle.kts            AGP 8.5.2, Kotlin 1.9.24, Compose BOM 2024.06
  app/src/main/java/app/leapin/mobile/
    MainActivity.kt               入口、底部四页、轮询
    ConsoleStore.kt               ViewModel：端点、状态、动作
    ControlClient.kt              /v1 客户端（HttpURLConnection，零网络依赖）
    Models.kt                     wire 模型，字段与 ControlContract.swift 一致
    TokenVault.kt                 Android Keystore AES-GCM 加密令牌
    ui/                           主题与六个页面
```

令牌不进明文存储：`TokenVault` 用 Android Keystore 里的 AES 密钥做 GCM 加密，密文存 SharedPreferences。

## 构建

```bash
./scripts/build-apk.sh        # → dist/LeapinMobile-Android-1.0.apk
```

需要 JDK 17（本机验证用 `/opt/homebrew/opt/openjdk@17`）和 Android SDK（`ANDROID_HOME`，默认 `~/Library/Android/sdk`）。签名读 `Android/keystore.properties`；没有该文件时 Gradle 回落到 debug key——能装，但换机器签名会变，升级时会冲突。

## 安装

1. 把 APK 传到手机（AirDrop / 网盘 / `adb install`）。
2. 首次安装要在系统里允许「安装未知来源应用」。
3. 打开后填 Mac 的局域网 IP、端口 7900、粘贴 `control-token`。

```bash
adb install -r dist/LeapinMobile-Android-1.0.apk   # 覆盖安装
```

## 与 iOS 版的一致性

| 能力 | iOS | Android |
| --- | --- | --- |
| 状态 / 连接 / 策略 / 诊断 | ✅ | ✅ |
| 令牌存储 | Keychain | Android Keystore（AES-GCM） |
| 明文 HTTP 到局域网 | ATS 放开（Info.plist） | `usesCleartextTraffic=true` |
| 系统级接管 | 需要 NetworkExtension | 需要 VpnService |
| 签名方式 | 用户自签（AltStore / Sideloadly） | 仓库侧发布密钥签名，直接侧载 |

## 验证记录（2026-11-14）

| 项目 | 结果 |
| --- | --- |
| `./gradlew assembleRelease` | 成功，`app-release.apk` 9.7 MB |
| 签名 | `apksigner verify` 通过，`CN=Leapin, OU=Sideload` |
| 包信息 | `app.leapin.mobile`、versionName 1.0、minSdk 26、targetSdk 34 |
| 编译错误修复 | `autoRefresh` 的私有 setter 与自定义 `setAutoRefresh` JVM 签名冲突，改为 `updateAutoRefresh` |

**未验证**：真机运行（没有连接 Android 设备，也没有启动模拟器）；跨设备局域网实测；`VpnService` 接管（本版不含）。

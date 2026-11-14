# 发布流程（每次发布都照这个走）

一条规矩：**发布 = 构建三个平台 + 更新本机 App + 打 tag 发版 + 把三个安装包交给用户。**
少任何一步都不算发完。

## 最快的路径：一条命令

```bash
./scripts/release.sh 1.10.1            # 交互确认后提交、打 tag、发版、等 CI
./scripts/release.sh 1.10.1 --yes      # 不询问
./scripts/release.sh 1.10.1 --no-push  # 只构建 + 更新本机 + 打包，不推送
./scripts/release.sh --check           # 只检查前置条件（Xcode 26+ / xcodegen / gh / JDK / SDK）
```

它按顺序完成：检查前置条件 → 改版本号 → 构建 macOS → **更新 `/Applications/Leapin.app`** →
构建 iOS 与 Android → 打包 + 校验和 → 提交并推 tag → 等 CI → 核对 Release 资产 → 打印三个包的路径。

下面的手工步骤是这条命令的内部实现，出问题时照着排查。

## 0. 判定是否要发版

| 改动性质 | 版本位 | 例子 |
| --- | --- | --- |
| 修 bug、文案、依赖小升级 | patch（1.10.0 → 1.10.1） | 修一个解析错误 |
| 新平台、新功能 | minor（1.9.0 → 1.10.0） | 新增 Android 端 |
| 破坏兼容（配置格式、数据目录） | major | 不轻易动 |

手机端（iOS / Android）有自己的版本号，当前都是 1.0，跟随桌面端的发版节奏走。

## 1. 改版本号

```bash
# 桌面端：两个字段一起改，build 号 +1
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.10.0" \
                        -c "Set :CFBundleVersion 20" scripts/Info.plist
```

手机端要升就改 `Mobile/project.yml` 的 `MARKETING_VERSION` 和 `Android/app/build.gradle.kts` 的 `versionName`。

## 2. 本地构建三个平台

```bash
./scripts/build-app.sh     # macOS App + CLI → dist/Leapin.app
./Mobile/build-ios.sh      # iOS → dist/LeapinMobile-1.0-unsigned.ipa
./scripts/build-apk.sh     # Android → dist/LeapinMobile-Android-1.0.apk
```

## 3. 更新本机 App（这一步最容易被忘）

替换 `/Applications/Leapin.app`，并确认版本号真的变了：

```bash
osascript -e 'quit app "Leapin"' 2>/dev/null; sleep 1
rm -rf /Applications/Leapin.app
ditto dist/Leapin.app /Applications/Leapin.app
defaults read /Applications/Leapin.app/Contents/Info.plist CFBundleShortVersionString   # 必须是新版本
codesign -v /Applications/Leapin.app && echo "signature ok"
open /Applications/Leapin.app
```

## 4. 打包与校验和

```bash
ditto -c -k --sequesterRsrc --keepParent dist/Leapin.app "dist/Leapin-<版本>-macOS.zip"
tar -czf "dist/leapin-<版本>-macOS-cli.tar.gz" -C dist/Leapin.app/Contents/MacOS leapin
cd dist && shasum -a 256 *.zip *.tar.gz *.ipa *.apk | tee SHA256SUMS.txt
```

## 5. 打 tag 发布（CI 负责出包）

```bash
git add -A && git commit -m "release: <版本>"
git push origin main
git tag -a v<版本> -m "Leapin <版本>"
git push origin v<版本>
```

`.github/workflows/release.yml` 会在 `macos-26` 上构建三个平台并挂到 Release。等它绿：

```bash
gh run watch --exit-status
```

## 6. 交付给用户

把三个文件发出来，并说明各自怎么装：

- `Leapin-<版本>-macOS.zip` —— 解压拖进「应用程序」
- `LeapinMobile-<版本>-unsigned.ipa` —— AltStore / Sideloadly，用本人 Apple ID 签名
- `LeapinMobile-Android-<版本>.apk` —— 直接侧载，允许「未知来源」

## 7. 核对清单

- [ ] `scripts/Info.plist` 版本号已改
- [ ] 三个平台的包都在 `dist/` 里且时间戳是本次
- [ ] `/Applications/Leapin.app` 版本号等于本次发布版本
- [ ] tag 指向的提交就是构建用的提交
- [ ] CI 绿，Release 四个资产（三个包 + SHA256SUMS.txt）齐全
- [ ] 三个安装包的路径已交给用户

## 已知的坑

- **必须用 Xcode 26+ 构建桌面 App**：`Sources/LeapinApp` 用了 Liquid Glass（`glassEffect` / `GlassEffectContainer`），旧 SDK 编译期就缺符号，`#available` 救不了。
- **SwiftPM 偶尔在 `.build` 里卡死**：换 `--scratch-path /tmp/build-xxx --disable-sandbox` 重来，不要反复重试同一路径。
- **Android 签名密钥**：`Android/leapin-release.jks` + `keystore.properties` 不入库；CI 侧存在仓库 secrets（`ANDROID_KEYSTORE_BASE64` 等）。换密钥会导致无法覆盖安装。

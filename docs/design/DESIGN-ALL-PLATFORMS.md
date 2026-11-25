# 三端统一视觉：一条路，一张纸，一个信号

> 2026-11-25。把 macOS 的 v5 设计语言推到 iOS 与 Android，让三个客户端读起来是一个产品。
> 依据：`docs/design/DESIGN-v5.md`（视觉系统、构图模板、验收）。本文只写「怎么映射到三端」。

## 1 一句话

**一条路**（RouteLine：你 → 判据 → 出口）、**一张纸**（纸面 + 每屏最多一个墨色焦点带）、**一个信号**（朱红只标当前决策 / 正在生效 / 需要你处理）。

## 2 三端对照

| 层 | macOS | iOS | Android |
| --- | --- | --- | --- |
| 表面 | `LP.paper / sheet / ink / line` | `LP.canvas / panel / ink / line` | `LP.canvas / panel / ink / stroke` |
| 字阶 | 28 / 15 / 13 / 11 mono / 20 mono | `LPFont.title/section/body/label/number` | 同左（sp） |
| 圆角 | 面板 12、控件 8 | `LP.radius 12` / `radiusSmall 8` | `LP.radius 14 → 12` |
| 一条路 | `Design/RouteLine.swift` | `Design/RouteKit.swift` · `RouteLine` | `ui/RouteKit.kt` · `RouteLine` |
| 焦点带 | `FocusBand` | `FocusBand` + `LPFact` + `OnInkButtonStyle` | `FocusBand` + `Fact` + `OnInkButton` |
| 页头 | `PageHeader`（壳统一渲染） | `LPPageHeader` | `PageHeader` |
| 首页 | 走哪：焦点带 + 证据区 | 这台手机的网络：页头 / 焦点带 / 两块证据 | 同左 |

## 3 本次改动

- **iOS**：`MobileTheme` 加 `ink / onInk`、字阶对齐 28/15/13/11/20、圆角 12；新增 `RouteKit`（RouteLine / FocusBand / LPFact / LPPageHeader / OnInkButtonStyle）；首页改成「页头 28 → 墨色焦点带（一条路 + 四事实 + 主按钮）→ 证据区两块」；连接 / 策略 / 诊断 / 工具四页换成 `LPPageHeader`，背景统一 `LP.canvas`。
- **Android**：`LP.ink / onInk`；新增 `ui/RouteKit.kt`（RouteLine / FocusBand / Fact / OnInkButton / PageHeader）；首页加焦点带（引擎状态 + 四事实 + 启停按钮）；连接 / 策略 / 诊断 / 工具四屏加 `PageHeader`。

## 4 验收

| 端 | 怎么验 | 结果 |
| --- | --- | --- |
| iOS | `qa/T-22` 8/8、截图 `docs/shots/v5-ios-{home,connections,policies,diagnostics,tools}.png` | 绿 |
| Android | `./gradlew --no-daemon --offline assembleDebug` → BUILD SUCCESSFUL；APK 落 `Android/app/build/outputs/apk/debug/` | 绿（无模拟器，未截图） |
| 三端一致 | 同一组色值、同一字阶、同一个 RouteLine 画法；见 §2 | 逐项对照 |

## 5 边界

- Android 这一轮只做视觉与结构，不动 VPN 权限流程（仍在工具页）。
- 三端都没有引入新依赖；Compose 与 SwiftUI 各用原生组件。
- Android 没有可用模拟器，**这一端只有编译验证**，观感要靠装 APK 后人工确认。

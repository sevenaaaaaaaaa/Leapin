# TouchFlow 设计评审 — 距离 Awwwards 还有多远

**评审基准**：`/tmp/tfbase/*.png`，浅色，1040×752，10 页逐张看（00 dashboard / 01 rules / 02 adblock / 03 capture / 09 settings 全看，04–08 抽查后补看全）。
**评审口径**：Awwwards SOTD / FWA / Webby 的 craft 标准 —— 不是"好看"，是"每一个像素都能被解释"。
**代码侧**：只读，未改任何 `.swift`。注意：评审期间仓库正被并发修改（`git status` 显示 `Design/Theme.swift`、`TouchFlowApp.swift`、`Views/Shared.swift` 已被改动，方向是暖纸 + vermilion + 去 rounded），所以下文**代码引用一律用符号名、不用行号**，行号已漂移。图形证据以基线截图为准。

---

## 0. 判决

| 维度 | 现在 | 获奖线 | 一句话 |
|---|---|---|---|
| Craft（细节执行） | 5.5 / 10 | 9 | 单个组件做得干净，组件之间没有系统 |
| Typography | 4 / 10 | 9 | 15 个字号，正文 10–11.5pt，圆角字体 |
| Color | 3.5 / 10 | 9 | 5 种强调色 + 4 套渐变，零语义 |
| Hierarchy | 5 / 10 | 9 | 卡片们平权，一屏里两个一样大的主 CTA |
| Originality | 3.5 / 10 | 8 | 这是 2023 年 Linear / Vercel 模板的浅色版 |
| Motion | 3 / 10 | 8 | 唯一该有动效的地方（抓包流）没有动效，装饰在动 |
| Responsive | 3 / 10 | 7 | 宽度预算没算过，最小窗口恒差 1pt |
| Micro-interaction | 5 / 10 | 9 | 有 hover 有 spring，但键盘焦点只有 1 个控件有 |

**总评：这是一份"正确但匿名"的实现。** 它没有错（对齐、留白、圆角、配色都在安全区），但它可以被任何一个人用"做一个 macOS 网络工具的 SwiftUI 界面"这句话 + 一份 2023 年的 Linear 截图生成出来。获奖作品的标准是「换掉任何一个元素，整体就散了」；现在换掉整页配色和字体，它还是同一个 App —— 这说明设计语言没有在做功。

真正的问题不是"哪个地方不好看"，而是**这个 App 没有自己的声音，而且它的视觉预算分配反了**：装饰（渐变、光斑、圆角图标块、阴影）拿了全部预算；信息（数字、行、状态、可操作性）拿了剩下的。

---

## 1. 先说清楚：哪些东西是 AI 通用审美

这一节是后面所有建议的前提。以下 10 条，任何一条出现在作品集里都会被评委归入"模板感"，而 TouchFlow 十条全中：

1. **极光光斑** —— `TFBackground` 两团 `Circle` blur 120/130（accent 10% / mint 8%）。2021 年 Stripe 带火的配方，现在等于"我没有背景设计能力"的招供。
2. **蓝紫品牌渐变** —— `TF.brand = LinearGradient(accent #3D6BFF → violet #7B5CFF)`，用在 logo、三个主按钮、hero 渐变底。这是"AI startup"最饱和的视觉签名，而且它把两个都没有语义的颜色绑在一起。
3. **圆角系统字体** —— `TFFont.display` / `TFFont.num` 全部 `design: .rounded`。"默认配置" 21pt rounded、"0" 24pt rounded：这是消费级 App 的语气，放在一个会显示 `IP-CIDR 172.16.0.0/12` 的工具里，像给示波器贴了卡通贴纸。
4. **五等分彩虹统计卡** —— 总览 5 张 `StatTile`：蓝（活动连接）/ 红（已拦截）/ 紫（抓包）/ mint（流量）/ amber（规则）。五种颜色互不构成系统，且红 = 坏事的直觉被用在了"拦截成功"这件好事上。
5. **每张卡都长一样** —— `TF_PanelModifier` 给全 App 每一块内容同一个白底 0.86 + 14pt 圆角 + 1px 10% 描边 + 0.06 阴影 r14 y6。当所有东西都浮起来，就没有东西浮起来。
6. **24pt 着色圆角方块图标** —— `SectionHeader` 的 tint 14% 底 + 11pt SF Symbol。全 App 30+ 个，设置页一屏 6 个。它是"卡片标题需要装饰"的肌肉记忆，不是信息。
7. **空状态模板** —— 居中 26pt thin SF Symbol + 11.5pt 灰字 + 一句说明。4 个页面同一套，其中 2 个（抓包、发现）连 CTA 都没有。
8. **虚线投放区** —— 学习页 264×112 dashed 圆角 12。Figma / Notion 模板的直系后代。
9. **mint 环形分数盘** —— 隐私页 100 分 conic 渐变环。这是从健身 / 睡眠 App 借来的情感语言（"你的睡眠得分"），而它算的是一个全 0 的仪表盘。
10. **紫色的"去广告"徽章 / 红色的"已拦截"数字** —— 颜色被当装饰用完，就没有颜色留给"这是什么状态"。

> **判断标准**：把一个元素拿掉，如果没有人会注意到 —— 它就是装饰，应该删。这 10 条全部通过这个测试。

---

## 2. 八个维度

### 2.1 Typography

**现状证据**
- 基线 `TFFont` 调用里出现 **15 个不同字号**：7.5 / 8.5 / 9 / 9.5 / 10 / 10.5 / 11 / 11.5 / 12 / 12.5 / 13.5 / 14.5 / 20 / 21 / 24。
  其中 9.5 → 12.5 之间**挤了 7 档，每档相差 0.5–1pt**。0.5pt 在 Retina 上是 1 物理像素 —— 用户看不见这个差别，只能感觉到"文字有点乱"。
- 正文实际落在 **10–11.5pt**：卡片说明 10.5、`SectionHeader` 副标题 11、页头副标题 11.5、Badge 9.5、侧栏 kicker 7.5（`NETWORK CONTROL`）、复制图标 8.5。macOS HIG 的正文是 **13pt**，11pt 是 small，10pt 是 mini。**这个 App 把 mini 当 body 用。**
- 两个层级只有 1pt 之差的地方到处都是：`SectionHeader` 标题 13.5 / 副标题 11；卡片标题 12.5 / 说明 10.5。层级差 < 1.35×，在 10pt 尺度上等于没有层级。
- 数字用 `.rounded` + `monospacedDigit`（00/01/02 的 "0"、"9"、"7898"）。`.rounded` 的 0 带圆角转角，在 24pt 下是可见的"软" —— 而网络工具的数字应该是**仪表读数**。
- `StatTile` 的值有 `lineLimit(1) + minimumScaleFactor(0.7)`：5 张卡在同一行、宽度各 ~145pt，任何一张值变长（`1.2 GB` → `12.3 GB`，或"已开启"这种文本塞进数字位，见 02 第三张卡）就会**独自缩字号**，同一行的数字光学大小不再一致。这是 typography 里最致命的一类错误：读者会以为"变小了的那个不重要"。
- 行长失控：08 配置页有整段 10pt 说明**横跨 727pt**（≈110 字符/行）。可读上限是 68ch。

**基准差距**
获奖作品的字号阶梯通常只有 **5–6 档**，且**相邻档位至少 ×1.25**（例如 11 / 13 / 17 / 22 / 30）。它们把"层级"编码在**字重 + 字距 + 大小写**，而不是 0.5pt 的寸差。数据类界面（Bloomberg、Charles、Proxyman、Fluke 表盘）会有一个专属的**数字字体角色**：等宽、tabular、与正文完全分离。

**修法（SwiftUI 原语级）**

`@swift
// 1) 收成 6 档 + 显式角色，删掉其余 9 个字号
enum TFFont {
    case display   // 28 .semibold  tracking -0.6
    case title     // 17 .semibold  tracking -0.2
    case body      // 13 .regular              <- 正文从 10-11.5 抬到 13
    case caption   // 11 .regular  color: textSecondary
    case micro     // 10 .semibold tracking 1.4 UPPERCASE（只用于 overline，全文不超过 6 处）
    case data      // 12 .regular .monospaced  <- 所有数字/域名/IP/端口/路径
}

// 2) 页面标题：现在 20 bold rounded -> 改成
Text(title)
    .font(.system(size: 28, weight: .semibold))
    .tracking(-0.6)                      // 大字号负字距是"贵"的来源
// 3) 页头副标题：11.5 sans tertiary -> 改成仪器铭牌
Text(subtitle.uppercased())
    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
    .tracking(1.4)
    .foregroundStyle(TF.textTertiary)
// 4) 数字：.rounded -> .monospaced + 关掉自救式缩放
Text(value)
    .font(.system(size: 24, weight: .semibold, design: .monospaced))
    .monospacedDigit()
    .lineLimit(1)
    .truncationMode(.tail)              // 不要 minimumScaleFactor，宁可截断也不缩
    .contentTransition(.numericText())  // 数值变化时滚动，而不是跳变
// 5) 长说明加测量
Text(desc).frame(maxWidth: 560, alignment: .leading)   // 约 68ch @ 10pt
`@

**还有一件没人做但很值钱的事**：全局正文改成 13pt 后，用 `ScaledMetric`（或至少接 `DynamicTypeSize`）让系统"更大文字"生效。现在所有字号硬编码，无障碍字号放大等于失效。

---

### 2.2 Whitespace

**现状证据（这是最割裂的一维）**
- **总览页：挤到爆。** 首屏 430pt 高全部用来讲"0"：hero 卡 ~160pt + 与 hero 启动按钮**完全重复**的"第一步"引导条 60pt + 5 张空数据 StatTile 100pt。真正有价值的"最近连接"被压到 y≈690，只露一个标题就被折叠线切断。
- **配置页：空到荒。** 内容在 y≈447 结束，下面 300pt 纯背景。
- **抓包页：双倍死白。** `HSplitView` 两栏各 ~500pt 高，每栏一个垂直居中的空状态；两条主信息（"暂无 HTTP 请求" / "选择左侧请求查看详情"）在争同一件事，且**都没有 CTA**。
- 同一 App 里总览页密度 ≈ 8 个信息块/屏，配置页 ≈ 2 个/屏 —— **没有密度策略**，说明留白是每个 View 各自"感觉一下"决定的，不是系统。

**基准差距**
获奖作品的留白是**有刻度的**：一套 4/8/12/16/24/32/48 的间距标尺，任何两元素间距必须落在标尺上；卡片内 padding 与卡片间距有固定比例（通常内 16 / 外 24）。TouchFlow 有 `TF.gutter = 18` 这个 token 却**基本没被使用**，实际值散落成 12/13/14/16/20/22/26 一堆手写数字。

**修法**
`@swift
enum TFSpace { static let s1: CGFloat = 4, s2 = 8, s3 = 12, s4 = 16, s5 = 24, s6 = 32, s7 = 48 }
// 卡片内 padding 一律 s4(16)，卡片间距一律 s5(24)，页面边距 s6(32)
`@
具体到总览页：hero 160 -> **96pt**（标题与按钮同一基线，orb 92 -> 56），删掉"第一步"整条（信息合并进 hero 的一行 12pt 提示），5 张 StatTile -> **4 张可换行**，把"最近连接"整卡提上首屏 —— 这是全 App 唯一会持续变化的内容，它应该在首屏。抓包页：左栏空态保留并**加 CTA**，右栏空态降级为一行内联提示，不占整卡。

---

### 2.3 Visual hierarchy

**现状证据**
- **主 CTA 通货膨胀**：总览页同一屏内有两个"启动代理"渐变按钮（hero 右上 + 引导条右侧），加上侧栏底部第三个。NAS 页同一屏两个"开始扫描"（卡片内 + 空状态中央）。当一屏有 2 个一样的主按钮，**主按钮就不再是主按钮**。
- **卡片平权**：`TF_PanelModifier` 让"当前配置"hero、"本地端点"、"白名单"、"挂载说明"全部同一视觉重量。读者无法通过视觉判断"先看哪"。
- **页面级 3 层结构，但没有第 4 层**：页头（20 bold）/ 卡片标题（13.5 semibold）/ 正文（10.5）。缺的是**"这一步最重要的一件事"**这一层 —— 也就是 hero 应该承担、但被装饰用掉的那一层。
- 表头缺失：01 分流规则 9 行规则**没有列头**。哪一列是类型、哪一列是策略、右侧绿字是"目标"还是"状态"全靠猜。这是信息架构层的缺失，不只是排版。
- 状态色反向：02 "元素隐藏"把字符串 `已开启` 塞进 24pt 数字位，与左边的 `0`、`0` 并排 —— 同一行里两个数字一个状态，读者第一眼会把它读成"三个数字"。

**基准差距**
获奖线的做法是**每屏只有一个视觉主角**，其余元素按"支持 / 参考 / 背景"三档降级，且降级手段是**字重 + 灰阶 + 描边**，不是"再加一张卡"。

**修法**
`@swift
// 1) 一屏一个 primary：层级用语义，而不是再加一种颜色
enum TFButtonRank { case primary, secondary, quiet }
// primary 全 App 每屏最多 1 个（靠 review 规则约束，不靠 API）
// 2) 主角卡用"抬升"而非"渐变"区分：唯一保留阴影的层级
extension View {
    func tfRaised() -> some View { /* 白实底 + 0.10 阴影 r24 y10，每屏只用 1 处 */ }
    func tfFlat()   -> some View { /* 去阴影，只留 1px hairline，其余全部改这个 */ }
}
// 3) 规则表加列头（mono 9.5 uppercase tracking 1.2），用 Grid 对齐
Grid(alignment: .leading, horizontalSpacing: 12) {
    GridRow {
        Text("#").frame(width: 28, alignment: .trailing)
        Text("TYPE").frame(width: 78, alignment: .leading)
        Text("VALUE").frame(maxWidth: .infinity, alignment: .leading)
        Text("POLICY").frame(width: 80, alignment: .trailing)
    }.font(.system(size: 9.5, weight: .medium, design: .monospaced)).tracking(1.2)
}
// 4) 状态值不进数字位：拆成 StatTile(value:number) 与 StatTile(state:String)
`@

---

### 2.4 Color

**现状证据**
- token 有 7 个强调色（accent / violet / mint / amber / danger / success + brand 渐变），**没有一个承载固定语义**：mint 同时表示"直连"（01 DIRECT）、"累计流量"（00）、"使用中"（08）、"DNS 安全"（07 状态点）。violet 同时是品牌色、抓包数、PROXY 策略、"当前配置"徽章。
- **4 套互不相干的渐变**：`TF.brand`（accent -> violet 线性）、`TF.mintGradient`（mint -> accent 线性）、隐私页环形 `AngularGradient`（mint 三停）、SSH 终端 `#0B1020` 深 navy（既不是 `TF.bg` 深色 token，也不是任何 token）。四套渐变 = 四个设计者的痕迹。
- **系统色泄漏**：01 与 06 页右上"系统代理"开关外圈有一圈 macOS 系统蓝（约 #0B84FF）焦点框；01 策略组的 `NSPopUpButton` 自带 AppKit bezel 与蓝色 chevron。这两个蓝都不是 `TF.accent`（#3D6BFF），在浅薰衣草背景上一眼能看出来。
- **对比度**：`TF.textTertiary` #5F6C82 在 `TF.bg` #F3F5FA 上约 **4.9:1**（勉强过 AA），但一旦落到 accent 14% 的 chip 底上就掉到 **约 4.4:1**，已经在 AA 线下 —— 而 9.5pt 的 Badge 正好是那种底。
- 红用于"已拦截"（好事）、amber 用于"规则"（中性）—— 颜色语义与业务语义冲突。

**基准差距**
获奖级工具（Charles、Proxyman、Raycast、Linear 深色）普遍是**近单色 + 一个信号色 + 4 个状态色**，且状态色**只在非文字元素上出现**（小圆点、2pt 左边条、图标），从不用整块填充。颜色的"少"本身就是高级感的来源。

**修法**
`@swift
enum TF {
    // Ink scale：只有 4 级
    static let ink      = Color(hex: 0x141310)   // 主文字
    static let inkMid   = Color(hex: 0x4A4740)   // 次文字
    static let inkFaint = Color(hex: 0x8A8578)   // 注释（比 #5F6C82 更暖更淡，但字号抬到 13 后反而更可读）
    static let rule     = Color(hex: 0xE2DFD7)   // 唯一的分隔线色（替代 10% 黑 stroke）
    // Signal：一屏 <=3 次
    static let signal   = Color(hex: 0xC63A12)
    // State：只用于 dot / bar / glyph，不用于填充
    static let ok = Color(hex: 0x0C7A55), warn = Color(hex: 0x8F5E07),
               bad = Color(hex: 0xB32636), route = Color(hex: 0x5446B8)
    // 渐变：全 App 只保留 0 个
}
// 干掉光斑
struct TFBackground: View { var body: some View { TF.bg } }   // 就这一行
// 干掉阴影，只留 hairline
.overlay(Rectangle().stroke(TF.rule, lineWidth: 0.5))
`@
并且必须**统一系统 accent**：系统 focus ring 的蓝无法用 `NSApp.appearance` 覆盖，解决方式是给所有自绘控件加自定义焦点环（见 2.6），并把 `Picker` 从 `NSPopUpButton` 换成自绘菜单 —— 否则系统蓝会永远在泄漏。

---

### 2.5 Motion（从静态图 + 代码推断）

**现状证据**
- **代码里 16 处 `.animation` / `withAnimation`，全部是 easeOut 0.10–0.20**，只有自绘 `TFSwitch` 用了 spring(.26, .82)。也就是说：**全 App 的运动曲线只有一种，且是"过渡"而不是"物理"**。获奖作品的运动是有性格的 —— 快进慢出、轻微过冲、有质量感。
- **唯一"想做转场"的地方其实是死的**：`AppModel.go()` 用 `withAnimation(.easeOut(0.12))` 包住页面切换，但 `RootView` 的 `sectionContent` 是裸 `switch`，**没有 `.transition` 也没有 `.id`** -> 10 页切换是**硬切**，那行 `withAnimation` 什么都没做。这是最能说明"动效是装饰性添加"的证据。
- **该动的地方没动**：抓包页是流式列表（请求以每秒几十条进来），但**没有插入动画、没有新行高亮、没有滚动锚定策略**。用户看到的是行突然出现、列表跳一下。这是这个工具最核心的动效场景，预算为 0。
- **不该动的地方在动**：`StatusDot` 用 `repeatForever` 的 1.6s 呼吸环（scale 0.75->1.25 + 淡出），hero orb 用 `symbolEffect(.pulse)`。装饰在呼吸，信息在硬切。
- **reduce motion 只覆盖 1/5**：`TFRow` 检查了 `accessibilityReduceMotion`；`StatusDot`、`TFProgressLine`（1.1s 无限循环）、`symbolEffect(.pulse)`、`TFSwitch` 都没检查。

**基准差距**
获奖作品的运动语言通常 <=3 条曲线（一条进、一条出、一条强调），且有**语义**：状态变化动、层级变化动、数据增长动；**装饰不动**。另外必须支持 reduce motion —— 这是评委直接扣分项。

**修法**
`@swift
// 1) 三条曲线，全 App 只用这三条
enum TFMotion {
    static let enter = Animation.spring(response: 0.34, dampingFraction: 0.86)  // 面板/卡片进
    static let shift = Animation.spring(response: 0.26, dampingFraction: 0.92)  // hover/选中/开关
    static let value = Animation.easeOut(duration: 0.22)                        // 数字/进度
}
@Environment(\.accessibilityReduceMotion) private var reduceMotion
var anim: Animation? { reduceMotion ? nil : TFMotion.shift }

// 2) 页面转场真的接上（现在是死代码）
sectionContent
    .id(app.page)
    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)),
                            removal: .opacity))
    .animation(TFMotion.enter, value: app.page)

// 3) 抓包流：插入 + 高亮 + 锚定（这是核心资产）
List(selection: $selected) { ... }
    .animation(TFMotion.value, value: rows.map(\.id))       // 行插入/删除
    .onChange(of: rows.first?.id) { _, new in
        if follow, let new { withAnimation(TFMotion.value) { proxy.scrollTo(new, anchor: .top) } }
    }
// 新行左侧 2pt 信号色条 0.9s 淡出，代替整行闪烁
.overlay(alignment: .leading) {
    Rectangle().fill(TF.signal).frame(width: 2)
        .opacity(isNew ? 1 : 0).animation(.easeOut(duration: 0.9), value: isNew)
}

// 4) 关掉装饰运动
// StatusDot: 去掉 repeatForever，改成"状态变化时 pulse 一次" —— 静止态不该有东西在动
// TFProgressLine: reduceMotion 时改成静态 40% 填充
`@

---

### 2.6 Micro-interaction

**现状证据（有 vs 没有）**

| 交互 | 现在 | 问题 |
|---|---|---|
| 侧栏/表格行 hover | 有：fill 6% + easeOut 0.12 | 只有底色，没有"可点"的其它信号 |
| 主按钮 hover | 无 | 渐变按钮是死的，鼠标移上去毫无反馈；只有 pressed 时 opacity 0.82 |
| 主按钮 pressed | 只改 opacity | 没有位移/内阴影，按下去像图片变淡 |
| 自定义开关 | 有：spring 0.26/0.82 + focus ring | 全 App **只有它**画了焦点环 |
| 其它按钮/行焦点 | 无 | 键盘用户 tab 过去**看不见自己在哪** |
| 复制端点 | 有：toast「已复制」 | 但 8.5pt 复制图标是**常显**的，一行 4 个图标噪音 |
| 危险操作 | 半个：`清空` 是普通 ghost | 没有 danger 变体，hover 不变红，与"重载"视觉同级 |
| 输入框 | 5% 黑填充 = 看起来像只读 | 09 设置页的端口 / TTL 全部像禁用控件 |
| 快捷键 | 非常完整（⌘1–⌘0 跳页、⌘⌥Space 面板） | 这是全 App 最接近"专业工具"的地方，但**界面上没告诉他**（只有设置页一个 10pt 段落） |
| 长路径 | 中间省略 `…/Library/Appli…uchFlow/ca/…` | 开发者工具里不可复制、无 tooltip 的路径是硬伤 |

**基准差距**
获奖级的微交互有一条铁律：**每一个可点的东西，在 hover / focus / pressed / disabled / 加载中 五个状态下都有明确定义**。现在这个 App 定义了两个（hover、pressed），第三个（focus）只在一个控件上存在。

**修法**
`@swift
// 统一焦点环（把 TFSwitch 的做法推广到所有自绘控件）
struct TFFocusRing: ViewModifier {
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.focusable().focused($focused)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(TF.signal.opacity(focused ? 0.9 : 0), lineWidth: 1.5)
                .padding(-3))
    }
}
// 主按钮要有"质量"
.scaleEffect(pressed ? 0.985 : hover ? 1.01 : 1)     // 1% 的抬升就够"贵"
.brightness(hover ? 0.06 : 0)
.animation(TFMotion.shift, value: hover)
// 数值域改成真输入框
TextField("", value: $port, format: .number)
    .textFieldStyle(.plain)
    .padding(.horizontal, 8).frame(height: 24)
    .background(.white, in: RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(TF.rule, lineWidth: 1))
    .font(.system(size: 12, design: .monospaced))     // 端口是数据，等宽右对齐
// 路径可复制
Text(path).truncationMode(.middle).textSelection(.enabled).help(path)
`@

---

### 2.7 Responsive

**现状证据**
- 窗口 `minWidth: 1040 / minHeight: 700`，但**宽度预算从来没算过**：抓包页两栏各 `minWidth: 380` + 各 7pt padding（=394 × 2 = 788），外层 `.padding(.horizontal, 20)`。最小窗口下主区可用 = 1040 - 212（侧栏）- 1（分割）= 827，减去 40 = **787pt**。**788 > 787，恒差 1pt** —— 这个页面的最低宽度需求，比它自己声明的最小窗口还宽 1pt。这不是"边缘情况"，这是没有预算表的直接证据。
- `tfPage` 是 `.frame(maxWidth: 1080, alignment: .leading)`：窗口拉宽到 1440 时，正文右边界停在 1080，而页头右侧按钮贴在窗口右缘 —— **页头和正文不共享同一条右网格线**，右侧空出约 95pt 死白。
- 总览 5 张 `StatTile` 是 `HStack(spacing: 12)` 死写 5 张，无 `LazyVGrid` / `ViewThatFits`。1440 宽时它们只是变宽，密度不变；1040 宽时每张 145pt，任何值变长就触发 `minimumScaleFactor` 偷偷缩字。
- 分流规则右栏死写 286pt，NAS 页 244 / 260 / 220 死写 —— 三处都是"在这个窗口尺寸下看起来还行"的数值。
- `minHeight: 700`：总览页在 700 高时"最近连接"完全在折叠线以下，且没有任何"下面还有内容"的提示（无渐隐遮罩、无滚动条常显）。

**基准差距**
获奖作品会在 3 个断点上实际调整**信息密度**（不是把它拉宽）：宽屏从两栏变三栏（列表 / 详情 / 日志），窄屏把侧栏折叠成图标条，表格列按重要性丢弃而不是挤压。

**修法**
`@swift
// 1) 去掉 1080 硬上限，改为居中 + 与页头共用同一 container
.frame(maxWidth: 1180)                            // 与 header 的 maxWidth 同值
.frame(maxWidth: .infinity, alignment: .center)   // 不再 leading
// 2) 侧栏可折叠（回收 212pt）
SidebarView().frame(width: sidebarCollapsed ? 64 : 212)
// + .keyboardShortcut("s", modifiers: [.command, .control])
// 3) 统计行真的会重排
LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) { ... }
// 4) 抓包页按可用宽度决定分栏
GeometryReader { geo in
    if geo.size.width < 760 { /* 单栏 + 导航式详情 */ } else { HSplitView { ... } }
}
// 5) 域名截断用 middle（host 的 TLD 和 path 尾部都有信息）
Text(host).truncationMode(.middle)
`@

---

### 2.8 Originality

**现状证据（这是全篇最狠的一节）**
把 10 页截图去掉品牌名，混进"2024 年 SwiftUI 网络工具 Mockup"的搜索结果里，**没有任何一张能被认出来**。原因不是粗糙，是**没有一处只属于这个产品的东西**：

- SSH 页那个深 navy 终端（#0B1020 + mono 12 + `IDLE` 铭牌）是**全 App 唯一有性格的表面** —— 有真实材质、有仪器的冷感、有信息密度。而它的处理方式是：在里面画了**假的 macOS 红黄绿三圆点**。这是把唯一的原创资产，用最常见的廉价装饰（仿窗口 chrome）盖住了。
- 隐私页 100 分环是**第二处有记忆点的东西**，但它的语义是错的：全 0 数据 -> "100 分 / 防护状态良好"。一个测量工具在这里变成了奉承机器。评委看得出来 —— 这是"设计语言与产品诚实度不一致"。
- 其余 8 页：同一个 hero 模板、同一排统计卡、同一套空状态、同一个「图标块 + 标题」的 `SectionHeader`。

**基准差距**
Awwwards 级的作品有一个共同点：**至少有一个"只有这个产品才会有"的视觉机制**。比如 Proxyman 的请求瀑布图、Charles 的结构树、Bloomberg 的键盘提示条、Teenage Engineering 的刻度铭牌。它们不靠渐变，靠**把产品独有的数据变成视觉主角**。

**TouchFlow 的独家素材现成摆在那里，没人用**：
1. **流量本身就是图形** —— 每个请求有 duration / size / status，可以是一条横向时间条（waterfall）。现在它是 9 行表格。
2. **路由决策链** —— 一个域名怎么被 MATCH / GEOIP / SUFFIX 命中的，天然是一条分支图形。现在藏在"分流解释器"一个输入框后面。
3. **端点是坐标** —— `127.0.0.1:7890` 是一个物理地址，可以做成仪表读数（mono 大数字 + 小字单位），而不是 4 行表格里的小字。
4. **SSH 终端已经是仪器面** —— 把它变成全 App 的材质基准，而不是一个孤例。

**修法方向**（不是补丁，是重建）：
把"卡片 + 图标块 + 统计数字"的骨架，换成 **"仪表读数 + 数据带 + 发丝线"** 的骨架。具体：总览首屏 = 一个 mono 大读数（`7890` / `0 B` / `9`）+ 一条 12 小时流量 sparkline + 最近 5 条连接的行内时间条。删掉 orb、删掉 5 张彩虹卡、删掉 hero 渐变。

---

## 3. 逐页速诊（每页 3 个最痛的点）

| 页 | 问题 1 | 问题 2 | 问题 3 |
|---|---|---|---|
| 00 总览 | 首屏 430pt 讲"0"，真实数据在折叠线下 | 同一屏 3 个"启动代理"按钮 | 5 张彩虹统计卡无一处语义 |
| 01 分流规则 | 9 行规则无列头，列含义靠猜 | 原生 NSPopUpButton 露出 AppKit bezel | 系统蓝焦点框泄漏，破坏单色系统 |
| 02 去广告 | 主开关在右、子开关在左，同卡内矛盾 | "已开启"文本塞进 24pt 数字位 | 白名单一块 300×150 纯白死 box |
| 03 抓包 | 两个空状态并排争主信息，都无 CTA | 500pt 高卡片里垂直居中 = 双倍死白 | 流式列表零动效（本 App 最该动的地方） |
| 04 SSH | 唯一的深色仪器面被假窗口圆点盖住 | navy 不在 token 体系内 | 终端是死块，无滚动锚定 / 清屏 / 字号 |
| 05 NAS | 同一屏两个「开始扫描」渐变主按钮 | 空状态 CTA 与顶部 CTA 重复 | 挂载说明用 bullet，密度与上两卡失衡 |
| 06 智能学习 | textarea 是 430×155 纯灰石板，无 placeholder | 三步流程用 "->" 字符当连接线 | 头部系统蓝焦点框泄漏 |
| 07 隐私 | 全 0 数据算出 100 分（奉承而非测量） | 第四套渐变语言（conic） | 右卡空状态无 CTA，纯死路 |
| 08 配置 | 10pt 说明跨 727pt（110 字符/行） | 页尾 60% 全空，与总览密度策略矛盾 | 4 个按钮里 3 个同权重 |
| 09 设置 | 数值域像禁用控件（5% 灰填充） | CA 路径中间省略且不可复制 | 一屏 6 个图标块 + 2 个原生 Picker |

---

## 4. Top 7 优先级修复（按「影响 ÷ 成本」排序）

**1. 重建字号阶梯（改一个文件，影响 10 页）**
15 档 -> 6 档；正文 10–11.5 -> **13**；`display` 去 `.rounded`，数字改 SF Mono；`StatTile` 删掉 `minimumScaleFactor`。这是唯一一个"只改 `Theme.swift` 就能让全 App 从商用模板升到工作室作品"的动作。**成本约 1h，收益最大。**

**2. 颜色收敛为「1 信号色 + 4 状态色」，删掉全部渐变与光斑**
`TF.brand` / `mintGradient` / 隐私角向渐变 / 白名单紫 / 彩虹 stat 全部下线；`TFBackground` 一行纯色；卡片阴影 -> 0.5pt hairline。**成本约 1.5h，立刻杀死"AI 通用审美"的三条主罪。**

**3. 建立"每屏一个主角"的层级**
一屏最多 1 个 primary 按钮（现在总览 3 个、NAS 2 个）；卡片分 raised / flat 两级（现在全部同级）；规则表补列头；状态值不进数字位。**成本约 2h，解决"不知道先看哪"这个根本问题。**

**4. 总览页首屏重排**
hero 160->96、删"第一步"横幅、统计 5->4 可换行、把"最近连接"提到首屏并在每行画 duration 时间条。**成本约 3h，把首屏从"0 的展示"变成"实时的仪表"。**

**5. 抓包页升级为真正的核心资产**
插入动画 + 新行 2pt 信号条淡出 + `scrollTo` 锚定 + 列头 + middle 截断 + 单栏/双栏自适应 + 空状态加 CTA。这个页面是"网络调试工具"存在的理由，现在它是最空的页面。**成本约 6h，也是唯一能产出"只有这个产品才有"的画面的地方。** 建议与 4 并列，甚至优先。

**6. 接上页面转场 + 统一三条运动曲线 + 补 reduce motion**
现在 `withAnimation` 是死代码、10 页硬切；`StatusDot` 无限呼吸但不尊重 reduce motion。改成 spring(0.34/0.86) 入场 + `.id(app.page)` + `.transition`，装饰动效全部静止化。**成本约 2h，是评委最容易注意到的"廉价感"来源之一。**

**7. 微交互五态补齐（hover / focus / pressed / disabled / loading）**
所有自绘控件加焦点环（现在只有 `TFSwitch` 有）；主按钮加 1% scale + brightness hover；数值域从"灰填充"变真输入框（白底 + hairline + mono）；CA 路径可复制 + `.help()`；危险操作加 danger 变体。**成本约 3h，是"专业感"的密度来源。**

> 顺序建议：1 -> 2 -> 3 必须一起做（共用 `Theme.swift` 与 `Shared.swift`，分三次改会互相打脸）；4 / 5 / 6 / 7 可并行。

---

## 5. 我建议的视觉方向：**Instrument Monochrome（仪器化单色）**

### 为什么不直接选 Editorial（虽然团队正在往那走）

评审期间我发现仓库已经被并发改成了"暖纸 + vermilion + serif + 点阵"的 Editorial 方向。**它对了一半，但有两个真风险**：

1. **serif 在 10 页工具里是负债**：serif 的情感是"叙述 / 编辑部 / 慢"，而这个产品的用户 90% 时间在读 `172.16.0.0/12` 和 `GET /api/v1/user 200 41ms`。serif 只能出现在"每页一句人话"（比如空状态那一句），一旦扩散到标题，就滑向"生活方式博客"。
2. **点阵不是解药，是同一个病的换药**：把两团模糊光圈换成 26pt 点阵，装饰预算没变，只是从"极光"变成"工程感极光"。**如果背景不是在设计信息，它就该是纯色。**

### 建议规格（可直接落 token）

| 项 | 值 | 说明 |
|---|---|---|
| 地面 | `#F7F6F3`（浅）/ `#0B0B0C`（深） | 纯色。无光斑、无点阵、无网格 |
| 墨阶 | `#141310` / `#4A4740` / `#8A8578` / `#E2DFD7` | 只有 4 级；第 4 级就是唯一的分隔线色 |
| 信号 | `#C63A12` | **一屏 <=3 次**：一个主操作、一个 live 指示、一个危险确认 |
| 状态 | ok `#0C7A55` / warn `#8F5E07` / bad `#B32636` / route `#5446B8` | **只用于 6pt 圆点、2pt 边条、图标**，永不整块填充 |
| 字体 | Display 28 semibold `tracking -0.6`；Body 13；Micro 10.5 mono `tracking 1.4` uppercase；**Data 12 mono tabular** | 无 serif。层级靠字重与字距，不靠 0.5pt 寸差 |
| 结构 | 圆角 6（不是 14）；卡片无阴影，只有 0.5pt hairline；**唯一 raised 层级每屏 1 处** | "所有卡都浮起来" = "没有东西浮起来" |
| 网格 | 8pt 基线，页边 32，卡片内 16 | token 化，停用所有手写 13/18/22 |
| 数据 | 表格必有列头（mono 9.5 uppercase tracking 1.2）；数字右对齐 tabular | 这是"仪器"与"仪表盘"的分界线 |

### 为什么它适合网络工具

1. **心理模型对得上**：网络工具的本体是**仪表**（万用表、示波器、频谱仪），不是 SaaS 仪表盘。仪表的美学是"黑色外壳 + 一种刻度的颜色 + 精确的发丝线"，不是"渐变卡片"。
2. **注意力成本最低**：用户读的是数字和行。近单色把"识别颜色"的开销降到 0，只留一个红点告诉"哪里出事了"。彩虹统计卡强迫用户每次重新解码 5 种颜色的含义。
3. **视觉密度正相关**：装饰越少，能塞的信息越多。这个 App 有 10 页、表格、日志、路径、IP —— 它需要密度，而不是呼吸感。Editorial 的暖纸 + 大留白会**降低**可比密度。
4. **抗过时**：Swiss 网格与仪器面板 40 年没变过形；蓝紫渐变每 3 年换一代。评委看的是"这是不是 2026 年的作品"，而不是"这是不是 2023 年的 Linear"。
5. **它给原创性留了位置**：一旦底色是纯的，**唯一有颜色的东西就是数据**（状态点、时间条、流量线）。到那时 SSH 那个深色仪器面不再是孤例，而是整个 App 的材质基准 —— 那才是"只有 TouchFlow 会有"的画面。

### 与并发改动的协调建议

**保留**：暖纸（`#F7F6F3` 比 `#F6F4EF` 更中性，建议微调）、vermilion 单信号、数字改 mono。
**建议回退**：serif（或严格限制到每页 <=1 处、仅空状态文案）、点阵背景（删掉，或降到 `opacity <= 0.03` 且只用于 hero 一个区域）。
**还要补**：圆角 14 -> 6、卡片阴影全删、字号阶梯 15 -> 6、正文抬到 13。

---

## 6. 验收标准（可以拿尺量的那种）

- [ ] 全 App 字号种类 <= 6，且相邻档位比值 >= 1.2
- [ ] 最小正文 >= 12pt（理想 13）
- [ ] 强调色 <= 5，每个色的语义在 `Theme.swift` 有注释、在 10 页里用法一致
- [ ] `LinearGradient` 出现次数 = 0；`shadow` 出现次数 <= 2
- [ ] 任一屏 primary 按钮 <= 1
- [ ] 最小窗口 1040 下抓包页无横向溢出（两栏 minWidth + padding < 787）
- [ ] 所有可点控件有可见 focus ring（tab 走完 10 页，截图 10 张）
- [ ] 开启"减少动态效果"后，无 `repeatForever` 动画在跑
- [ ] 1440 宽度下页头右缘与正文右缘在同一条竖线上（截图对比）
- [ ] 抓包页收到第一条请求时有插入动画 + 新行标识（录屏 5 秒）

---

*评审结束。一句话：这个 App 现在缺的不是更多设计，是**删掉 60% 的设计，然后把省下来的注意力全押在数据本身上**。*

# TouchFlow 二轮视觉评审（Final · 视觉重构后）

> 评审对象：/tmp/tffinal/review 下 21 张真实窗口截图（light ×10、light3-ssh/adblock/learn 最新版、compact 900×700 ×4、dark ×4）
> 代码核对：只读 grep / read，未构建、未启动、未改任何 .swift
> 基准：Awwwards Site of the Day / Webby Visual Design / FWA 级桌面工具（Linear、Raycast、Arc、Panic Transmit、Bloomberg Terminal、Are.na）
> 评分刻度：1–10；交付线 6.5（专业可用），获奖线 8.0（可提交 SOTD）

---

## 0 判决

| # | 维度 | 分数 | vs 交付线 6.5 | vs 获奖线 8.0 | 一句话 |
|---|------|------|------|------|--------|
| 1 | Typography | **5.5** | FAIL | FAIL | 系统成立，但 25 档字号 + 正文 11pt 把它按在地上 |
| 2 | Whitespace | **6.0** | FAIL | FAIL | 节奏统一了，但首屏与空态仍在浪费 40% 面积 |
| 3 | Visual Hierarchy | **7.0** | PASS | FAIL | 一屏一个实心按钮做到了；总览仍有 3 个「启动」入口 |
| 4 | Color | **7.5** | PASS | FAIL | 单信号色是真纪律，可惜策略/状态又开回三原色 |
| 5 | Motion | **6.0** | FAIL | FAIL | 转场死代码已修，但一种曲线、零共享元素、两处无视 reduce motion |
| 6 | Micro-interaction | **6.5** | PASS | FAIL | hover/复制/键盘提示都在；按钮无焦点环，开关三个尺寸 |
| 7 | Responsive | **6.5** | PASS | FAIL | 788>787 溢出已消灭；网格不重排、分栏不坍缩 |
| 8 | Originality | **7.5** | PASS | FAIL | Editorial Instrument 立住了；缺一个「只有 TouchFlow 才有」的画面 |
| | **加权总分** | **6.7** | | | 上一版约 4.1 |

### ① 是否达到 Awwwards / Webby「可提交」状态

**否。** 三条硬理由，评审在 3 秒内就能看出来：

1. **没有 hero moment。** 获奖作品有一张「截图即海报」的画面。当前 10 页里最接近的是总览 hero 与 SSH 终端，但 hero 讲的是 **0**，终端讲的是「未连接」。全 App 没有任何一屏在展示「正在工作的仪表」——真实数据、真实流量、真实波形。
2. **正文在 1440pt 宽屏会缩成蚂蚁。** 11pt 是 Xcode Inspector 的密度，不是 1040px 窗口的阅读尺寸。评审通常在 1440–1728pt 显示器上看截图，11pt 会读作「未完成」。
3. **诚实性缺口。** 隐私页用 `0 已拦截 / 0 风险项 / 0 规则` 算出 100 分。这类「奉承式评分」在专业眼里是判断力问题，比任何字号错误都致命。

**它能到哪：** Webby Utility/Product 提名、Hacker News 首页、Product Hunt 当日前五——这一档现在就该投。SOTD 差 1.3 分，差的不是打磨，是「一个属于这个产品的签名画面」。

---

## 1 Typography — 5.5 / FAIL

**现状证据（好的一面，先记账）**
- `light-rules` 右栏「策略组 / GROUPS」「出站 / OUTBOUNDS」「规则集 / RULE-SETS」「快捷键 / KEYS」——mono 小字 + 字距 1.2–1.7 的 eyebrow + 1px 发丝线，这是 Editorial 语法的正确用法。
- `light-profiles` 底部「导入来源」四行（Clash YAML / Surge conf / TouchFlow JSON / 订阅链接 + mono 规则串）是全 App 排版最好的一块：左列固定宽、右列 mono 对齐、行距一致，像一份工单。
- 页面标题 26pt semibold tracking −0.8（Shared.swift `PageHeader`），副标题 12pt tertiary，层级干净。
- 数据统一 SF Mono + `contentTransition(.numericText())`，数字不抖——专业度在这一处成立。

**现状证据（扣分项）**
- `grep` 统计：全项目 **25 个不同字号**（7 / 7.5 / 8 / 8.5 / 9 / 9.5 / 10 / 10.5 / 11 / 11.5 / 12 / 12.5 / 13 / 13.5 / 14 / 14.5 / 15 / 18 / 19 / 20 / 22 / 26 / 27 / 30 / 48）。**11pt 出现 88 次**、10pt 37 次、9pt 41 次、9.5pt 24 次——五个「迷你号」在当正文用。
- `light-settings` 左栏：11pt 标签 + 9.5pt 说明 + 12.5pt 数值同处一行；「上游」被截成 `https://1.1.1...tls://1.0.0.1`（中间省略、无 tooltip、无复制）。
- `light-dashboard` hero 那句 `代理尚未启动，本机流量仍走系统默认路径。` 用 `TFFont.serif(13.5).italic()`（DashboardView.swift:60）。SF Serif 无中文斜体，CJK 会被合成倾斜——**假斜体**，专业评审判定最快的硬伤之一。
- `light3-adblock` 统计条三格里两格是数字、一格是 `已开启`，26pt 位放词不放数。

**与获奖基准的差距**
获奖字阶是「设计决定」，不是逐处试出来：通常 5–7 档，正文 ≥13pt（macOS 正文），mono 只给数据/路径/时间，绝不给解释性散文。现在从 9 到 12.5 挤了 7 档，等于「没有阶梯，只有刻度」。

**具体修法（SwiftUI 原语级）**
1. Theme.swift 建 7 档 token，删掉裸 `.system(size:)`：
```swift
extension TFFont {
    static let micro   = Font.system(size: 9.5, weight: .medium).monospaced()   // eyebrow / keycap
    static let caption = Font.system(size: 12, weight: .regular)                // 说明 / 单位 / meta
    static let body    = Font.system(size: 13, weight: .regular)                // 唯一阅读字号
    static let bodyEm  = Font.system(size: 13, weight: .semibold)
    static let label   = Font.system(size: 15, weight: .medium)                 // 区块标题
    static let title   = Font.system(size: 22, weight: .semibold).width(.compressed)
    static let display = Font.system(size: 34, weight: .semibold).width(.compressed)
}
```
2. 三张映射表全局替换：`size: 11 → .body`、`size: 10 / 10.5 → .caption`、`size: 9 / 9.5 → .micro`。中文**删掉 tracking**（中文加字距会散行），tracking 只留给 mono eyebrow。
3. hero 标题 30 → 34，页面标题 26 → 22：**把两者差距从 4pt 拉到 12pt**。现在 30 与 26 同屏（`light-dashboard` y≈50 与 y≈180）互相抵消，读者不知道这页的主语是谁。
4. 删 `TFFont.serif(13.5).italic()`；那句人话改 `.body` + `textSecondary`。斜体只允许拉丁（如 `v1.1`）。
5. 截断三件套：`.truncationMode(.middle)` 已对，补 `.help(fullValue)` + 行尾 `doc.on.doc`（本地端点卡已有此模式，直接复制）。

**验收**：非 mono 正文字号 ≥12pt；`size:` 调用点由 321 处降到 <60；中文无 `.italic()`；任一屏字号相邻两级比值 ≥1.3。

---

## 2 Whitespace — 6.0 / FAIL

**现状证据**
- 好：gutter 统一（`tfPage` 32/26、卡内 18、行间 24），发丝线取代阴影，页面呼吸一致。`light-rules` 左表 37pt 行高、无斑马纹、只靠发丝线，密度正确。
- `light-capture`：左右两个 500pt 高的大空态并排，整屏约 **62% 空白**；右侧「选择左侧请求查看详情」占了 380pt 宽。
- `light3-ssh`：终端 470pt 高，只有顶部一行说明 + 左下 `$` 光标，**85% 是黑**。
- `light3-learn`：左 textarea 430×155 纯空白（**无 placeholder**），右虚线拖拽区 264×112，两个大空腔并排。
- `light3-adblock`：四张全宽卡等高同边框上下堆叠——页面没有「疏密」，只有「均匀」。
- 反面：`light-dashboard` 首屏 430pt 塞 hero + 引导条 + 5 列统计，真正数据在折叠线下。**同一 App 里「挤爆」与「空旷」并存**。

**与获奖基准的差距**
获奖作品的白是「被结构定义的」：空白出现在两栏之间、数字之间、章节之间，且每屏有一处刻意的宽白（巨号数字或一句人话周围的大留白）。现在的白是「没填满」的副产品。

**具体修法**
1. 空态改骨架而非居中图标。抓包 0 条时渲染 3 行幽灵表格行 + 照常列头，用户立刻知道「这里将来长什么样」：
```swift
if engine.captures.isEmpty {
    VStack(spacing: 0) {
        captureHeaderRow                       // 方法 / URL / 状态 / 耗时 照常
        ForEach(0..<4) { _ in
            HStack { Rectangle().fill(TF.stroke).frame(height: 9) }
                .frame(height: 34)
                .redacted(reason: .placeholder)
        }
        Spacer()
        TFEmptyState(...)                      // 空态下沉到底部，不居中
    }
}
```
2. 终端空态从「一行字」升级为 3 段 mono 引导（`ssh -p 22 user@host` / 密钥建议 / 连接后显示交互输出），12pt、行距 20、行首 `$`——空白变成「待输入的命令行」。
3. 去广告页把 4 张卡合并为 2 个章节：引擎（开关组）与名单（过滤列表 + 白名单）之间用全宽发丝线 + 56pt 留白分隔，拆边框。页面从「4 个盒子」变「2 个章节」。
4. 总览：hero `.padding(.vertical, 24) → 18`，统计条 `13 → 11`，省出的 60pt 全给折叠线以上的第一行真实数据。

**验收**：任一屏的纯空白矩形不再 >320×320；空态底部对齐；首屏（y<700）至少 1 条真实数据行。

---

## 3 Visual Hierarchy — 7.0 / PASS（交付线）· FAIL（获奖线）

**现状证据**
- 真进步：每页恰好 1 个实心朱红按钮（`light-rules` 添加规则、`light3-adblock` 检查、`light-profiles` 导入配置），其余全 4.5% 墨底 ghost。上一轮「一屏 3 个渐变主按钮」已修对。
- 图标全中性灰（SectionHeader 注释写明「颜色只留给数据信号」），比上一版彩色图标块高级一档。
- `light-dashboard` hero 的视线成立：eyebrow → 30pt 标题 + `v1.1` → serif 人话 → 3 个状态胶囊 → 右侧实心按钮 + 两个开关。
- 但**总览一屏仍有 3 个「启动代理」**：hero 实心（y≈184）、引导条描边（y≈348）、左下侧栏（y≈718）。引导条与 hero 说的是同一件事，把 hero 的权威稀释成「提示」。
- `light-capture` 两个空态等权重居中，「暂无请求」与「选择左侧请求」互相竞争——空态只能有一条主信息。
- `light3-adblock` 第三格把状态词塞进 26pt 数字位；一行里两种数据类型。
- 页面标题 26 与 hero 标题 30 只差 4pt：顶部两个标题在争「这是谁的页面」。

**与获奖基准的差距**
获奖页是「一个主角 + 若干配角」，配角靠**尺寸差 3 倍**或留白区分，不靠颜色。现在主角与配角的尺寸比只有 1.15。

**具体修法**
1. 删掉总览引导条（DashboardView.swift:202 的 `TFEmptyState(actionTitle:)`），信息并入 hero 人话：「代理尚未启动 · 启动后本机流量才会经过 127.0.0.1:7890」。
2. 统计条改「1 主 4 从」：活动连接 34pt display 占 1.6 倍宽，其余 15pt 等分。层级从「五个 0」变成「一个数字 + 四个注脚」。
```swift
HStack(alignment: .firstTextBaseline, spacing: 0) {
    stat(value: "\(flows.count)", label: "活动连接", flex: 1.6, size: .display)
    Divider().frame(height: 34)
    stat("\(blocked)", "已拦截"); stat(bytes, "累计流量"); stat("\(rules)", "规则")
}
```
3. 「元素隐藏」不占数字位：单独一行开关（`元素隐藏   注入 CSS 隐藏规则   [switch]`），统计条只留两个真数字。
4. hero 30 → 34、页面标题 26 → 22（见 §1），比值做到 1.55。

**验收**：一屏内同一动作最多出现 2 次且只有 1 次实心；相邻字级比 ≥1.3。

---

## 4 Color — 7.5 / PASS（交付线）· FAIL（获奖线）

**现状证据**
- 方向正确且执行到位：暖纸 `#F6F4EF` / 暗墨 `#0A0A0B`、墨阶四级（`text` / `textSecondary` / `textTertiary`）、唯一信号色朱红 `#C63A12`（暗色 `#FF7A4D`，实心按钮另用 `accentFill` `#C2410F` 保证白字 ≥4.5:1——注释里写明了，专业动作）。`light-dashboard` 全屏只有 3 处朱红：hero 顶部 44×2 信号线、启动按钮、去广告开关。克制得漂亮。
- 失败点一：策略/状态色仍开三原色。`light-rules` `DIRECT` 是墨绿 `#0C7A55`、`PROXY` 是紫 `#5446B8`，而 `REJECT` 是朱红——**朱红既是「添加规则」的主按钮色，又是「拒绝」的语义色**。同一个颜色在同屏承担两种相反含义，这是色彩语义的硬冲突。
- 失败点二：总览 Badge 仍在用 `violet`（HTTPS 解密）与 `amber`（去广告），`light3-privacy` 又引入绿点/琥珀点两套状态色。于是「单一信号色」在第 2、7 页破功两次。
- 失败点三：残留渐变。`TF.brand` 仍是朱红→焦褐的双停渐变，用在菜单栏面板图标（TouchFlowApp.swift:860）与不定态进度条（Interactions.swift:144/147）；`mintGradient` 已是死代码。全 App 唯一的两处渐变都被藏在不显眼处——要么删，要么明确写进规范。
- 对比度风险：9–9.5pt 的 tertiary 在纸色上约 4.6:1，**刚过 AA 无余量**；而它承担了大量说明文字。暗色 tertiary 在 `#151517` 上同样贴线。

**与获奖基准的差距**
获奖的桌面工具用「墨阶 + 一个强调色 + 极少量语义色」，且强调色的含义**全局唯一**。现在朱红同时是「主行动 / 拒绝 / 品牌 / 信号线」，四种含义挤在一个色值上。

**具体修法**
1. 策略改墨阶，朱红只留给「拦截/危险」：
```swift
enum PolicyTone {
    static func color(_ p: String) -> Color {
        switch p.uppercased() {
        case "DIRECT": return TF.textTertiary                     // 灰：不经过本机
        case "PROXY", "AUTO": return TF.text                      // 墨：经过本机（重要，但不是警告）
        case "REJECT": return TF.danger                           // 朱红：唯一语义色
        default: return TF.textSecondary
        }
    }
}
```
2. 删掉 Badge 的 violet/amber：HTTPS 解密用「中性描边胶囊 + 锁图标」，去广告用「中性描边 + 盾牌图标」，靠**图标**而不是色相区分。
3. 隐私页状态点收敛为两级：完成 = 实心墨点，待办 = 空心墨环，风险 = 实心朱红。绿/琥珀全部删除。
4. `TF.brand` 改 `TF.accentFill`（纯色）；`mintGradient` 删除。若坚持品牌渐变，只允许出现在 24×24 的菜单栏图标内，并在 Theme 注释里写死边界。

**验收**：全项目色值（除黑白灰）≤6 个；朱红在任一屏的含义唯一；`grep -c "TF.violet\|TF.mint\|TF.amber"` 等于 0（或仅剩数据系列）。

---

## 5 Motion — 6.0 / FAIL

**现状证据（从静态图 + 代码核对）**
- 上一轮的**死代码已修**：TouchFlowApp.swift:388–391 现在有 `.transition(.opacity.combined(with: .offset(y: 6)))` + `.animation(.easeOut(0.18), value: app.section)`，10 页切换不再是硬切。
- 数字有 `contentTransition(.numericText())`（7 处，Shared/Dashboard/Privacy/AdBlock），计数变化会滚动——这是仪表感的核心，做对了。
- 抓包新行有 `freshID` 高亮 + 0.25s easeOut（CaptureView.swift:113/286），列表流式插入有人管了。
- 卡片 hover 有 1pt 上浮 + 0.06 阴影（`tfHoverLift`，且已检查 reduce motion）。
- 缺口一：**只有一种运动语言**。32 处 animation 里 26 处是 `easeOut 0.10–0.20`，其余是 `.snappy`。没有一条曲线是「仪器的」——获奖工具会用 0.35s 的强减速（如 `.timingCurve(0.2, 0.9, 0.1, 1)`）来表达「指针落位」，用 0.08s 表达「按键反馈」。现在两者都是 0.12。
- 缺口二：**零共享元素**。抓包列表点一行 → 右侧详情是硬替换，没有 `matchedGeometryEffect` 或至少共享的元素位移。列表→详情的连续性正是 Raycast/Linear 级别的差距所在。
- 缺口三：**插入没有编排**。新行只是自己闪一下，没有「列表整体下移 34pt + 新行从 4pt 高度展开」的段落动画，也没有滚动锚定（用户盯着的行会被顶走）。
- 缺口四：**两处无限循环无视 reduce motion**：`StatusDot` 的 1.8s 脉冲（Theme.swift:308）与 `TFProgressLine` 的 1.1s 不定态（Interactions.swift:151）都没有 `accessibilityReduceMotion` 判断——而项目里其余 5 处都判了，属于漏项而非无知。

**与获奖基准的差距**
获奖桌面工具的运动是「状态变化被可视化」：数字滚动、规则落地、行滑入、指针回零。现在只做到了「淡入淡出」，那是 Web 2016 的语言。

**具体修法**
1. 建三条曲线（Theme.swift）并在全项目替换：
```swift
enum TFMotion {
    static let tap      = Animation.timingCurve(0.2, 0.0, 0.0, 1.0, duration: 0.10)  // 按下
    static let settle   = Animation.timingCurve(0.16, 0.9, 0.10, 1.0, duration: 0.34) // 指针落位/页面切换
    static let reveal   = Animation.spring(response: 0.34, dampingFraction: 0.86)      // 行/卡片出现
}
```
2. 页面切换改「发丝线扫过」而非整体位移：新页内容 `opacity` 0→1 配 `offset(y: 2)`，同时顶部 1px 朱红规则从左向右 `scaleEffect(x: 0→1, anchor: .leading)` 0.28s——一秒钟建立「翻页」的隐喻，比整体上移 6pt 高级。
3. 抓包新行：给列表加 `.animation(TFMotion.reveal, value: engine.captures.first?.id)`，新行 `.transition(.asymmetric(insertion: .offset(y: -8).combined(with: .opacity), removal: .opacity))`，并 `ScrollViewReader` + `proxy.scrollTo(id, anchor: .top)` 保持视口稳定。
4. 列表→详情：详情面板头部（方法 + URL）用 `matchedGeometryEffect(id: "requestHead", in: ns)` 从行内放大 40pt 到位——一个动作讲清「你点的是这一行」。
5. 补两处 reduce motion：
```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion
// StatusDot
.animation(reduceMotion ? nil : .easeOut(duration: 1.8).repeatForever(autoreverses: false), value: on)
// TFProgressLine
if !reduceMotion { withAnimation(...) { phase = 1.1 } }
```

**验收**：动画调用点里出现 ≥3 种不同曲线；reduce motion 覆盖率 100%（含 2 处循环）；列表插入有滚动锚定。

---

## 6 Micro-interaction — 6.5 / PASS（交付线）· FAIL（获奖线）

**现状证据**
- 已在的细节：侧栏 hover 时右侧浮出 `⌘1…⌘0` 键位提示（TouchFlowApp.swift:621）；复制按钮点击换成对勾（Shared.swift:305，0.22s snappy）；`TFSwitch` 有自绘焦点环 + `.accessibilityRepresentation`（Theme.swift:369/374）；文本框聚焦时下划线转朱红（SettingsView.swift:421 等）；命令面板 `⌘K` 常驻工具栏与侧栏入口双通道。
- 缺口一：**按钮没有焦点环**。`TFPrimaryButtonStyle` / `TFGhostButtonStyle` 都没有 `focused` 或 focus 描边；自定义 `.buttonStyle(.plain)` 在 macOS 全键盘导航下会出现系统蓝环（上一轮 `light-rules` 右上开关外圈那圈 `#0B84FF` 就是这个），此时蓝环与品牌色冲突。开关有环、按钮没有——最常被键盘访问的控件反而最弱。
- 缺口二：**同一个开关三种宽度**：28（SSH）/ 30（顶栏、总览）/ 34（规则、去广告、抓包）。同一控件在不同页面大小不一，是「逐处调参」的痕迹。
- 缺口三：**禁用态用「褪色实心」表达**。`light3-learn` 左下「解析列表」在空输入时渲染成 45% 透明朱红 + 白字，对比度跌到约 2.4:1，读作「坏掉的按钮」而不是「还差一步」。
- 缺口四：**拖拽没有目标态**。LearnView.swift:118 `.dropDestination` 没有 `isTargeted` 绑定，拖文件进来时虚线框不变色、不扩张——用户唯一能确认「可以松手」的信号缺失。
- 缺口五：表格/列表行没有「按下」态（只有 hover 填充），点击瞬间无反馈。

**与获奖基准的差距**
获奖工具把「每个控件都有 5 个状态」（rest / hover / focus / pressed / disabled）当默认。现在鼠标态齐全、键盘态残缺、拖拽态缺失。

**具体修法**
1. 按钮焦点环统一进 ButtonStyle（用 `@Environment(\.isFocused)` 不成立，改用一个 `FocusRingModifier` 在调用点加 `.focused($f)` 太散；最省事是把三个 style 包成 `Button` 的 wrapper 组件，内部 `@FocusState`）：
```swift
.overlay(
    RoundedRectangle(cornerRadius: 7, style: .continuous)
        .strokeBorder(focused ? TF.accent : .clear, lineWidth: 2)
        .padding(-3)
)
.focusEffectDisabled()
```
2. 开关宽度收敛为单值 32（`TFSwitch(isOn:)` 默认值），删除所有 `width:` 实参。
3. 禁用态不要改透明度。在 style 里读 `@Environment(\.isEnabled)`：
```swift
@Environment(\.isEnabled) private var enabled
// fill: enabled ? accentFill : .clear
// stroke: enabled ? .clear : TF.strokeStrong
// foreground: enabled ? .white : TF.textTertiary
```
4. 拖拽区加 `isTargeted`：
```swift
.dropDestination(for: URL.self) { urls, _ in ... } isTargeted: { over in
    withAnimation(TFMotion.tap) { dragOver = over }
}
// 虚线改 2pt 朱红 + 背景 accentSoft(4%)，图标 1.04 放大
```
5. 列表行加 `.scaleEffect(pressed ? 0.998 : 1)` + 按下填充 `stroke.opacity(0.7)`，0.10s `TFMotion.tap`。

**验收**：键盘 Tab 走遍一屏，每个可操作元素都有可见焦点（且不是系统蓝）；开关只有一种尺寸；禁用态不靠透明度。

---

## 7 Responsive — 6.5 / PASS（交付线）· FAIL（获奖线）

**现状证据**
- 上一轮的硬 bug **已消灭**：抓包两栏 `minWidth: 336`（CaptureView.swift:70/73）+ 窗口最小 `900×660`，不再 788>787 恒差 1pt 溢出；900pt 下侧栏塌成 68pt 图标栏（TouchFlowApp.swift:376 `geo.size.width < 960`），`compact-dashboard`/`compact-capture` 均无横向裁切。
- 旧值也顺手清理了：侧栏 216/68、页面 `maxWidth: 1180`。
- 缺口一：总览统计条是固定 5 列 `HStack`，窗口变宽不重排（不要求瀑布流，但至少 2 行 × 3 列或 1 主 4 从，见 §3）。
- 缺口二：设置页两列网格在 900pt 下仍是 2 列，每卡 370pt——`compact-settings` 里「上游」截断更狠、证书路径截成 `…/App…F…Flow/ca/…`。应该在 <980 时改单列（或 1 大 1 小的非对称）。
- 缺口三：抓包在 900pt 仍 1:1 分栏，右侧详情 385pt 装不下「请求头 / 响应体」的 68 字符行；而空态时右栏 100% 浪费。应在无选中项时隐藏右栏（或收成 0pt + 48pt 手柄）。
- 缺口四：高度维度完全没被设计。`compact-settings` 与 `light-settings` 都在 y≈735 被硬切（卡片被折叠线拦腰截断），没有「内容继续」的视觉暗示（fade / 底部内阴影 / 计数）。1040×752 是笔记本常见可用高度，等于**默认窗口就是被切的**。

**与获奖基准的差距**
获奖桌面 App 至少设计 3 个宽度档与「内容超出」这一状态；现在只有 2 档宽度、0 个高度语义。

**具体修法**
1. 统计条用 `ViewThatFits` + 断点：
```swift
ViewThatFits(in: .horizontal) {
    statStrip(columns: 5)      // ≥1000
    statStrip(columns: 3)      // 900–999（3+2 两行）
}
```
2. 设置页：
```swift
let cols = width < 980 ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())]
LazyVGrid(columns: cols, spacing: 16) { ... }
```
3. 抓包详情栏条件渲染：
```swift
if let sel = selection, width >= 1000 {
    CaptureDetail(selection: sel).frame(minWidth: 380)
} else if selection == nil {
    // 不渲染右栏，列表吃满
}
```
4. 滚动容器统一加底部渐隐（`mask` 的 `LinearGradient(stops: [.init(color: .black, location: 0.94), .init(color: .clear, location: 1)])`）+ 右下角 `还有 4 项` 计数，告诉用户「下面还有」。

**验收**：900 / 1040 / 1440 三档均无裁切、无 1:1 硬分栏；任一页折叠线处有继续提示。

---

## 8 Originality — 7.5 / PASS（交付线）· FAIL（获奖线）

**现状证据（原创资产，实打实存在）**
- 品牌标记：墨方块 + 斜体衬线 `T` + 右下角 5pt 朱红点（TouchFlowApp.swift:566–582）。这是「被设计过」的 mark，不是 SF Symbol 拼贴。
- 栏目语法：mono eyebrow + 中文主词（`策略组 / GROUPS`）、发丝线分区、下划线表单（设置页 7890/7891/7892 用单一底线而非输入框底色）——这套东西在 macOS 工具里很少见。
- 隐私页的**刻度尺**：100 下方一条 0/55/80/100 的标尺（`light3-privacy` y≈258），把「分数」变成「读数」。这是全 App 最有原创性的一笔——它属于仪器，不属于 SaaS。
- 智能学习的 `01 识别 / 02 建议 / 03 落地` 三段（mono 序号 + 衬线小标 + 说明），是编辑设计的正确用法。
- 但：整体仍是「2024 编辑风仪表盘」的一次高水平临摹（Are.na / Bloomberg Graphics / NYT 交互版）。**没有任何一处只能属于「本地代理」**：没有每秒包数、没有瀑布图、没有路由地图、没有规则命中台账。最具产品特征的两个界面（抓包表、SSH 终端）恰恰是最不风格化的——它们看起来像任何 dev tool。

**与获奖基准的差距**
SOTD 的判定语通常是「我没见过这样的工具」。现在的判定语会是「执行得很好」——这是 7.5 与 8.5 的分界。

**具体修法：给产品一个签名器件「流量地震仪」**
在每个数据页的页头下方，插入一条 28pt 高的全宽条带（不放卡片、不放边框，只有上下两条 1px 发丝线）：
- 一根 1pt 墨色路径，表示最近 60 秒的请求数/字节数（`Canvas` 绘制，60 个采样点，线性插值）；
- 每秒在最右端追加一个采样，路径整体左移 1pt（`TimelineView(.periodic(from: .now, by: 1))`）；
- 当前秒用 2pt 朱红竖线标记（就是刻度尺上的游标）；
- 空闲时路径是一条水平基准线 + 极小的呼吸噪声——**「没有流量」本身也成为可读的信号**。
```swift
TimelineView(.periodic(from: .now, by: 1)) { _ in
    Canvas { ctx, size in
        var p = Path()
        for (i, v) in samples.enumerated() {
            let x = size.width * CGFloat(i) / CGFloat(samples.count - 1)
            let y = size.height - 2 - size.height * 0.85 * CGFloat(v)
            p.addLine(to: CGPoint(x: x, y: y))
        }
        ctx.stroke(p, with: .color(TF.text.opacity(0.55)), lineWidth: 1)
        ctx.fill(Path(CGRect(x: size.width - 2, y: 0, width: 2, height: size.height)),
                 with: .color(TF.accent))
    }
}
.frame(height: 28)
```
为什么这条能提分：它是**唯一一个「截图里看得出在运行」的元素**，且只有网络工具会拥有它。评审看到 1040×752 的静态图，第一眼就懂「这是一个在听网络的东西」。

**验收**：随机截一张图，去掉 logo 与文案，仍能被认出是网络工具。

---

## 9 剩余最影响评审的 5 个缺陷

| # | 页面 | 元素 | 动作 | 影响面 |
|---|------|------|------|--------|
| 1 | 总览 | 首屏 430pt + 「最近连接 / RECENT」在折叠线下（DashboardView.swift:533） | 删引导条、hero 压到 150pt、统计条 1 主 4 从，让 3 行真实连接在 y<620 出现 | 决定性：首屏讲 0 |
| 2 | 全局 | 25 档字号、正文 11pt（88 处） | 收敛到 7 档、正文 13、标题 22、hero 34 | 全局观感「未完成」 |
| 3 | 分流规则 / 总览 | `DIRECT` 墨绿、`PROXY` 紫、`REJECT` 朱红，朱红同时是主按钮 | 策略改墨阶，朱红只留拦截 | 语义冲突，专业评审必点 |
| 4 | 隐私 | `100` 分来自 0/0/0 | 空数据显 `—` + 「样本不足」，或把标签改成「配置完备度」 | 唯一「不诚实」处 |
| 5 | 抓包 | 900pt 仍 1:1 分栏 + 两个居中空态 | <1000 不渲染右栏；空态改幽灵表格行 + 底部对齐 | 最大面积浪费 |

**次级（不占前五，但一并修）**
- 设置页三处中间截断（上游 DNS / 证书路径 / MITM 主机）：补 `.help` + 复制图标。
- 智能学习空 textarea 无 placeholder；禁用主按钮是 45% 透明朱红（对比度 ≈2.4:1）。
- 开关 28/30/34 三尺寸；按钮无焦点环；`dropDestination` 无 `isTargeted`。
- 假斜体中文（`serif(13.5).italic()`）。
- `mintGradient` 死代码 + 菜单栏图标仍在用渐变。

---

## 10 哪一页拖后腿

1. **去广告（最弱）**：四张全宽等高卡上下堆叠，无疏密、无焦点；`已开启` 占数字位；主体开关行与三行子开关视觉权重几乎相等（只差一级字重）。构图层面它是「表单清单」，不是「页面」。改法：2 章节 + 发丝线分隔 + 「拦截趋势」地震仪 + 把「已开启」降级为右对齐 mono 状态。
2. **智能学习（次弱）**：左 430×155 的空 textarea 与右侧虚线区形成两个竞争空腔，唯一实心元素还是个禁用按钮。改法：默认预填一条示例（`微信 / com.tencent.xin`）作为「可删除的样例行」，右栏虚线区缩到 200×96 并靠右，主按钮保持可用直到用户清空。
3. **总览（第三弱，但只差一处重排）**：hero 与统计条都精致，问题全在「首屏没有真数据」这一个决策上——修完 §9-1 它可能直接变成最强页。

最稳的一页：**分流规则**。列头齐、右栏分组清楚、无卡片噪音、密度专业。它可以作为其余页面的排版基准。

---

## 11 上一轮 8 条遗留问题的复核

| 上轮问题 | 状态 | 证据 |
|---|---|---|
| ① 15 档字号 / 正文 10–11.5 / 圆角字体当正文 | **部分** | 圆角已去（`design: .rounded` → 默认 SF），数字改 mono；但仍 25 档、正文 11pt ×88 处 |
| ② 颜色零语义 / 7 强调色 / 4 套渐变 | **大修** | 单信号色 + 墨阶成立；残留策略三色、Badge violet/amber、`TF.brand` 渐变 2 处 |
| ③ 卡片平权 / 一屏 3 个主按钮 | **部分** | 每屏 1 实心已做到；总览仍有 3 个「启动代理」入口（2 个在主区） |
| ④ 首屏讲 0 / 配置页 60% 空 | **一半** | 配置页用「导入来源」表填满，很好；总览首屏仍全是 0，真实数据在折叠线下 |
| ⑤ `withAnimation` 死代码 / 抓包流零动效 | **已修** | TouchFlowApp.swift:388 有 transition + animation；CaptureView `freshID` 高亮 + `numericText` |
| ⑥ 抓包双空态 / 宽度预算 788>787 | **一半** | 宽度已修（`minWidth: 336`、窗口 900）；空态未改（只加了 CTA），仍居中占满 |
| ⑦ 无列头 / 状态塞数字位 / 焦点环只有开关 | **一半** | 规则表列头已加；adblock「已开启」仍占 26pt 数字位；焦点环仍只有 `TFSwitch` 与文本框 |
| ⑧ SSH 假窗口圆点 / 隐私 0 算 100 | **一半** | SSH 已修（去红黄绿、改 `ssh — 未连接` + `IDLE`，观感大升级）；隐私 100 分未动 |

净结果：**3 项全修、3 项半修、2 项未动**。修对的部分质量很高（不是敷衍），未动的部分恰好是最伤"评审第一眼"的两处（首屏与诚实性）。

---

## 12 再进一步：从 Editorial Instrument 到 **The Ledger**

方向不是换风格，是换**内容形态**：把"卡片页面"彻底换成"账页"。

**为什么是它（三条，按重要性）**
1. **代理工具的本质就是一本账。** 每一次连接都是一条 entry：时间、来源、目标、策略、字节数、是否命中规则。现在的 UI 把账本拆成了卡片和统计块，读者拿不到"这一秒发生了什么"的连续感。账页形态让产品第一次"长得像它做的事"。
2. **账页天然解决白空间与层级。** 账页的节奏来自**ruling（横线）**而不是**card（盒子）**：一条横线就是一条记录，行高即信息密度，页脚一条双线就是合计。空白被结构吸收，不再需要"卡片 padding 制造呼吸"。
3. **它可被截图识别。** "左边 96pt 边注 + 右侧规则化正文 + 右对齐 mono 数字列 + 页脚合计双线"——这个组合在 macOS 工具里几乎没人做，但读者一眼就懂（因为每个人都读过银行流水和报表）。这是能拿 SOTD 的那种「朴素但没人做过」。

**落地到 SwiftUI（三件事）**
```swift
// 1) 边注栏：标签住进 96pt 左边的窄栏，正文不再被标签挤窄
struct LedgerRow<Content: View>: View {
    let label: String; let note: String?
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(TFFont.micro).tracking(1.4).foregroundStyle(TF.textTertiary)
                if let note { Text(note).font(.system(size: 10)).foregroundStyle(TF.textTertiary.opacity(0.75)) }
            }
            .frame(width: 96, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
        .background(alignment: .bottom) { Rectangle().fill(TF.stroke).frame(height: 0.5) }
    }
}

// 2) 页脚合计：一条 1pt + 一条 3pt 双线，右侧 mono 合计
struct LedgerFooter: View {
    let items: [(String, String)]
    var body: some View {
        VStack(spacing: 0) {
            HStack { ForEach(items, id: \.0) { k, v in
                VStack(alignment: .leading) { Text(k).font(TFFont.micro); Text(v).font(TFFont.num(15)) }
            } }
            .padding(.vertical, 12)
            Rectangle().fill(TF.text).frame(height: 1)
            Rectangle().fill(TF.text.opacity(0.25)).frame(height: 1).padding(.top, 2)
        }
    }
}

// 3) 数字列永远右对齐、永远 mono、永远 tabular
Text("1,284,930").font(TFFont.num(12)).monospacedDigit()
    .frame(width: 96, alignment: .trailing)
```
先在**分流规则**（已有表格底子）与**总览**（把 5 个统计 + 最近连接合成一本流水）这两页试点，成功后再推到其它页。不要去改 SSH 终端和抓包详情——它们已经是"仪器面"，账页语法用不上。

**注意**：不要同时保留「卡片 + 账页」两套语言。要么卡片（现状），要么账页。混用会比现在更像 AI 生成的东西。

---

## 13 如果只有 3 天

| 天 | 做什么 | 为什么是它 |
|---|---|---|
| D1 | 字号收敛到 7 档（机械但收益最大）+ hero 压到 150 + 统计条 1 主 4 从 + 删引导条 | 直接决定"专业 / 未完成"的第一判断 |
| D2 | 策略改墨阶 + 删 violet/amber + 隐私改「—」或改名 + 删假斜体 | 决定"有判断力 / 没判断力" |
| D3 | 流量地震仪（28pt 条带）+ 抓包幽灵表格空态 + 三曲线 + 按钮焦点环 | 决定"可提交 / 不可提交" |

做完这 4 组，8 维里 Typography 5.5→7.5、Whitespace 6→7.5、Color 7.5→8.5、Motion 6→7.5、Originality 7.5→8.5，**加权 ≈ 6.7 → 8.1**。SOTD 仍然需要运气，但"可提交"这条线会跨过去。

---

*评审人：design-critic · 二轮 · 基于 21 张截图 + 只读代码核对 · 未修改任何 .swift*


---

## 14 第三轮复核（v4 · 五条硬缺陷修复后）

> 输入：/tmp/tfv4 的 12-seismo-idle（总览）、11-dashboard-seismo（2× 总览）、08-capture2（抓包 1040）、10-privacy3（隐私无样本）、02-rules（分流规则）
> 代码核对：只读 grep / read（行号为本轮实测）· 未改 .swift · 未构建

### 14.1 分数

权重重算说明：前两轮为手工取整，本轮起固定等权（每维 1/8）并给两位小数。按同一权重重算，二轮基线为 **6.56**（此前记录的 6.7 是取整值），本轮见下。

| # | 维度 | 二轮 | 三轮 | 变化 | 判定 |
|---|------|------|------|------|------|
| 1 | Typography | 5.5 | **6.5** | +1.0 | FAIL（差 8.0） |
| 2 | Whitespace | 6.0 | **6.8** | +0.8 | FAIL |
| 3 | Visual Hierarchy | 7.0 | **7.5** | +0.5 | FAIL |
| 4 | Color | 7.5 | **8.0** | +0.5 | **PASS 获奖线** |
| 5 | Motion | 6.0 | **7.0** | +1.0 | FAIL |
| 6 | Micro-interaction | 6.5 | **6.8** | +0.3 | FAIL |
| 7 | Responsive | 6.5 | **7.0** | +0.5 | FAIL |
| 8 | Originality | 7.5 | **8.0** | +0.5 | **PASS 获奖线** |
| | **加权** | 6.56 | **7.20** | **+0.64** | |

**是否达到 8.0 获奖线：否，差 0.80。** 但性质变了：上一轮差的是「一个属于产品的东西」，这一轮差的是**收尾**。Color 与 Originality 已经跨线——单信号色纪律成立，地震仪是一个只有网络工具才有的器物。剩下的全部是执行层，没有一条需要新想法。

### 14.2 本轮做对了什么（逐条对账）

- **总览重排成立。** `12-seismo-idle` 首屏现在是 4 段递进：hero（34pt 配置名 + 44×2 红规则条）→ 统计条（1 主 34pt / 4 从 21pt）→ 地震仪（「流量 / 60S · 静止」+ 基准线 + 右端 2pt 朱红游标）→ 最近连接（列头「时间 / 主机·规则 / 流量」+ 3 行 + 底部一句状态）。这是全 App 第一次**用首屏讲完一件事**。重复的引导条已删，右侧红按钮成为唯一 CTA。
- **地震仪是真器件，不是装饰。** DashboardView.swift:302–352 的实现里，无流量时只画基准线 + 零位游标（`guard ... rawPeak > 0.5 else { ... return }`），没有伪造一条平线——这个克制让它像仪器而不像图表。它是上轮建议里唯一一条被完整实现的，而且实现得比建议好。
- **隐私诚实化到位。** PrivacyView.swift:48 的注释「宁可显示「—」，也不给一个凭空的 100」，代码与截图一致（「无样本」+ 指标「—」+ 刻度尺压暗）。这是判断力的体现，比任何字号修复都值钱。
- **墨阶替代彩虹。** `02-rules` 里 DIRECT 走灰阶、PROXY 走黑、REJECT 才用朱红；右栏出站圆点同步。策略列从「三种品牌色」变成「三种墨度」，这是专业工具的做法。
- **开关尺寸统一。** 全仓只剩 5 处 `width: 32`（上轮是 28/30/34 三种）。
- **搜索焦点改下划线**（Shared.swift:143–147：`open ? 1.5 : 1` 底边线）——比整框红描边更像仪器。
- **字号从 25 档降到 17 档**，12pt 成为主力（78 处），页标题 22 tracking -0.6、hero 34 tracking -1.1。

---


### 14.3 若仍差，最多 5 条「再改就能跨线」

先说清一件事：**8.0 是均值线，意味着没有任何一维可以低于 7.7。** 现在还有 5 个维度在 7.0–7.5（Typo 6.5 / White 6.8 / Micro 6.8 / Motion 7.0 / Resp 7.0），所以跨线不是「再修几个 bug」，而是「把这 5 维各推一档」。下面 5 条按「一条修法能同时推动几个维度」排序。

**1｜抓包 1040 仍然渲染空右栏（Whitespace + Responsive + Hierarchy）**
- 证据：`08-capture2` 左列表已很专业（列头「方法 / 主机·路径 / 状态 / 耗时」+ 7 行 + 底部「暂无 HTTP 请求」+ 朱红 CTA），但右栏仍是 375×505 的居中空态「选择左侧请求查看详情」——整页仍有 ~40% 面积零信息，而 1040 正是评审窗口。
- 代码：CaptureView.swift:71 `if geo.size.width < 740`。1040 窗口的内容宽 = 1040 − 216（侧栏）− 1（分割）− 64（左右 padding 32）= **759**，比阈值只多 19pt，所以永远走分栏分支。
- 修法：阈值 740 → **820**（等价窗口 ≈1100pt），并且右栏改为条件渲染：
  ```swift
  if let req = current, geo.size.width >= 820 {
      detail(req)
  }
  ```
  无选中项时右栏根本不存在，列表吃满宽度。
- 验收：1040 全屏、无任何请求时，页面上只有一列内容，右侧没有空白面板。

**2｜隐私 hero 左格塌陷（Typography + Whitespace + Hierarchy）**
- 证据：`10-privacy3` hero 左三分之一现在只有 22pt 的「无样本」+ 一条几乎看不见的刻度尺，而这块原来站着 48pt 的「100」。右侧段落 12pt 反而成了视觉主体——hero 的锚点从「读数」漂到了「说明文字」。
- 代码：PrivacyView.swift:71 `Text("无样本").font(TFFont.display(22, weight: .semibold))` 占据原 48pt 数字位；:76 `scoreRuler(hasSample ? r.score : 0, tint: tint)` 把刻度尺画成全暗。
- 修法：保留仪器的光学质量，只换读数内容——
  ```swift
  Text(hasSample ? "\(r.score)" : "—")
      .font(TFFont.num(48, weight: .medium))
      .foregroundStyle(hasSample ? TF.text : TF.textTertiary)
  // 「无样本」降级为数字下方的 eyebrow：
  Text("无样本 / NO SAMPLE").font(TFFont.overline).tracking(1.2).foregroundStyle(TF.textTertiary)
  ```
  刻度尺传 `hasSample ? r.score : nil`，nil 时把 0–55 段画成 6% 斜纹带（「样本不足区」），刻度线保持 100% —— 分数缺失，仪器仍在。
- 验收：遮住右侧段落，左格单独看仍是一块「有读数位置的仪表」。

**3｜规则页 DIRECT 太淡、类型 chip 像禁用（Color + Typography）**
- 证据：`02-rules` 整张表 8 行 DIRECT 全是浅灰，是这张页面里最高频的值，却是最淡的元素；类型 chip（IP-CIDR / SUFFIX / GEOIP）改成灰底灰字后，读起来像「不可选」的禁用标签，而不是类型元数据。
- 代码：RulesView.swift:402 `if p == "DIRECT" { return TF.text.opacity(0.45) }`——在纸底 #F6F4EF 上约 **2.9:1**，低于 4.5:1；:366–369 策略文本直接用 `policyColor`。
- 修法：策略值改 `TF.textSecondary`（≈0.66，≥4.5:1）；层级靠字重与大小，不靠透明度。类型去掉 pill 底与描边：
  ```swift
  Text(rule.kind.rawValue.uppercased())
      .font(TFFont.mono(10, weight: .regular))
      .tracking(0.8)
      .foregroundStyle(TF.textTertiary)   // 不再加背景与边框
  ```
- 验收：把截图转灰度，DIRECT 仍是可读的一列；类型列不再有「按钮感」。

**4｜地震仪的峰值归一化会让整条线跳变（Motion + Originality）**
- 证据：静态图只能给出「静止」这一种形态，器件本身的形状从未被看见；而实现里归一化用的是窗口内瞬时最大值。
- 代码：DashboardView.swift:320–328 `let rawPeak = rateHistory.max() ... let peak = rawPeak`，纵轴按 `v / peak`。一个尖峰进入/离开 60 秒窗口时，历史折线会整体缩放——**形状会自己跳舞**，这在评审眼里是「图表不稳」而不是「仪器在动」。
- 修法：换成衰减上限 + 压缩映射，
  ```swift
  @State private var ceiling: Double = 1
  // 每个采样：ceiling = max(rawPeak, ceiling * 0.94)   // 尖峰走后缓慢回落
  // 映射用 sqrt，让 1KB/s 与 1MB/s 的区别仍然可见
  let y = mid - (mid - 2) * sqrt(min(1, v / ceiling))
  ```
  再加一个**演示流量**入口（设置页隐藏开关，或 ⌥ 点统计条触发 30 秒合成脉冲），专门用于截图与首启——否则评委永远看不到这个签名器件的形状。
- 验收：连续两次截图间隔 30 秒，除新采样外折线既有部分不位移。

**5｜去广告页整页未动（Whitespace + Hierarchy + Typography）**
- 证据：本轮 5 条改动没有落到这页。它仍是我上一轮判定的「最拖后腿」：4 张全宽等高卡上下堆叠无疏密；`已开启` 这种状态词仍塞在 26pt 数字位，与旁边两个「0」抢同一条基线。
- 代码：AdBlockView.swift:60–61 `metric("元素隐藏 / COSMETIC", ... ? "已开启" : "已关闭")`。
- 修法：第三格换回真数字（`engine.profile.adblock.cosmeticRules.count` →「0 条隐藏规则」），状态降级为 10pt 右侧 mono（`ENABLED` / 10pt，跟着标题走）；页面拆两个章节：**引擎**（4 行，发丝线）与**名单**（过滤列表 / 白名单并排 1:1），引擎卡下方接一条与总览同款的地震仪（`命中 / 60S`）。
- 验收：把这页截图单独发给没看过这个 App 的人，「已开启」不再被读成一个数值。

### 14.4 次级（不占 5 条名额，但会扣分）

- **骨架屏语义**：总览 3 行、抓包 7 行的灰色骨架条读作「正在加载」，而 App 是空闲态——用户会等一个不会到来的加载。改成幽灵行（每格 mono `—`）+ 表底 1px 合计线 + 「0 条」。
- **设置页 900pt 仍两列**，三处中间截断仍在（上游 DNS / 证书路径 / MITM 主机）。
- **按钮无焦点态**：Theme.swift:251 / 273 两个 ButtonStyle 里没有焦点分支；全仓 `.focused` 共 10 处，全部给文本框与列表，无一处给按钮。键盘用户在一屏里找不到自己停在哪。
- **`dropDestination` 仍无 `isTargeted`**（智能学习的拖拽区松手前无反馈）。
- **MATCH 仍用 amber**，是墨阶体系里唯一的残留彩点。
- **Typography 到 7.5 的最后一档**：9/9.5/10 合成 9.5，11/11.5 全部并入 12 → 17 档降到 11 档（9.5 / 10.5 / 12 / 12.5 / 13 / 14 / 15 / 18 / 20 / 22 / 34）。

### 14.5 一句话结论

**7.20 / 10，仍未到 8.0，但差的已经不是设计而是收尾**——Color 与 Originality 双双跨线，说明方向已被证明；按均值线算，8.0 要求没有任何一维低于 7.7，所以下一步不是再找灵感，而是把「抓包空右栏、隐私左格塌陷、DIRECT 太淡、地震仪抖动、去广告整页」这 5 处收干净，再补一轮微交互（焦点环 / 共享元素 / reduceMotion），届时约 7.6–7.8，剩下的 0.2 交给真实流量跑起来的截图。

*第三轮复核 · design-critic · 基于 5 张 v4 截图 + 只读代码核对 · 未修改任何 .swift*


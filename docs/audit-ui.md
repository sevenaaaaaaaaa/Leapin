# TouchFlow 交互与入口审计（只读）

> 审计范围：`Sources/TouchFlowApp/` 全部 SwiftUI 代码（TouchFlowApp.swift、Design/、Views/）。
> 基线快照：2026-11-05 12:23:06，18 个文件 4703 行（`git HEAD 历史提交` + 未提交改动，已复制到 `/tmp/tf-audit-snap`）。
> 复核时间 12:33：工作树增至 5024 行，`RulesView.swift`(492)、`CaptureView.swift`(410) 已被并行实现改写；本文相关条目已按复核结果更新，其余 7 页的行号与基线一致。
> 全部行号为仓库根相对路径，可直接 grep 定位；本文未修改任何 .swift，也未执行 swift build（按委托要求避免抢锁），因此“能否编译”不在结论范围内。
> **复核 2（12:40，并行实现已继续推进）**：以下条目已被对方改掉，清单里保留原证据仅供追溯，**不要再做**：N1 强制解包（`NASView.swift` 已无 `URL(string:...)!`）、X04 toast 直写（`app.toast =` 现为 0 处）、T1 端口输入（`SettingsView.swift:260` 已加 1–65535 内联校验，但 `:301-303` 保存仍用 `?? 旧值`，需确认按钮已被校验拦住）。
> 仍成立的高价值项：X01 焦点环（无 `TFButton`/`tfFocusRing`）、X02 reduce-motion（仍只有 `Interactions.swift:15` 一处）、X03 进度（`ProgressView` 0 处）、X05 撤销（0 处）、X08 ⌘F（除 Dashboard/Rules/Capture/AdBlock/Profiles 外，SSH/NAS/Learn/Privacy/Settings 仍未接）、X10 对比度、X12 菜单栏 4 页签、X13 ⌘,、X14 URL scheme、P1 隐私假绿灯（`PrivacyView.swift:136`/`:138` 仍在）、S3 SSH 硬编码配色。
> 原语接线进度：AdBlock 0 个、SSH 0、NAS 1、Learn 0、Privacy 0、Profiles 4、Settings 1（`TFSearchField|TFEmptyState|tfConfirm|TFProgressLine|TFRow` 计数）。

---

## 1. 现状概览

- **骨架已经够用**：10 页自绘侧栏 + ⌘K 命令面板（`Sources/TouchFlowApp/Design/CommandPalette.swift:24-101`）+ ⌘1…⌘0 切页（`Sources/TouchFlowApp/TouchFlowApp.swift:42-45`）+ 全局 ⌘⇧Space（`Sources/TouchFlowApp/Platform.swift:31-57`）+ 窗口尺寸与页签恢复（`Platform.swift:13-27`、`TouchFlowApp.swift:170-173`）+ 首启引导（`Design/Onboarding.swift:10-17`）+ kind 化 Toast（`Design/Toast.swift:4-26`）。
- **但“原语写了、页面没接”**：TFSearchField / TFEmptyState / TFChip / tfConfirm 目前只落在 Rules、Capture 两页；其余 7 页（AdBlock、SSH、NAS、Learn、Privacy、Profiles、Settings，共 1491 行）仍是手写搜索框、旧 `EmptyHint`、直接给 `toast` 赋字符串。
- **键鼠一致性的缺口在“看得见”这一层**：全仓 `@FocusState` 9 处，focus 环只在总览手写了一次（`Views/DashboardView.swift:328-331`）；`TFPrimaryButtonStyle`/`TFGhostButtonStyle`/`TFSwitch` 都没有 focus 视觉，Tab 到任何按钮都看不到落点。
- **反馈层不完整**：`ProgressView` 0 处、撤销 0 处、`accessibilityReduceMotion` 仅 1 处（`Design/Interactions.swift:15`）、9 处 `app.toast =` 绕过 kind；失败态大多只有一行红字，没有重试按钮。
- **入口层“代码写了但系统不认识”**：`.onOpenURL` + `handle(url:)` 已实现（`TouchFlowApp.swift:180-199`、`:296`），但 `scripts/Info.plist` 无 `CFBundleURLTypes`；无 Settings scene（⌘, 无效）；无登录项；菜单栏与 Dock 只给 4 个页签（应为 10）。

---

## 2. 差距清单

### 2.1 横切（影响全部 10 页）

| ID | 证据（文件:行） | 问题 | 具体改法（落到函数/类型级） | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| X01 | `Design/Theme.swift:231-246`、`:248-258`、`:292-318`；`Views/SettingsView.swift:291`、`:307`；focus 环唯一实现 `Views/DashboardView.swift:328-331` | 自定义 ButtonStyle 丢弃系统 focus ring，TFSwitch 同样；键盘 Tab 后无落点提示（WCAG 2.4.7 不达标） | 在 `Design/Interactions.swift` 新增 `struct TFFocusRing: ViewModifier`（入参 Bool）与 `extension View { func tfFocusRing(_ on: Bool) -> some View }`；ButtonStyle 内读不到焦点，故新增 `TFButton` 容器（内部 `@FocusState` + `.focusable()`）替换 `TFPrimaryButtonStyle`/`TFGhostButtonStyle` 的调用点；TextField 沿用 Dashboard 已验证的 overlay 描边法 | 全站按钮/开关/输入框；键盘与 VoiceOver 用户 | P0 | M |
| X02 | `Theme.swift:275`（`repeatForever` 脉冲）、`Theme.swift:313`（spring）、`DashboardView.swift:124`（`symbolEffect(.pulse)`）、`TouchFlowApp.swift:286`、`Design/Onboarding.swift:72`/`:77`、`Design/Interactions.swift:149`、`TouchFlowApp.swift:347` | 系统“减弱动态效果”开启后仍有 7 处持续或位移动画 | `Theme.swift` 增 `enum TFMotion { static func animation(_ base: Animation?) -> Animation? }`（读 `@Environment(\.accessibilityReduceMotion)`）；`StatusDot` 在 reduce 时只保留静态色；`TFSwitch` 用 `.animation(reduceMotion ? nil : .spring(...))`；symbolEffect 改为 `isActive: app.isRunning && !reduceMotion` | 全站动效；前庭敏感用户 | P1 | S |
| X03 | 全仓 `ProgressView` 0 处；`Views/SettingsView.swift:222-231`、`Views/ProfilesView.swift:89-94`、`Views/RulesView.swift:67`、`Views/NASView.swift:26-39`、`Views/LearnView.swift:111` | 启动/停止、重载配置、扫描 NAS、OCR、启用配置都没有进度或 loading，按钮保持可点，只能猜 | `AppModel` 增 `@Published var busy: Set<BusyKey>`（或在页内 `@State`）；为 `TFPrimaryButtonStyle` 加 `isLoading` 参数（12pt 旋转指示 + 内部 `.disabled`）；长任务统一 `withBusy(key) { ... }` 包装 | 7 个页面；首次使用体感 | P1 | M |
| X04 | 9 处直写：`SettingsView.swift:231`、`Views/PrivacyView.swift:192`、`Views/LearnView.swift:216`/`:229`/`:231`/`:253`、`Views/NASView.swift:163`/`:235`/`:237` | 直写 `app.toast = "..."` 不更新 `toastKind`/`toastAction`，上一次的 kind 与 action 残留，失败提示可能显示成功样式 | 把 `toast` 改成 `@Published private(set)`，只保留 `showToast(_:kind:actionTitle:action:)`（`TouchFlowApp.swift:158-166`）；9 处改为带 kind 调用（失败用 `.error`） | 全站反馈语义正确性 | P1 | S |
| X05 | 全仓 `undo`/`UndoManager` 0 处；`LearnView.swift:250-256`、`PrivacyView.swift:185-193`、`RulesView.swift:86`（确认删除后仍无撤销）、`CaptureView.swift:90-99` | 破坏性操作只有“确认”，没有“撤销”；应用建议后建议列表立刻清空 | `AppModel` 增 `func undoable(_ label: String, apply: () -> Void, undo: @escaping () -> Void)`，内部调 `showToast(label, kind: .success, actionTitle: "撤销", action: undo)`（Toast 已支持 action，见 `Design/Toast.swift:47-53`） | 全站；误操作成本 | P1 | M |
| X06 | 已有确认：`Views/ProfilesView.swift:119-133`、`RulesView.swift:86`、`CaptureView.swift:90`；缺失：`Views/AdBlockView.swift:141-145`（删过滤列表来源）、`:167-172`（整份白名单覆盖）、`PrivacyView.swift:185-193`（改 adblock 名单并 restart） | 同一类“不可撤销的配置覆盖”，有的确认、有的即时生效 | 全部改走 `tfConfirm(...)`（`Interactions.swift:202-214`，destructive: true）；白名单加脏标记（`allowText != allowList.joined`），有脏才可保存 | AdBlock / Privacy；配置丢失风险 | P0 | S |
| X07 | `Views/Shared.swift:114-130`（EmptyHint 只有 icon+text，无 CTA）；仍在用旧空态：`DashboardView.swift:404`、`PrivacyView.swift:165`、`ProfilesView.swift:67`、`NASView.swift:173` | 空态只解释“为什么空”，没有“下一步”按钮 | 4 处替换为 `TFEmptyState(actionTitle:action:)`（`Interactions.swift:164`）；`EmptyHint` 标 deprecated 并删除，防止新代码继续用 | 4 个页面；新用户路径 | P1 | S |
| X08 | 消费点仅 `DashboardView.swift:33`、`RulesView.swift:99`、`CaptureView.swift:100`；未响应页：`AdBlockView.swift:78`、`SSHView.swift:40-71`、`NASView.swift:47`、`LearnView`（主输入 `:76` 区间）、`PrivacyView`、`ProfilesView`、`SettingsView.swift:286-316` | 命令菜单提供“搜索当前页面 ⌘F”（`TouchFlowApp.swift:39-40`），但 7 页不响应 → 明确的假入口，比没有更伤 | 7 页各加 `.onChange(of: app.searchFocusRequest)` 并给主输入框 `@FocusState`；能换 `TFSearchField` 的直接换；Settings/Profiles 没有搜索对象，改为跳到首个可编辑字段，并按 section 改写菜单文案 | 7 个页面；最常用的就地检索 | P0 | M |
| X09 | a11y 修饰 21 处，集中在 `Theme.swift:316`、`Interactions.swift:37-38`/`:228`、`Toast.swift:73`、`TouchFlowApp.swift:421`、`DashboardView.swift:210`/`:322`/`:356`；`SidebarRow` 无 isSelected（`TouchFlowApp.swift:449-487`）；`PageHeader`/`SectionHeader` 无 heading（`Theme.swift:150-227`）；`FieldRow` 与控件未关联（`SettingsView.swift:237-259`） | VoiceOver 不播报当前页签；标题不进 rotor；表单控件读不到标签 | `SidebarRow` 加 `.accessibilityAddTraits(selected ? .isSelected : [])`；`PageHeader` 加 `.accessibilityAddTraits(.isHeader)`；`PlainField`/`NumField` 增 `label` 参数并在内部 `.accessibilityLabel(label)`；`StatusChip`/`Badge` 补语义 | 全站；VoiceOver | P1 | M |
| X10 | `Theme.swift:33`（textTertiary `0x8B98AB` / `0x6B7A90`）；浅底 `0xF3F5FA` 上约 2.9:1；`font(.system(size: 9…))` 31 处 | 9–10pt 次要文字低于 WCAG AA 4.5:1 | 浅色值改 `0x5C6A7D`（约 4.8:1），并核查 `StatusChip`（`TouchFlowApp.swift:593-617`）与 `Badge`（`Shared.swift:96-112`）的叠加底色；字号下限提到 10 | 全站可读性 | P0 | S |
| X11 | `Theme.swift:292-318`（自绘 Button + spring，仅 `:316` 有 accessibilityRepresentation） | 开关只能鼠标点；Tab 无法聚焦，空格/方向键无效 | 保留外观，改 `.focusable()` + `.onKeyPress(.space)` 切换 + `tfFocusRing`；或直接 `Toggle().toggleStyle(.switch).labelsHidden()`（macOS 27 渲染 bug 需回归一次） | 所有开关：`DashboardView.swift:134`、`AdBlockView.swift:50`/`:181`、`SettingsView.swift:261-284` | P1 | S |
| X12 | `TouchFlowApp.swift:690-708`（硬编码 `[.dashboard, .rules, .capture, .settings]`）；`Platform.swift:94`（Dock 菜单同） | PLAN 要求 10 页签直达，实际只给 4 个 | 改 `ForEach(AppModel.Section.allCases)`，行尾显示 ⌘N 提示 | 菜单栏常驻用户 | P2 | S |
| X13 | `TouchFlowApp.swift:11-21` 只有 `Window(id: "main")`；`.commands:23-54` 未覆盖 appSettings | macOS 标准“设置”快捷键 ⌘, 无效 | 加 `CommandGroup(replacing: .appSettings) { Button("设置…") { app.go(to: .settings) }.keyboardShortcut(",") }`；或新增 `Settings { SettingsScene() }` | 全站；习惯 ⌘, 的用户 | P1 | S |
| X14 | `TouchFlowApp.swift:180-199`（handle）、`:296`（onOpenURL）；`scripts/Info.plist` 无 `CFBundleURLTypes` | `touchflow://` 完全无法被系统唤起；Dock/脚本/快捷指令集成全部落空 | Info.plist 加 `CFBundleURLTypes`（scheme `touchflow`）；`handle` 的分支补 `openWindow(id: "main")` + `NSApp.activate`；改完必须重跑 `scripts/build-app.sh`（`:19` 复制 plist） | 外部入口集成；需重新打包验证 | P1 | S |
| X15 | 全仓无 `SMAppService`（grep）；`SettingsView.swift:127-162` 高级区无该项 | 常驻型工具无法开机自启，每次手动开 | `SettingsView` 增 ToggleRow「登录时启动」，绑定 `SMAppService.mainApp.register()/unregister()`，处理 `.requiresApproval`（引导到系统设置）；系统框架，零依赖 | 设置页；符合项目约束 | P2 | M |
| X16 | `Onboarding.swift:10-17`（三步无证书环节）、`:123-126`（finish 只写 `tf.onboarded`）；无重播入口 | 用户装完仍可能因未信任 CA 导致所有 HTTPS 报错；引导看过一次无法再看 | 加第 4 步「安装并信任 CA」，复用 `app.installCA()`（`TouchFlowApp.swift:246-254`）并要求勾选“我已信任”；`SettingsView` 加「重播引导」（清 `tf.onboarded` 后 `showOnboarding = true`） | 首启漏斗 | P2 | S |
| X17 | `TouchFlowApp.swift:230-244`（`NSSavePanel.runModal`）、`LearnView.swift:237-243`（`NSOpenPanel.runModal`） | 导出/选图期间主线程冻结 | 改 `panel.begin { }` 或 `.fileImporter`；回调里再 showToast | 导出、OCR 选图 | P2 | S |
| X18 | `TouchFlowApp.swift:309-317`：`startAccessingSecurityScopedResource` 后 `defer { stop }` 在异步导入完成前就执行 | 大配置导入可能间歇失败（scope 已释放） | 把 start/stop 收进 async 函数，`defer` 置于 Task 内部；或先 `FileManager.copyItem` 到临时目录再解析 | 配置导入路径 | P1 | S |
| X19 | `CommandPalette.swift:103-110`（只匹配固定命令的 title/subtitle）、`:24-101`（无规则/设置项） | 无法“跳到某条规则”或“打开某个设置项”；无最近使用 | `results` 增规则（`engine.profile.rules`，上限 50，按 raw 匹配）与设置项静态表；UserDefaults 记 `recentRuns` 置顶；按 group 分段显示标题 | ⌘K 常客 | P2 | M |
| X20 | `CaptureView.swift` 每次 body 全量过滤；`Sources/TouchFlowRuntime/TouchFlowEngine.swift:272-290` 每条 flow 一次 `Task { @MainActor }` append；上限 flows 2000 / captures 1000 | 代理跑满时抓包页 CPU 高、选中项闪烁 | UI 侧：`@State visible` 由 0.25s 节流任务从 `engine.captures` 拉取（保留 `frozen`/`paused` 语义，`CaptureView.swift:125-141`）；行视图加 `.equatable()`；engine 侧批量 flush 属 runtime 层，需 lead 授权 | 抓包页性能 | P1 | M |
| X21 | `DashboardView.swift:62-67`（错误只有红字）、`SettingsView.swift:222-231`（恒“设置已保存”）、`ProfilesView.swift:89-94`（启用失败无提示）、`RulesView.swift:67`（重载失败静默） | 失败后不知道该做什么，也没有重试按钮 | 统一 `do/catch` → `app.showToast(..., kind: .error, actionTitle: "重试", action: retry)`；错误文案附修复动作（如“端口被占用 → 改端口”直达 settings 页） | 全站错误路径 | P1 | M |

### 2.2 逐页

**总览（DashboardView.swift，434 行）**

| ID | 证据（文件:行） | 问题 | 具体改法 | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| D1 | `Views/DashboardView.swift:149-175`（仅 retry/proxy/verify/start 四个分支） | 已启动且开系统代理但未信任 CA 时没有任何提示，HTTPS 全红也找不到原因 | `nextStep` 增分支：`mitmEnabled && !caTrusted` → 「安装并信任 CA」，action 调 `app.installCA()`；需 engine 暴露只读 `caInstalled`/`caTrusted` | 总览首屏 | P1 | S |
| D2 | `DashboardView.swift:408-413` 用 `FlowRow`（`Shared.swift:132-180` 纯展示，无 onTap） | 看到可疑域名无法一键跳抓包定位 | `FlowRow` 增 `onTap` 闭包（或包一层 TFRow），点击后 `app.go(to: .capture)` 并带入 host 过滤（`CaptureView` 需接受外部初始过滤参数） | 总览→抓包动线 | P2 | S |
| D3 | `DashboardView.swift:428`（`port: 443` 固定） | 无法解释非 443 端口（8080、22 等） | 增端口输入（默认 443），或解析 `host:port` 形式 | 分流解释器 | P2 | S |
| D4 | `DashboardView.swift:62-67` | 只知道失败，看不到日志上下文 | 错误行右侧加「查看日志」→ `app.go(to: .settings)` 或日志面板（engine.logs 已有 1500 条上限） | 排障 | P2 | S |

**分流规则（RulesView.swift，492 行，已被并行改写）**

| ID | 证据（文件:行） | 问题 | 具体改法 | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| R1 | `Views/RulesView.swift:14`（`selection: String?` 单选）、`:167-174` | 想清理一类规则只能逐条删 | `selection` 改 `Set<String>`，加 ⌘A 全选、Shift 连选、批量删除（走 tfConfirm）、批量改策略 | 规则管理效率 | P1 | M |
| R2 | `RulesView.swift:15-21` 过滤后按 profile 原序 | 数百条规则难以按策略巡检 | 加排序控件（原始序/策略/类型/匹配值），或侧栏策略分组计数可直接点击过滤 | 规则巡检 | P2 | S |
| R3 | `RulesView.swift:124-130`（`selectOutbound` → `restart: true`，`TouchFlowEngine.swift:371-377`） | 点一下 Picker 全栈重启，已有连接全断且无提示 | 切换前 tfConfirm（“会重启代理并断开当前连接”），或改热更新（需 runtime 支持） | 规则侧栏 | P1 | S |
| R4 | `RulesView.swift:380-412`（格式校验、去重、预览已到位） | 规则是否真的命中无法就地验证 | 行右键加「测试该规则命中的域名」，复用 `engine.explain` | 规则可信度 | P2 | M |

**去广告（AdBlockView.swift，193 行，未接线）**

| ID | 证据（文件:行） | 问题 | 具体改法 | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| A1 | `Views/AdBlockView.swift:159-174` | 白名单编辑后误点保存即整份覆盖，且触发 restart；无脏标记 | 见 X06；另加 `allowText != allowList.joined` 的脏标记控制按钮可用性 | 白名单 | P1 | S |
| A2 | `AdBlockView.swift:130-149`（删除按钮在 `:141-145`） | 误删一个过滤来源立即生效并重启，无确认无撤销 | tfConfirm + 撤销（X05） | 过滤列表 | P1 | S |
| A3 | `AdBlockView.swift:20-29`（只有计数，无命中列表） | “已拦截 1234”无法定位哪条规则在拦、哪个域名被误拦 | 新增「最近拦截」表：engine 侧加 50 条环形缓冲（或复用 flows 中被拦项），行右键「加入白名单」 | 去广告可用性 | P1 | M |
| A4 | `AdBlockView.swift:58-69`（两个子开关 `restart: true`） | 每切一次开关代理重启一次 | 改 `restart: false` + 引擎热更新，或确认框说明会断开连接 | 去广告设置 | P2 | S |
| A5 | `AdBlockView.swift:90-106`（测试结果只展示） | 查到被拦后不能一键转成白名单/规则 | 结果区加「加入白名单」按钮，写 profile 后 showToast(.success) | 去广告排障 | P2 | S |

**抓包（CaptureView.swift，410 行，已被并行改写）**

| ID | 证据（文件:行） | 问题 | 具体改法 | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| C1 | `CaptureView.swift` 列表行（复核后 `:191` TFRow）无 `.contextMenu` | 抓包最常见的动作（复制 URL / 复制为 cURL / 加规则）全缺 | 行加 contextMenu：复制 URL、复制为 cURL（method+headers+body）、加入分流规则、加入白名单、删除该条 | 抓包日常 | P1 | M |
| C2 | `CaptureView.swift:254-265`（导出恒为全量 HAR） | 只想导出过滤后的几条不行 | 工具栏导出拆成「导出全部 HAR / 导出当前过滤 N 条」 | 抓包导出 | P2 | S |
| C3 | `CaptureView.swift` 详情 body 用 `prefix(4000)`（基线 `:236`，复核后行号后移） | 大响应看不到全文，也无另存 | 加「显示全文」「另存为…」；超长时按需解码避免卡顿 | 抓包详情 | P2 | S |

**SSH（SSHView.swift，250 行，未接线）**

| ID | 证据（文件:行） | 问题 | 具体改法 | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| S1 | `Views/SSHView.swift:11-25`、`:36-71` | 没有主机历史/收藏，每次手输主机、用户、私钥路径 | 主机列表（UserDefaults 存最近 10 条）+ 收藏置顶；连接表单改为下拉选择 + 可编辑 | SSH 常用性 | P1 | M |
| S2 | `SSHView.swift:223`（失败只 `output += "[连接失败] ..."`） | 错误埋在滚动输出里，没有重试按钮 | 表单下方 error banner + 「重试」（保存上次参数） | SSH 排障 | P1 | S |
| S3 | `SSHView.swift:141-186`（至少 10 处 `Color(red:...)` 硬编码） | 与 TF 主题脱节；浅色模式下终端仍是深底，边框/标签对不上 | 定义 `TF.terminalBackground/Foreground/Dim/Success`（dyn 双色），替换全部硬编码 | SSH 观感 | P1 | M |
| S4 | `SSHView.swift:138-190` | 输出只能手动选择复制，无清屏/保存 | 加「清屏 / 复制全部 / 保存输出」三个按钮 | SSH 使用闭环 | P2 | S |
| S5 | `SSHView.swift:198-233` | 网络抖动后命令静默失败，无断线提示 | 连接状态心跳 + 「连接已断开，重连」 | SSH 稳定性 | P2 | M |

**NAS（NASView.swift，242 行，未接线）**

| ID | 证据（文件:行） | 问题 | 具体改法 | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| N1 | `Views/NASView.swift:156`：`URL(string: "smb://.../...")!` | host/share 含空格或非 ASCII 时 URL 构造失败直接崩溃；同时违反项目“禁止强制解包”硬约束 | 改 `if let url = URL(string:)`，或 `URLComponents` 逐段 percent 编码；失败走 `showToast(.error)` | App 崩溃风险 | P0 | S |
| N2 | `NASView.swift:163`（toast「已读取保存的密码」） | 实际是从 Keychain 读，文案误导为明文保存 | 改「已从钥匙串填入密码」 | 隐私信任 | P2 | S |
| N3 | `NASView.swift:26-39`、`:213-218` | 扫描只有按钮文案切换，没有“已发现 N 台”、也没有不确定进度 | 加计数 + 不确定进度条（TFProgressLine） | NAS 发现 | P2 | S |
| N4 | `NASView.swift:173`（EmptyHint 无 CTA） | 空态只能读文案 | TFEmptyState + 「开始扫描」 | NAS 首屏 | P1 | S |
| N5 | `NASView.swift:228-239`（失败只 toast） | 权限/共享名错误没有后续指引 | 失败 toast 带 actionTitle「查看系统日志」，或表单内联提示 | NAS 挂载 | P2 | S |

**智能学习（LearnView.swift，257 行，未接线）**

| ID | 证据（文件:行） | 问题 | 具体改法 | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| L1 | `Views/LearnView.swift:108-125`（busy 只换 hourglass 图标）、`:221-233` | OCR 期间全页锁死观感，且无法中止 | TFProgressLine + 取消按钮（`Task.cancel`），按钮 isLoading | 智能学习 | P1 | S |
| L2 | `LearnView.swift:250-256`（写入后 `suggestions.removeAll()`） | 一次写 n 条规则后建议清空，写错无法回退 | 用 X05 的 `undoable` 包装，toast 给「撤销」 | 智能学习 | P1 | S |
| L3 | `LearnView.swift:139-160` | 已识别应用不可删除/编辑，识别多了只能清空重来 | 行上加删除按钮；提供「手动添加应用名」输入 | 智能学习 | P2 | S |
| L4 | `LearnView.swift:237-243`（`NSOpenPanel.runModal`） | 见 X17 | 同 X17 | OCR 入口 | P2 | S |
| L5 | `LearnView.swift:171-198`（无排序，rationale 字段 `:188` 只在行内） | 置信度高低混排 | 按 `confidence` 降序；行上「?」展开 rationale | 建议质量 | P2 | S |

**隐私（PrivacyView.swift，234 行，未接线）**

| ID | 证据（文件:行） | 问题 | 具体改法 | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| P1 | `Views/PrivacyView.swift:136`、`:138`（`check("日志自动脱敏", true, ...)`、`check("凭据保存在钥匙串", true, ...)`） | 两条加固项永远显示通过，与实际实现无关——安全类页面上的假绿灯最伤信任 | 接真实信号：脱敏由 Redactor 是否启用决定、凭据由 Keychain 是否存在条目决定（engine 暴露只读 BOOL）；无法判定时显示灰色「未检测」而非绿勾 | 安全信任 | P0 | S |
| P2 | `PrivacyView.swift:22-24`（report 在 body 计算属性里全量 audit） | 隐私页开着时，每条 flow 追加都触发全量重算 | 改 `@State report` + `.task(id: engine.stats.captures)` 节流 1s 重算；或 engine 侧缓存 | 隐私页性能 | P1 | S |
| P3 | `PrivacyView.swift:169`（`prefix(30)`） | 第 31 条之后看不见，也没有“查看全部” | 加「显示全部」或分页；默认按严重度排序 | 隐私巡检 | P2 | S |
| P4 | `PrivacyView.swift:164-167`（EmptyHint 无 CTA） | 见 X07 | TFEmptyState + 「打开抓包」 | 隐私首屏 | P1 | S |
| P5 | `PrivacyView.swift:185-193` | 「加入拦截」直接改 `adblock.blockLists` 并 restart，无确认无撤销 | tfConfirm（说明会改配置并重启）+ 撤销 | 隐私→去广告动线 | P1 | S |
| P6 | `PrivacyView.swift:224-230`（文案阈值 85/60，配色阈值 80/55） | 出现“85 分说良好但颜色是琥珀”的错位 | 抽 `enum TFPrivacyLevel` 单一阈值表，文案与配色共用 | 隐私页一致性 | P2 | S |

**配置（ProfilesView.swift，139 行，未接线）**

| ID | 证据（文件:行） | 问题 | 具体改法 | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| F1 | `Views/ProfilesView.swift:67`（EmptyHint 无 CTA） | 新用户不知道去导入 | TFEmptyState + 「导入配置」（`app.showImporter = true`） | 配置页首屏 | P1 | S |
| F2 | `ProfilesView.swift:89-94`（`await engine.activate` 无 loading/无 catch） | 点击后无反馈，失败静默 | 按钮 isLoading + do/catch → toast(.error, 重试) | 配置切换 | P1 | S |
| F3 | `ProfilesView.swift:65-112` | 无法标记常用配置，每次手动选 | 行上加星标 + 「启动时使用默认配置」 | 配置管理 | P2 | S |
| F4 | `TouchFlowApp.swift:219-228`（导入成功只 toast） | 用户还要自己找到那条配置再点启用 | toast actionTitle「立即启用」→ `engine.activate(new.id)` | 导入动线 | P2 | S |

**设置（SettingsView.swift，316 行，未接线）**

| ID | 证据（文件:行） | 问题 | 具体改法 | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| T1 | `Views/SettingsView.swift:208-218`（`UInt16(x) ?? next.general.mixedPort` 等 4 处） | 输错端口保存后静默保留旧值，用户以为改了 | 输入即校验 1...65535，红框 + 内联错误，保存按钮 disabled；去掉 `?? 旧值` 回落 | 设置正确性 | P1 | S |
| T2 | `SettingsView.swift:222-231`（stop → update → start，无 await 结果，末尾恒 `app.toast = "设置已保存"`） | 启动失败也提示“设置已保存”，代理实际没起 | 改为一次完整重启并 await 结果：成功 → showToast(.success)；失败 → showToast(.error, "启动失败：…", actionTitle: "查看原因")；保存期间按钮 loading | 设置页最关键动作 | P1 | S |
| T3 | `SettingsView.swift:183-200`（`loaded` 一次性守卫，无外部变化监听） | 配置在别处被切换/导入后，设置页仍显示旧值，保存会写回旧值覆盖新配置 | `.onChange(of: engine.profile.id)` 或 `.task(id:)` 重新 load；用 draft 与 profile 比较，显示「已修改」并可放弃修改 | 设置正确性 | P1 | M |
| T4 | `SettingsView.swift:127-162`（高级区无登录项/快捷键/动效项） | 见 X15；也没有“命令面板快捷键”说明与“减弱动效”状态 | 增设「通用」区：登录时启动（X15）、全局快捷键说明（`Platform.swift:31-57`）、reduce-motion 只读状态 | 设置完整度 | P2 | M |
| T5 | `SettingsView.swift:286-316`、`:237-259` | 所有输入框无 focus 环，标签与控件未关联 | 见 X01 / X09 | 设置可用性 | P1 | S |

---

## 3. 建议的实施顺序

### 3.0 已落地，不要重复实现（12:33 复核）

- Toast kind + action：`Design/Toast.swift`；命令面板：`Design/CommandPalette.swift`；⌘1…⌘0 与 ⌘⇧Space：`TouchFlowApp.swift:42-45`、`Platform.swift:31-57`；窗口尺寸与上次页签恢复：`Platform.swift:13-27`、`TouchFlowApp.swift:170-173`；首启引导：`Design/Onboarding.swift`；Dock 菜单：`Platform.swift:79-101`；总览“下一步建议”：`DashboardView.swift:21-23`/`:149-175`；规则页搜索/筛选/校验/去重/确认删除/↑↓：`RulesView.swift:86`/`:111`/`:115`/`:152`/`:167`/`:193-215`/`:380-412`；抓包页暂停/状态筛选/搜索/清空确认：`CaptureView.swift:90`/`:110-141`。

### 3.1 Wave 0 —— 点状修复（串行，0.5 天，1 人）

先做，因为都小、跨文件少，但决定“能不能用”：N1 强制解包、P1 假绿灯、X18 scope 竞态、T2 假成功、X13 ⌘, 映射、X14 Info.plist。
出口：`swift build` + `scripts/build-app.sh debug` + 手工验证 `open "touchflow://section/rules"`、⌘,、导入配置全流程。

### 3.2 Wave 1 —— 原语层（先串行 1 天，再 3 路并行）

第一步必须串行（1 人独占 `Design/Theme.swift`、`Design/Interactions.swift`、`Views/Shared.swift`）：X01 焦点环、X02 reduce-motion、X10 对比度、X11 TFSwitch、X09 的 SidebarRow/PageHeader/FieldRow。理由：后续页面改造全部依赖这些原语，先做可避免三轮返工。

第二步三路并行（写范围互斥）：

- **A 组**：`Views/AdBlockView.swift` + `Views/PrivacyView.swift`（A1-A5、P2-P6）。
- **B 组**：`Views/SSHView.swift` + `Views/NASView.swift`（S1-S5、N2-N5）。
- **C 组**：`Views/LearnView.swift` + `Views/ProfilesView.swift` + `Views/SettingsView.swift`（L1-L5、F1-F4、T1-T5）。

`TouchFlowApp.swift` 由 lead 单点写（X04 toast 通路、X12 菜单栏、X19 面板索引、X15 设置项宿主），否则会和 X01 的按钮替换大面积冲突。

### 3.3 Wave 2 —— 键盘与反馈闭环（2 路并行，2 天）

- **键盘**：X08（7 页 ⌘F 接线）+ C1 右键菜单 + R1 批量选择 + D1 CA 分支。
- **反馈**：X03 进度、X05 撤销、X21 重试、C2/C3 导出与全文。

### 3.4 Wave 3 —— 收尾（1 天）

X20 列表节流（engine 批量 flush 需 lead 同意）、X17 模态阻塞、X19 最近使用、X16 引导 CA、T4 登录项；最后按 §4.3 全量键盘走查。

### 3.5 为什么这些必须串行

- Theme/Interactions 是公共依赖：X01 引入 `TFButton` 会改所有按钮调用点，与页面并行必然冲突。
- `scripts/Info.plist` 改动只有重跑 `build-app.sh`（ad-hoc 重签）才生效，入口验证无法与其它改动并行。
- `TouchFlowApp.swift` 已是本轮冲突热点（工作树 M），必须单写者。

---

## 4. 风险与回归点

### 4.1 自动化护栏现状

`Tests/` 无任何 TouchFlowApp 引用（grep `AppModel|Section|audit-ui` 零命中）→ App 层零单测，本轮改动**没有自动化兜底**。可用验证：`swift build --build-tests`、`swift test`、`./scripts/build-app.sh debug`、`./scripts/smoke.sh`、`./scripts/bench.sh`。

### 4.2 逐改动点回归面

| 改动 | 会被牵连的文件/测试 | 回归要点 |
| --- | --- | --- |
| X01 按钮换 TFButton / 加 focus 环 | `Theme.swift` 全部调用点；`SettingsView.swift`、`CaptureView.swift`、`ProfilesView.swift` | Tab 顺序、⇧Tab 反向、Space 触发、按钮 disabled 态仍不可聚焦 |
| X02 reduce-motion | `Theme.swift:262-318`、`DashboardView.swift:113-127`、`Onboarding.swift`、`Interactions.swift:133-162` | 开“减弱动态效果”后无 repeatForever、无位移过渡，静态观感不塌 |
| X10 对比度（textTertiary） | `StatusChip`（`TouchFlowApp.swift:593-617`）、`StatusPill`、`Badge`（`Shared.swift:96-112`）、`StatTile`（`:50-94`） | 9pt 文案在 panel/panelSolid/stroke 三种底色上都 ≥4.5:1 |
| X07 EmptyHint → TFEmptyState | `DashboardView.swift:399-423`、`PrivacyView.swift:162-203`、`ProfilesView.swift:65-112`、`NASView.swift:60-190` | 空态高度（现有 `.frame(height: 120/130)`）不被 CTA 撑破 |
| X05/X06 撤销与确认 | `TouchFlowEngine.swift` 的 `addRules`/`removeRule`/`moveRules`（`:334`/`:347`/`:351`） | 撤销必须回写到 engine 并持久化，不能只改 @State |
| T2 保存即重启 | `TouchFlowEngine.swift:84`/`:319`、`SettingsView.swift:206-231` | 保存失败时端口/规则不被写坏；`TF_AUTOSTART` 启动路径不重复启动 |
| X14 URL scheme | `scripts/Info.plist`、`scripts/build-app.sh:19`、`Platform.swift` | 无窗口（仅菜单栏）时唤起要 `openWindow(id: "main")`；ad-hoc 重签后 Gatekeeper 仍可开 |
| X08 ⌘F 接线 | `TouchFlowApp.swift:39-40`、`TouchFlowApp.swift:306-308` | 每页只消费一次 `searchFocusRequest`；切页后不残留焦点；Rules/Capture 已实现，勿重复加 |
| X20 抓包节流 | `CaptureView.swift:103-105`/`:125-141` | 暂停/继续语义、过滤后选中项清理、导出仍取全量 `engine.captures` |
| C1 右键菜单写规则 | `engine.addRules` + `RulesView` 刷新 | 新规则出现且不破坏当前排序/过滤；重复规则给去重提示 |

### 4.3 手工键盘走查清单（改动后必跑）

1. ⌘1…⌘0 切 10 页；2. ⌘K 输入、↑/↓、↩、Esc；3. ⌘F 在 10 页逐页聚焦且可见焦点；4. 列表 ↑/↓ 选择 + ↩ 执行；5. Delete 删除 + 二次确认 + 撤销；6. Tab 顺序可视化（每一步 focus 环可见）；7. ⇧Tab 反向；8. Space 切开关；9. ⌘, 打开设置；10. `open "touchflow://section/capture"` 外部唤起。开 reduce-motion 再跑一遍第 2、3、6 项。

### 4.4 与并行工作的冲突提示

工作树当前已 M `TouchFlowApp.swift`、`CaptureView.swift`、`DashboardView.swift`、`RulesView.swift`（未提交），且 Rules/Capture 的改造与本清单高度重叠。动手前先 rebase 到最新快照，并把本文 §3.0 当作“已完成清单”核对，避免重复实现或回退别人的改动。
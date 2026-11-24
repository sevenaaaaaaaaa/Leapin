# 任务表 · product-v4

> 依据 `docs/PRODUCT-v4.md`（v4-draft-1，已确认）。
> 一项任务只拥有一个代码改动。两个任务不共享文件。

---

## M1 · 常驻层（PoC）

**目标**：不打开窗口也能完成 S1（看一眼现在走哪条 → 切 → 关窗）。
**用户怎么试**：点菜单栏图标 → 看到「当前配置 / 当前出口 / 速率 / 接管范围」→ 点另一个配置 → 1 秒内生效 → 打开之前打不开的内网地址，通了。

**里程碑 DoD（PRD §4 M1 的逐条落点，2026-11-23 补）**

| PRD M1 DoD | 承接 | 现状 |
| --- | --- | --- |
| 1 图标三态（正常 / 降级 / 异常），真实事件驱动 | T-02 | 未做 |
| 2 面板显示配置 / 出口 / 速率 / 拦截数，与窗口内一致 | T-01 + T-08（M2） | 面板四项齐全；窗口侧由 T-08 重写首屏时承接并截图对照 |
| 3 一键切配置 / 场景，≤1s，失败回滚并给原因 | T-01（面板）+ 引擎既有回滚 | 回滚与原因已有；T-03 修「原因不消失」 |
| 4 浮窗与菜单栏读同一份状态 | T-01 | 完成（ResidentStatusStore.shared） |
| 5 关窗 8 小时 RSS < 20MB | 人工验收 | 未测 |

### T-01 常驻层：一个状态源，三块面板

- **Verdicts**：code: pass (round 2) · security: pass · qa: pass · doc: pass (round 2)
- **Shape**: solo
- **Milestone**: M1

**现状**（已核对）
- `Views/MenuBarPanel.swift`（496 行）有 11 个区块：header / startStop / speedCard / switchCard / toggles / metrics / address / issues / navigation / footer，固定宽 262。
- `Views/FloatingStatusView.swift`（240 行）自己算速率：持有 `lastBytesIn/lastBytesOut/lastSample`，按秒差分 `engine.liveTraffic`。
- 两处都直接读 `app.engine`（`LeapinEngine.shared`），没有共享的聚合对象；`DashboardView` 再读一遍。
- 结果：同一时刻，菜单栏、浮窗、总览可以显示三个不同的速率。

**这个任务做什么**
1. **把常驻状态的计算搬出视图**：新增 `Sources/LeapinRuntime/ResidentStatus.swift`，一个纯计算 + 可观测的聚合对象，输入是引擎状态、`EngineStats`、`LiveTraffic` 快照、最近 flows、接管范围声明，输出是常驻层要显示的那一份数据（图标 tone、标题、副标题、速率、被拦截数、未覆盖声明）。速率差分只在这里做一次。
2. **菜单栏面板收敛为 3 块 + footer**：「现在」（状态 + 当前配置 + 当前出口 + 速率 + 接管范围）/ 「切换」（配置与场景）/「异常」（仅当有错误或降级时出现）。被收掉的内容（节点列表、端口地址、系统代理开关、导航）改为一行入口跳转到窗口对应页面，**功能不丢失，只是不再占据常驻面**。
3. **浮窗改读同一对象**，删掉自己的差分状态，保证与菜单栏逐字节一致。

**这个任务不做**
- 不改 `DashboardView`（属 M2）。
- 不动引擎、控制面、同步。
- 不新增第三方依赖。

**文件所有权**（只准改这些）
- 新增 `Sources/LeapinRuntime/ResidentStatus.swift`
- 新增 `Tests/LeapinRuntimeTests/ResidentStatusTests.swift`
- 修改 `Sources/LeapinApp/Views/MenuBarPanel.swift`
- 修改 `Sources/LeapinApp/Views/FloatingStatusView.swift`
- 修改 `Sources/LeapinApp/Views/MenuBarStatus.swift`（若图标 tone 需要扩展；先确认该文件是否存在）

**2026-11-23 修正（PM，追加不改原文）**
- 上面这一行指向的文件不存在：`MenuBarStatus` 类在 `Sources/LeapinRuntime/MenuBarKit.swift:98`，图标本体在 `Sources/LeapinApp/LeapinApp.swift` 的 `MenuBarLabel`，不属 T-01；图标三态由 T-02 承接。
- DoD 1 的「红→绿」过程证据在交接时未留存（实现先于验收存在）；以 15 条单测 + `qa/T-01/run.sh` 的独立用例为准，基线提交 `13e199b`。

**DoD**（逐条可判）
1. `swift test --filter ResidentStatusTests` 从红到绿；至少覆盖：空闲 / 运行中 / 脚本降级 / 引擎失败 / 有未覆盖声明 五种输入，输出字段与预期一致。
2. 速率差分只在 `ResidentStatus` 内实现一次；`FloatingStatusView` 与 `MenuBarPanel` 内不再出现 `lastBytesIn` / `lastSample` 这类自行计时状态。
3. 菜单栏面板的顶层区块数 ≤ 4（3 块 + footer）；「异常」块在无错误、无降级时**不渲染**（不是渲染成空块）。
4. 被收掉的每一项能力都能从面板一步到达：节点切换、端口地址、系统代理开关、各页导航。
5. 面板宽不超过 280，且在 13 寸屏（1440×900 缩放）下展开不被屏幕边缘裁切。
6. `swift build` 零新增 warning；`swift test` 全绿（含既有用例）。
7. 不修改 `Sources/LeapinApp/Platform.swift`（该文件有他人未提交改动）。
   **2026-11-23 更正（追加，PM）**：M2·T-13 按任务书拥有该文件的 Debug 快照同步，文件因此出现 +18/−10 的正常改动；`qa/T-01` 的 C7 原先用「整文件 diff = +1/0」当代理，从此不可能通过。判据改为机制无关的两条：那行 `host.appearance = NSAppearance(named: .aqua)` 仍在且恰好 1 处、文件里没有任何 T-01 的符号。意图不变：T-01 没有改这个文件。

**不可自动化的一项**：关窗连续运行 8 小时 RSS 增长 < 20MB。放在里程碑验收里人工确认，本任务只需保证新增对象不持有定时器（用引擎已有的刷新驱动）。

---

### T-02 常驻层：菜单栏图标三态

- **Verdicts**：code: pass (round 3) — R2-1 修复经 PM build/test 与 QA C4 复核，未再开第 4 轮（轮次上限） · security: pass · qa: pass · doc: pass (round 2)
- **Shape**: solo
- **Milestone**: M1

**现状**（已核对）
- `Sources/LeapinApp/LeapinApp.swift:1045-1058` 的 `MenuBarLabel` 只有 `running ? shield.lefthalf.filled : shield.slash` 两态；它读 `MenuBarStatus` 的延迟徽标，不看 tone。
- T-01 已算出 `ResidentTone`（idle / normal / degraded / failed）并驱动面板圆点，但图标没接。
- 平台约束：macOS 状态栏按模板渲染，颜色会被系统抹掉。所以四态用**字形**区分（斜线盾 / 空盾 / 感叹号盾 / 叉盾），颜色只留在面板圆点。PRD 里「墨/半红/红」的措辞已按 `docs/PRODUCT-v4.md` 的 Corrections 更正；用户在评审时可以推翻（代价：换 AppKit 状态栏）。

**这个任务做什么**
1. 新增 `Sources/LeapinRuntime/ResidentIcon.swift`：`ResidentTone.iconName` 纯映射（idle → `shield.slash`；normal → `shield.lefthalf.filled`；degraded → `exclamationmark.shield.fill`；failed → `xmark.shield.fill`）与 `accessibilityText`。放 Runtime 是为了可单测。停着的 App 必须和跑着的长得不一样，否则「关掉了吗」要靠点开面板才知道。
2. `MenuBarLabel` 改读 `ResidentStatusStore.shared.status.tone`，用上面的映射决定字形；延迟徽标只在 `normal` 时显示（降级/失败时不再挂着旧延迟）。
3. tone 只来自真实事件（引擎状态、脚本停用、系统代理未接管），不新增定时器。

**这个任务不做**
- 不做彩色 NSImage 状态栏图标（模板渲染限制，见现状第三条）。
- 不改 `ResidentStatus.make` 的判定逻辑，不改面板与浮窗。

**文件所有权**（只准改这些）
- 新增 `Sources/LeapinRuntime/ResidentIcon.swift`
- 新增 `Tests/LeapinRuntimeTests/ResidentIconTests.swift`
- 修改 `Sources/LeapinApp/LeapinApp.swift`（仅 `MenuBarLabel` 与它唯一的调用点）

**DoD**
1. `swift test --filter ResidentIconTests` 从红到绿：四个 tone 各一条字形断言 + 一条无障碍文案断言。
2. `MenuBarLabel` 不再用 `running` 决定字形（`grep` 可见它读 `ResidentStatusStore`）。
3. degraded / failed 时字形与 normal 不同；延迟徽标只在 normal 出现。
4. `swift build` 在本任务文件上零新增 warning；`swift test` 全绿。

**不可自动化的一项**：真实宕机时状态栏字形的肉眼确认（需真机跑一次引擎失败）。

---

### T-03 引擎：系统代理切换成功后清除上一条错误

- **Verdicts**：code: pass (round 2) — B-1 的单行改动由安全评审复核 · security: changes needed — B-2（标志未回读）由 T-04 承接 · qa: pass · doc: pass (round 2)
- **Shape**: solo
- **Milestone**: M1
- **类型**：bug（由 T-01 代码评审发现）

**报告**（2026-11-23，rev-1，T-01 评审）
- 复现：代理运行中，系统代理开启失败一次（如 `networksetup` 报错）→ `lastError` 被写入；随后再次切换成功，`systemProxyActive = true`，但 `lastError` 仍是上一条错误。
- 现象：常驻层把 `lastError` 当作「当前异常」渲染（`ResidentStatus.make`），于是面板与浮窗长期停在「降级（半红）」，直到下一次 start / activate 才清。
- 期望：成功的 `toggleSystemProxy` 清掉旧错误，异常块随事实消失。

**这个任务做什么**
1. `Sources/LeapinRuntime/TouchFlowEngine.swift` 的 `toggleSystemProxy`：进入 `do` 前清 `lastError`；成功分支不再保留旧错误，失败照旧写入。
2. 不改 `ResidentStatus` 与视图。

**文件所有权**（只准改这些）
- 修改 `Sources/LeapinRuntime/TouchFlowEngine.swift`（仅 `toggleSystemProxy`）
- 测试文件按 DoD 2 的结果决定是否新增：留了接缝才建 `Tests/LeapinRuntimeTests/SystemProxyErrorTests.swift`

**DoD**
1. `toggleSystemProxy` 在进入 `do` 之前清空 `lastError`；成功路径不再保留旧错误，失败路径照旧写入。静态检查能判（`grep` 该方法体内 `lastError` 的赋值次序）。
   **2026-11-23 更正（追加）**：安全评审 B-1 指出「入口清」会连带清掉 `saveProfile` / 回滚等写在同一槽里的错误，实现改为**只在成功分支清**（`applySystemProxySuccess` 内），入口不清。意图不变：成功一次就清掉上一条失败；失败仍照旧写入。`qa/T-03/run.sh` 的 C3 随之改为断言「成功分支调用 `applySystemProxySuccess`、入口无清错」，与本次更正同批更新。
   **2026-11-23 再更正（T-04 落地后）**：成功路径改为「命令成功 → `refreshSystemProxyStatus()` 回读 → `lastError = systemProxyReadbackMessage(...)`」，`applySystemProxySuccess` 只剩测试接缝。C3 再改为**机制无关**的判法：成功分支（`do` 之后、`catch` 之前）必须有一处把 `lastError` 清掉的动作，不钉具体函数名。真实接线仍只有静态检查；这是已知限制，记在 `qa/T-03/report.md`。
2. 单元测试：`SystemProxy` 是静态真实命令，测试不许执行 `networksetup`。若能在不扭曲设计的前提下留出接缝（例如成功分支调用一个 internal 方法），写测试断言它清错；做不到就在报告里说明并跳过——不许为了可测性把 `SystemProxy` 改成注入式。
3. `swift build` 零新增 warning；`swift test` 全绿。
4. 人工：制造一次失败、再成功一次，面板「异常」块消失。

**不可自动化的一项**：真实 `networksetup` 的失败/成功序列需要人工点一次。

### T-04 引擎：系统代理标志按事实回读，不按入参写死

- **Verdicts**：code: pass — 评审无 blocking（9 条 optional 待排期） · security: pass — B-2 已修，回读四条件 · qa: pass — qa/T-04 5/5 · doc: pass
- **Shape**: solo
- **Milestone**: M1
- **类型**：bug（由 M1 安全评审发现，B-2）

**报告**（2026-11-23，sec-1）
- `toggleSystemProxy` 在 `enableSystemProxy()` / `SystemProxy.disableAsync()` 成功后，直接把 `systemProxyActive` 写成入参值。
- `SystemProxy.statusAsync(service:)` 返回的是「该服务第一个已启用的代理」，不比对 host/port 是不是我们。机器上原有企业代理、或 `networksetup` 退出 0 但未生效时，标志会变 true；常驻层据此显示「接管范围：系统代理 · …」，面板、图标一起宣称已接管，实际直连。
- 引擎里已有更严格的 `refreshSystemProxyStatus()`（核对 `state == .running`、host ∈ {127.0.0.1, localhost}、port == 我们的监听端口），但从不调用。

**这个任务做什么**
1. `toggleSystemProxy` 成功分支改为先 `await refreshSystemProxyStatus()`，标志跟着回读结果走；「命令成功」仍清 `lastError`。
2. 测试：`refreshSystemProxyStatus` 依赖真实 `SystemProxy.statusAsync`，单测不跑它。把「回读的状态 → 标志」抽成纯函数（例如 `SystemProxyVerdict.flag(running:host:port:expectedPort:)`）单测，覆盖：未运行、别的代理、我们的代理、关闭。
3. 不改 `SystemProxy` 的实现。

**文件所有权**（只准改这些）
- 修改 `Sources/LeapinRuntime/TouchFlowEngine.swift`（`toggleSystemProxy` 与回读相关的纯函数）
- 新增 `Tests/LeapinRuntimeTests/SystemProxyFlagTests.swift`

**DoD**
1. 纯函数单测四种输入下标志正确，红→绿。
2. `toggleSystemProxy` 不再直接用入参写 `systemProxyActive`（`grep` 可判）。
3. `swift build` 零新增 warning；`swift test` 全绿。
4. 人工：机器上先设一个别的 HTTP 代理，再点「接管 开」，面板应显示「未接管」，而不是谎报。

**不可自动化的一项**：真实 `networksetup` 与既有代理的冲突，需要人工一次。

---

## M2 · 工作层四动词

**目标**：19 个接触面收成 11 行侧栏（4 动词 + 工具 5 + 收纳 2），四个动词共享上下文；「为什么」里就地生成规则并原地重测。
**设计**：`docs/design/hld-2026-11-23-product-v4-m2.md`（m2-hld-2，已按两份评审修订；第二轮评审见 `.dsh-crew/jobs/product-v4/reviews/`）。

**构建纪律（对本段每个任务生效）**：所有 swift 命令必须带 `--scratch-path /tmp/<task-id>-scratch`；同一时刻只跑一个构建；qa 脚本默认复用同一路径，不删。`git status` 里 M1 的未提交改动视为既存背景，任务评审按文件 + hunk 归属，不按整树。

**里程碑 DoD（PRD §4 M2 的逐条落点）**

| PRD M2 DoD | 承接 | 怎么判 |
| --- | --- | --- |
| 1 侧栏 ≤11 行 | T-06 | qa 静态断言行/组/落点 + 人工 |
| 2 首屏四入口 + 当前状态 | T-08 | 四入口标题与状态行静态断言 + 截图 |
| 3 一键生成规则并原地重测 | T-07 + T-12 | S2 人工走查 + `NetworkAssistantModel.submit` 调用静态断言 |
| 4 怎么判跳为什么带 host | T-10 + T-05 | WorkbenchTests（take 语义）+ 人工 |
| 5 四类共用列表与 apply | T-09 | `applyRewrite` 四处调用、无第二入口 + 人工各建一条 |
| 6 五页能力无丢失 | T-09/T-11/T-12/T-13 | 对照 HLD §4 逐项走查 |
| 7 首屏接管范围一行 | T-08 | `coverage.declaration` 引用 + 截图 |

---

### T-05 工作层纯逻辑：动词 / 上下文 / 侧栏计划 / 规则原子

- **Verdicts**：code: pass — 评审无 blocking（10 条 optional 待排期） · security: skipped — 纯数据与内存状态，不触碰网络、密钥与外部输入 · qa: pass — qa/T-05 5/5 · doc: pass — M2 计划评审第 2 轮
- **Shape**: solo
- **Milestone**: M2

**这个任务做什么**
1. 新增 `Sources/LeapinRuntime/Workbench.swift`：
   - `WorkbenchVerb`（goWhere / howJudged / whatChanged / why，标题与落点按 HLD §3）；
   - `RouteSubject`（host / port / source / at）；
   - `RouteContext`：`focus`、`peek(for:)`、`take(for:)`（每个动词只取一次）、`clear`；
   - `WorkbenchSidebar`（3 组 11 行的纯数据，含落点与 ⌘1..⌘4）；
   - `RuleDraft`（host + policy + source，不写死 DIRECT）。
2. 新增 `Tests/LeapinRuntimeTests/WorkbenchTests.swift`。

**这个任务不做什么**：不 import SwiftUI；不改 App 壳；不定义 View。

**文件所有权**
- 新增 `Sources/LeapinRuntime/Workbench.swift`
- 新增 `Tests/LeapinRuntimeTests/WorkbenchTests.swift`
- 新增 `qa/T-05/run.sh`（跑 WorkbenchTests + 编译）

**DoD**
1. `swift test --filter WorkbenchTests` 红→绿，至少覆盖：四动词顺序/标题/落点；11 行三组；同 subject 两个动词各 take 一次成功、第三次 nil；peek 不消耗；RuleDraft 保留 policy 原值。
2. `RuleDraft` 另带一个纯函数 `makeRuleSetEntry(existing:)`：生成一条 host 精确规则（policy 来自 draft，不写死 DIRECT），置顶、同 host+policy 去重；单测覆盖去重与置顶。
3. `qa/T-05/run.sh` PASS：构建 + WorkbenchTests 计数 + 11 行断言。
4. `swift build` 零新增 warning；全量 `swift test` 全绿。

---

### T-06 App 壳：11 行侧栏 + why / dashboard 落点 + 两个空壳

- **Verdicts**：code: pass — 评审仅 1 条 blocking（⌘0），已按 2026-11-23 更正作废（命令面板保持 ⌘K） · security: skipped — 只改导航与分组 · qa: pass — qa/T-06 6/6 · doc: pass — M2 计划评审第 2 轮
- **Shape**: solo
- **Milestone**: M2

**这个任务做什么**
1. 侧栏改用 `WorkbenchSidebar`：工作 4 + 工具 5 + 收纳 2；工具三件行调 sheet（`showHome` / `showCompany` / `showNetworkTools`），导入行 `app.beginImport()`（不是 `showImporter`）。
2. ⌘1..⌘4 指向四动词；「前往」菜单同步 11 行；命令面板保持现有 ⌘K（不另占 ⌘0——一个菜单项只能挂一个快捷键，2026-11-23 更正）。
3. 新增 `WhyPage.swift` 空壳（连接 tab = `CaptureView`，另外三 tab 占位）与 `GoWherePage.swift` 空壳（总览 tab = 现 DashboardView，配置 tab = `ProfilesView`）。
4. `sectionContent`：`.dashboard` → `GoWherePage()`，`.capture` 与新增 `.why` → `WhyPage()`；`Section` 增加 `why`（`.capture` 保留 alias）。
5. `AppModel` 增加 `let routes = RouteContext()` 并 `environmentObject` 下发。

**这个任务不做什么**：不删任何 Section case（Privacy 除外由 T-13）；不改业务视图；不动 Platform.swift。

**文件所有权**
- 修改 `Sources/LeapinApp/LeapinApp.swift`
- 新增 `Sources/LeapinApp/Views/WhyPage.swift`
- 新增 `Sources/LeapinApp/Views/GoWherePage.swift`
- 修改 `Sources/LeapinApp/Design/CommandPalette.swift`（只把「前往」条目过滤到 11 行）
- 新增 `qa/T-06/run.sh`

**DoD**
1. `qa/T-06/run.sh` 静态断言：侧栏 11 行 / 3 组 / 四动词标题与落点 / ⌘1..⌘4 / 导入行调用 `beginImport`。
2. 人工：11 行都可点，无死行；导入行打开导入中心而不是系统文件框。
3. `swift build` exit 0；全量 `swift test` 全绿。
4. 不改业务视图（只新增两个壳）。

---

### T-07 「为什么」页壳：四 tab + 连接搜索注入

- **Verdicts**：code: pass — 第 1 轮 blocking（切 tab 重挂载会二次 seed、顶掉用户搜索词）已修：四 tab 保活 + seed 只写首帧，qa C9 复核 · security: skipped — 只做容器与查询注入 · qa: pass — qa/T-07 9/9 · doc: pass — M2 计划评审第 2 轮
- **Shape**: solo
- **Milestone**: M2
- **依赖**：T-06 之后（shares `WhyPage.swift` with T-06, must be serial）

**这个任务做什么**
1. `WhyPage` 四 tab：连接 / 指标 / 探测 / 诊断，默认连接。
2. `CaptureView` 增加一个搜索注入点（`initialSearch` 或 `@Binding`），只影响初始过滤词，不改过滤逻辑。
3. `onAppear` 用 `routes.take(for: .why)` 把 host 填入搜索框；没取到就不动。

**这个任务不做什么**：不实现指标/探测/诊断 tab（T-11/T-12）；不改抓包存储与列表。

**文件所有权**
- 修改 `Sources/LeapinApp/Views/WhyPage.swift`
- 修改 `Sources/LeapinApp/Views/CaptureView.swift`（仅搜索注入）
- 新增 `qa/T-07/run.sh`

**DoD**
1. 四 tab 可切换，默认连接。
2. 单测（若注入逻辑抽成纯函数）或 qa 静态断言：`take(for: .why)` 只取一次。
3. 人工：从别页 focus 后打开为什么，搜索框出现该 host；再切走切回不重复触发。
4. `swift build` 零新增 warning；全量 `swift test` 全绿。

---

### T-08 「走哪」：总览重写 + 配置与订阅 tab

- **Verdicts**：code: pass — 第 1 轮 blocking（面板/浮窗都没开时五事实是死值）已修：首屏 `.task` 先取快照再用 1 Hz 驱动共享 store，qa C6 复核；评审 optional 里被删的两个快捷动作已恢复 · security: skipped — 只读引擎状态 · qa: pass — qa/T-08 7/7 · doc: pass — M2 计划评审第 2 轮
- **Shape**: solo
- **Milestone**: M2
- **依赖**：T-06 之后（shares `GoWherePage.swift` with T-06, must be serial）

**这个任务做什么**
1. `GoWherePage` 两个 tab：总览（重写 `DashboardView`）/ 配置与订阅（复用 `ProfilesView`）。
2. 总览首屏：配置 / 出口 / 速率 / 拦截 / 接管范围一行（读 `ResidentStatusStore`，与菜单栏同一格式化函数）+ 四个动词入口（各带当前状态一句话）。
3. 保留现有场景条与快捷操作；删掉与首屏重复的统计块。
4. `ProfilesView` 只加一个「作为 tab 时不显示页面大标题」的参数，不改业务。

**文件所有权**
- 修改 `Sources/LeapinApp/Views/GoWherePage.swift`
- 修改 `Sources/LeapinApp/Views/DashboardView.swift`
- 修改 `Sources/LeapinApp/Views/ProfilesView.swift`（仅页头参数）
- 新增 `qa/T-08/run.sh`

**DoD**
1. 首屏五个事实与四个入口都在；数字来自 `ResidentStatusStore`，并与菜单栏共用 `ResidentStatus` 的格式化输出（单测比较 `rates.summary` / `coverage.declaration` 两处调用结果）。
2. 人工截图：面板与首屏四项数字逐字相同（补上 M1 DoD 2 的窗口一致性）。
3. `qa/T-08/run.sh` PASS：五事实、四入口、`coverage.declaration` 引用、无新增轮询（`grep Timer` 0）。
   **2026-11-23 更正（追加，PM）**：`grep Timer` 的原意是「视图里不自建定时器、不出现第二个速率差分器」，不是「页面存活期不得有任何 1 Hz 采样」。第 1 轮评审的 blocking 恰恰要求首屏在面板/浮窗都没开时自己喂 store，而 SwiftUI 侧不建 Timer 的等价物只有 `.task` + `Task.sleep`；原文按字面读会与 C6 互相矛盾（T-14 评审 O5）。判据定为：三个视图文件与 store 内 `Timer` 0 处、全仓只有一个 `ResidentRateMeter`、采样由页内 `.task` 驱动且离开页面即取消。`qa/T-08` C6 已按此判。
4. `swift build` 零新增 warning；全量 `swift test` 全绿。

---

### T-09 「改成什么」：四 tab + 共用 apply

- **Verdicts**：code: pass — 评审无 blocking；optional 里脚本行 id 会撞（同名脚本只切第一个开关）已修，其余 4 条待排期（记在 docs/STATUS-M2.md） · security: skipped — 复用既有重写/过滤引擎 · qa: pass — qa/T-09 7/7 · doc: pass — M2 计划评审第 2 轮
- **Shape**: solo
- **Milestone**: M2

**这个任务做什么**
1. 新增 `Sources/LeapinApp/Views/RewriteDeck.swift`：四类（重写 / Mock / 脚本 / 去广告）共用的列表模型与 `applyRewrite(_:)` 单一入口。
2. `RewriteView` 改四 tab；去广告内容复用 `AdBlockView` 的列表数据（允许把列表抽到 Deck，视图只渲染）。
3. 脚本 tab 先列 `profile.scripts`（只读 + 启用/停用），不做脚本编辑器（PRD 明确后补）。

**文件所有权**
- 新增 `Sources/LeapinApp/Views/RewriteDeck.swift`
- 修改 `Sources/LeapinApp/Views/RewriteView.swift`
- 修改 `Sources/LeapinApp/Views/AdBlockView.swift`
- 新增 `qa/T-09/run.sh`

**DoD**
1. `grep -c 'applyRewrite(' RewriteView.swift RewriteDeck.swift` 合计 = 4（四 tab 各调用一次；定义在 Deck、调用在 View 都算），且不存在第二个 apply/save 函数名（模式写死在 qa 脚本里）。
2. 四 tab 可切换；脚本 tab 能列出 `profile.scripts` 并启停。
3. 人工：四类各建一条，确认走同一条生效路径（toast/失败原因一致）。
4. `swift build` 零新增 warning；全量 `swift test` 全绿。

---

### T-10 「怎么判」：策略组 + 学习建议 + 带 host 跳转

- **Verdicts**：code: pass — 评审无 blocking；optional 修了两条：「规则 value 改了但条数没变时诊断不刷新」与负载均衡组大小写不归一，其余 3 条待排期（记在 docs/STATUS-M2.md） · security: skipped — 只改规则页展示与跳转 · qa: pass — qa/T-10 7/7 · doc: pass — M2 计划评审第 2 轮
- **Shape**: solo
- **Milestone**: M2

**这个任务做什么**
1. `RulesView` 顶部两区：规则 / 策略组（Mihomo 与原生都能显示分组与选中）。
2. 规则行加「看它为什么没命中」：`routes.focus(RouteSubject(host:..., source: .rule))` + `go(to: .why)`。
3. 底部「学习建议」入口跳 `LearnView`。
4. 补 PRD §2.2 的「永不命中 / 被遮蔽」标记（静态分析现有规则集，不做求值器重写）。

**这个任务不做什么**：不改规则求值引擎；不新建 App 层测试 target。

**文件所有权**
- 修改 `Sources/LeapinApp/Views/RulesView.swift`
- 新增 `qa/T-10/run.sh`

**DoD**
1. `qa/T-10/run.sh` 静态断言：`routes.focus` 调用、`go(to: .why)`、学习入口、永不命中/被遮蔽标记存在。
2. 人工：点规则行的「为什么」，为什么页拿到同一 host。
3. `swift build` 零新增 warning；全量 `swift test` 全绿。

---

### T-11 「为什么」·指标 tab

- **Verdicts**：code: pass — 独立评审 m2-reviewer 无 blocking（见 STATUS-M2 §评审） · security: skipped — 只嵌入既有观测视图 · qa: pass — qa/T-11 8/8 · doc: pass — 任务行经 M2 计划评审第 2 轮
- **Shape**: solo
- **Milestone**: M2
- **依赖**：T-07 之后（shares `WhyPage.swift` with T-07, must be serial）

**这个任务做什么**
1. 指标 tab 嵌入 `ObservationView`；加一个 `embedded` 参数去掉页面级标题。
2. 不改它的采样逻辑（第三处速率采样留到 M2 后统一）。

**文件所有权**
- 修改 `Sources/LeapinApp/Views/WhyPage.swift`
- 修改 `Sources/LeapinApp/Views/ObservationView.swift`
- 新增 `qa/T-11/run.sh`

**DoD**
1. 指标 tab 显示实时速率 / 连接数 / 命中统计。
2. 页内不再出现第二个大标题（静态断言 `embedded`）。
3. `swift build` 零新增 warning；全量 `swift test` 全绿。

---

### T-12 「为什么」·诊断 tab + 原地重测

- **Verdicts**：code: pass — 独立评审 m2-reviewer 无 blocking（见 STATUS-M2 §评审） · security: skipped — 复用既有诊断工作区 · qa: pass — qa/T-12 7/7（含全量 test） · doc: pass — 任务行经 M2 计划评审第 2 轮
- **Shape**: solo
- **Milestone**: M2
- **依赖**：T-11 之后（shares `WhyPage.swift` with T-11, must be serial）

**这个任务做什么**
1. 诊断 tab 嵌入 `DiagnosticsWorkspace`（命中链 / DNS trace / 直连与代理耗时 / 报告）。
2. 连接 tab 的「改成走公司」在本页弹出 `RuleDraft` 编辑器，保存后调用新增的 `NetworkAssistantModel.submit(host:policy:)` 原地重测，不跳页。
3. `DiagnosticReportView` 只作为工作区内部的结果卡，不独立成页。

**文件所有权**
- 修改 `Sources/LeapinApp/Views/WhyPage.swift`
- 修改 `Sources/LeapinApp/Design/NetworkAssistant.swift`
- 修改 `Sources/LeapinRuntime/NetworkTask.swift`（`NetworkRuleChange` 的 policy 参数化，不再写死 DIRECT）
- 修改 `Sources/LeapinApp/Views/DiagnosticReportView.swift`（仅让结果卡接受工作区传参）
- 新增 `qa/T-12/run.sh`

**DoD**
1. 诊断 tab 能生成/导出报告；命中链与耗时可见。
2. `NetworkAssistantModel` 新增 `submit(host:policy:)`：解析 host → 生成 `RuleDraft` → 应用 `makeRuleSetEntry` → 调 `diagnose(target)` 原地重测；`NetworkRuleChange` 的 policy 从入参来。
3. S2 原地链路：连接行 → 生成规则（policy 取自用户选择）→ 原地重测 → 结果留在本页（qa 断言 `submit(host:` 与 `policy:` 调用链，人工走查）。
4. `swift build` 零新增 warning；全量 `swift test` 全绿。

---

### T-13 收尾：Privacy 迁移 + 删除不可达页 + Platform debug 同步

- **Verdicts**：code: pass — 独立评审 m2-reviewer 无 blocking（见 STATUS-M2 §评审） · security: pass — 隐私事实迁移逐项核对，无新增外发/凭据读写（qa/T-13 C3–C5） · qa: pass — qa/T-13 7/7（含全量 test） · doc: pass — 任务行经 M2 计划评审第 2 轮
- **Shape**: solo
- **Milestone**: M2
- **依赖**：T-06 / T-09 / T-10 / T-11 / T-12 之后（shares `LeapinApp.swift` with T-06, must be serial）

**这个任务做什么**
1. Privacy 事实逐项迁移：评分 → 删除；追踪器列表 → 去广告列表；DNS / 日志 / 钥匙串 → 设置「隐私与数据」；出站建议 → 为什么·诊断；系统代理事实 → 走哪首屏。
2. 删除 `PrivacyView.swift`；`Section` 与 `sectionContent` 删除 `privacy`；`Platform.swift` 的 Debug 快照 switch 同步（不动 `:137` 那行他人改动）。
3. **旧页收口（评审 T-06 第 6 条）**：`sectionContent` 里给退役页加 alias——`.profiles` → `GoWherePage(initialTab: .profiles)`、`.adblock` → `RewriteView(initialTab: .adblock)`、`.activity` → `WhyPage(initialTab: .metrics)`、`.diagnostics` → `WhyPage(initialTab: .diagnostics)`、`.learn` → 打开「怎么判」的学习入口（或保留独立页并在侧栏不列）；`SettingsView` 的「启动时打开」只列 11 行，快捷键说明改成 ⌘1–⌘4 + ⌘K；`PageHeaderBar` 的标题用动词名（dashboard → 走哪、capture/why → 为什么）；`Platform.swift` 的快照名映射到新壳（含 why）。判法：每个旧 rawValue 只落到一个视图（grep 可判）。
3. 在 HLD §4 表标注每项「已迁移 / 已删除（原因）」。

**文件所有权**
- 修改 `Sources/LeapinApp/LeapinApp.swift`
- 修改 `Sources/LeapinApp/Platform.swift`
- 修改 `Sources/LeapinApp/Views/SettingsView.swift`
- 删除 `Sources/LeapinApp/Views/PrivacyView.swift`
- 新增 `qa/T-13/run.sh`（迁移表状态由 PM 在评审后更新，工程师不改判据文档）

**DoD**
1. 设置页能找到 Privacy 的每一项事实（逐项对照）。
2. `privacy` 在侧栏、命令面板、Section 枚举、Platform debug 中都不再出现（grep 0）。
3. `swift build` exit 0；全量 `swift test` 全绿。
4. 迁移表每项标「已迁移 / 已删除（原因）」。

---

### T-14 S2 走查与 M2 汇总验收

- **Verdicts**：code: pass — 独立评审 m2-reviewer 复核账本模式不漏跑；B4 修后 T-12 的链路断言可红 · security: skipped — 只做验收脚本 · qa: pass — qa/T-14 6/6；两种模式都实测（run-all 账本 / 单独逐个调用 T-05..T-13） · doc: pass — 计时模板与任务行经 PM 核对
- **Shape**: solo
- **Milestone**: M2

**这个任务做什么**
1. `qa/T-14/run.sh`：汇总 T-05..T-13 的脚本（逐个调用）、断言侧栏 11 行、四个动词、Privacy 不可达、五个并入页无独立侧栏入口。
2. `qa/T-14/report.md`：S2 人工走查清单与计时模板（为什么 → 输入 host → 命中链 → 改成走公司 → 原地重测 → 通）。

**文件所有权**
- 新增 `qa/T-14/run.sh`、`qa/T-14/report.md`

**DoD**
1. 脚本可重复执行，4+ 个任务全绿。
2. S2 按 PRD 的 90 秒目标记录真实耗时（人工，不伪造）。

---

## M2.5 · v5 构图落地（新增 2026-11-23，CRD 0001）

**目标**：把 `docs/design/DESIGN-v5.md` 的 W1–W3 落成可用界面。W1 先做，做完停下来评审。
**用户怎么试**：打开窗口，5 个页面每屏只看到一个焦点带；正文不再是 9–10pt；侧栏选中行不再像报错。

**为什么进计划**：M2 交的是「四动词的功能」，不是「v5 的构图」。复盘 §1 的十条一条没消——字阶、材质、轴线还是旧的。用户 2026-11-23 裁定新建 M2.5。

**里程碑 DoD（对应 DESIGN-v5.md §12）**

| §12 | 承接 | 怎么验 |
| --- | --- | --- |
| 1 一屏 ≤1 焦点带 / ≤1 主按钮 / ≤5 个一级模块 | T-15 | `qa/T-15` 静态计数 |
| 2 最小字号 11、正文 13、mono 只给数字 | T-15 | `qa/T-15` 字号扫描 |
| 3 对比度 AA / 焦点环可见 / 目标 ≥24pt | T-15 + 人工 | 人工走查 |
| 4 3 秒测试 5 人里 ≥4 人 | 人工 | T-15 之后实测，脚本不替代 |
| 5 轴线 ≤2、无居中悬浮 tab | T-15 | `qa/T-15` |
| 6 每页只用 PageHeader / FocusBand / Module / Row 四件 | T-16…T-19 | W2 |
| 7 同一「路」在五处出现 | T-20 | W3 |

W2/W3 的任务行等 W1 评审通过后再写。现在只有 T-15。

---

### T-15 W1 基础：v5 token、字阶、页头、侧栏选中态

- **Verdicts**：code: not run — 本会话没有独立代码评审角色，等 W1 评审 · security: skipped — 只动字号、材质、选中态，无网络与权限改动 · qa: pass — qa/T-15 8/8（脚本层；六条人工项见 qa/T-15/report.md） · doc: pass — 任务行与核对清单经 PM 于 2026-11-24 核对
- **Shape**: solo
- **Milestone**: M2.5

**这个任务做什么**
1. **表面与字阶**：`Theme.swift` 收敛成 v5 的四种表面（paper / sheet / ink / line），删掉 `cardTint` 与内容区玻璃用法；字阶常量按 §6.2 定死——页面标题 28 semibold、区块 15 semibold、正文 13、标签 11 mono、数字 20 mono、一句人话 15 serif italic。全仓字号 <11 的（8 / 8.5 / 9 / 9.5 / 10）一律提到 11 以上；12 提到 13。
2. **间距与圆角**：4 / 8 / 12 / 16 / 24 / 32 / 48 七档；圆角面板 12、控件 8、状态胶囊 full。不再 6 / 10 / 16 / 20 混用。
3. **页头组件**：新增 `Design/PageHeader.swift`，标题 + 一句状态（左）｜1 主 + 2 次（右），左对齐，不带居中悬浮 tab；5 个工作页换用它。
4. **侧栏选中态**：ink 6% 底 + 2px 朱红左条 + 文字 primary，去掉 `accentSoft` 浅朱红底（现在读作 warning）。
5. **模块预算**：每个工作页一级模块 ≤5、填充主按钮 ≤1；超出的收进「更多」或详情。

**这个任务不做**
- 不动任何功能行为、不改 DoD 里的数据与交互断言。
- 不做 W2 的四页重排与 RouteLine 组件（T-16…T-19）。
- 不做 W3 的菜单栏/浮窗重做、空态、图标、动效（T-20）。

**文件所有权**
- 修改 `Sources/LeapinApp/Design/Theme.swift`
- 新增 `Sources/LeapinApp/Design/PageHeader.swift`
- 修改 `Sources/LeapinApp/LeapinApp.swift`（侧栏选中态）
- 修改 `Sources/LeapinApp/Views/` 下 MenuBarPanel、FloatingStatusView、DashboardView、ProfilesView、RulesView、RewriteView、AdBlockView、WhyPage、GoWherePage、RewriteDeck、SettingsView、CaptureView、ObservationView、DiagnosticReportView
- 修改 `Sources/LeapinApp/Design/` 下 CommandPalette、NetworkAssistant、FloatingPanel
- 以及 `Views/` 下其余工具页的字号统一：LearnView、NASView、SSHView、NetworkToolsView、ImportCenter、ImportReportSheet、CompanyAccessView、HomeConnectionView、ManagedKernelPanel、Shared、WorkspaceSheets（这些页只改字号，不动结构）
- 新增 `qa/T-15/run.sh`、`qa/T-15/report.md`

**DoD**
1. `Theme` 暴露 paper / sheet / ink / line 四个表面 token 与 §6.2 的字阶常量；全仓文字字号无 <11pt（图标 glyph 白名单列在脚本里，且每条写理由）。
2. 正文统一 13，页面标题 28，区块标题 15，标签 11 mono，数字 20 mono。
3. 内容区不再出现玻璃或 `cardTint`；玻璃只出现在菜单栏面板、浮窗、命令面板、sheet 四处。
4. `PageHeader` 存在并被 5 个工作页使用；页头左对齐，无居中悬浮 tab。
5. 侧栏选中态 = ink 6% 底 + 2px 朱红左条，脚本断言不再出现 `accentSoft` 作选中底。
6. 每个工作页一级模块 ≤5、填充主按钮 ≤1。
7. `swift build --scratch-path /tmp/t15-scratch --disable-sandbox` exit 0 且零 warning；`swift test` 全绿；`qa/T-15/run.sh` 全 PASS。

**2026-11-24 更正（第 4 条）**：原文写「PageHeader 存在并被 5 个工作页使用」，与实现不符——本仓库的页头由壳（`LeapinApp.swift`）统一渲染一次，页面只提供 `headerTitle / headerSubtitle / headerIcon` 元数据，不各自画标题。断言据此改为「壳渲染 ≥1 处 + section 元数据 ≥1 处 + 页面内重复标题 0 处」。含义未变：一屏一个页头，左对齐。

---

### T-16 RouteLine：一条路与焦点带组件

- **Verdicts**：code: not run — 本会话无独立代码评审角色，等 W2 评审 · security: skipped — 纯视图组件，无网络与权限 · qa: pass — qa/T-16 6/6 · doc: pass — 任务行经 PM 于 2026-11-24 核对
- **Shape**: solo
- **Milestone**: M2.5

**这个任务做什么**
1. 新增 `Design/RouteLine.swift`：全产品唯一的装饰几何。三节点（你 → 判据 → 出口），节点三态（普通 / 当前 / 异常），当前节点用朱红并带 4pt 光圈；支持 `.horizontal`（首屏）与 `.vertical`（trace）两轴。
2. 新增 `Design/FocusBand.swift`：ink 焦点带容器，圆角 12、内缩 26/28，槽位固定为「眉标 + 一条路 + 事实行 + 一个主操作」；配 `RouteFact`（11 标签 + 20 mono 数值）。
3. 只建组件，不改任何页面的现有布局——页面改造在 T-17…T-19。

**这个任务不做**
- 不接引擎、不读全局状态（组件只吃传入数据，便于预览与单测）。
- 不动菜单栏与浮窗的「路」缩略（W3 / T-20）。

**文件所有权**
- 新增 `Sources/LeapinApp/Design/RouteLine.swift`
- 新增 `Sources/LeapinApp/Design/FocusBand.swift`
- 新增 `qa/T-16/run.sh`

**DoD**
1. `RouteLine` 支持横向与纵向两轴、节点三态；当前节点用 `LP.accent`，非当前节点不用强调色。
2. `FocusBand` 用 `LP.ink` 底 + `LPRadius.panel`，内缩 26/28，只有一个主操作槽。
3. 两个组件都不引用 `LeapinEngine` / `ResidentStatusStore` / `@EnvironmentObject`。
4. `swift build` exit 0 零新增 warning；`qa/T-16/run.sh` 全 PASS。

---

### T-17 走哪：三段式重排

- **Verdicts**：code: not run — 无独立评审 · security: skipped — 只改摆法 · qa: pass — qa/T-17 7/7（含 chips 的 C7）、qa/T-08 7/7 回归（458 条单测） · doc: pass — 任务行经 PM 于 2026-11-24 核对
- **Shape**: solo
- **Milestone**: M2.5
- **依赖**：T-16 之后（shares nothing；组件须先存在）
- **进度**：2026-11-24 完成。首屏是 4 块——焦点带 / 四动词 / 场景 / 「更多」开关，加页头共 5 个一级模块；书签、随手可用、常用工具、公司与回家、页脚、五个快捷动作都收进 `moreToggle` 后面。
  PM 接手余下三项，同日做完：六个场景卡收成 chips（`sceneChip`，Capsule 底，切换仍走 `app.switchScene`）；删掉焦点带接管后无人调用的 `statusBar` / `factStrip` / `factCell` / `factDivider` 与 `textAction`（约 100 行）；证据区的「最近决策」栏按 **ADR 001** 暂不做——仓库里没有决策历史的数据源，硬做只能编。

**这个任务做什么**
1. 首屏改三段式：页头 / 焦点带（一条路 + 四个事实 + 「切到 X」一个主操作）/ 证据区两栏（最近决策 7 : 场景 5）。
2. 六个场景卡收成 chips，放进证据区右栏；删掉「线路与订阅」残留块与重复计数行。
3. 四事实仍来自 `ResidentStatusStore.shared`，接线不动。

**文件所有权**
- 修改 `Sources/LeapinApp/Views/GoWherePage.swift`
- 修改 `Sources/LeapinApp/Views/DashboardView.swift`
- 新增 `qa/T-17/run.sh`

**DoD**
1. 首屏一级模块 ≤5（页头 / 焦点带 / 证据区两块），焦点带只有一个。
2. 四事实与菜单栏面板同源（沿用 T-08 的快照 + 1 Hz store 纪律，不新增定时器）。
3. 场景 chips 可切换配置或出口，行为与改造前一致。
4. `swift build` exit 0；`qa/T-17/run.sh` 全 PASS；qa/T-08 仍全绿（回归）。

---

### T-18 怎么判 + 改成什么：表为主

- **Verdicts**：code: not run — 无独立评审 · security: skipped — 只改摆法 · qa: pass — qa/T-18 5/5；qa/T-09 7/7（C4 已按 CRD 002 改成行为口径）、qa/T-10 7/7 回归 · doc: pass — 任务行经 PM 于 2026-11-24 更新
- **Shape**: solo
- **Milestone**: M2.5
- **依赖**：T-16 之后
- **进度**：2026-11-24 完成。改写成什么：segmented Picker 换成左对齐 chips（`LPChip`，四类仍读 `RewriteDeck.Kind.allCases`），「新建」主按钮移到过滤条右端、成为全页唯一主按钮，空态动作降为 ghost，编辑器仍是 sheet；工具栏里那个重复的添加按钮已删。怎么判：策略组右栏可折叠（`showsPolicyGroups` + 工具栏开关），收起时规则表占满宽度。

  两处按实情收窄，记在这里而不是留给下一个人猜：① 任务书写的过滤条是「全部 / 策略组 / 规则」，实际保留了原有的策略 chips（全部 / 直连 / 代理 / 拦截）——把策略组搬进主表会改掉 T-10 的「策略组在右栏」契约，那是另一条任务；② 「行 hover 才出动作」不适用：`RuleRow` 只显示、不带动作，动作在行尾菜单与 ⌫ / 空态写入口里（T-10 C7 已判）。

**这个任务做什么**
1. `RulesView`：表为主，页头下方左对齐过滤条（全部 / 策略组 / 规则），策略组右栏可折叠，行 hover 才出动作。
2. `RewriteView`：页头下方左对齐过滤条（重写 / Mock / 脚本 / 去广告）+ 单一「新建」主按钮 + 列表；编辑器仍是 sheet，不跳页。
3. 居中悬浮 tab 全部去掉（§12 第 5 条）。

**文件所有权**
- 修改 `Sources/LeapinApp/Views/RulesView.swift`
- 修改 `Sources/LeapinApp/Views/RewriteView.swift`
- 新增 `qa/T-18/run.sh`

**DoD**
1. 两页都没有居中悬浮的 tab；过滤条在页头下方左对齐。
2. 每页填充主按钮 ≤1。
3. `RewriteView` 的保存/应用入口仍只有一个（沿用 T-09 的 `applyRewrite` 约束）。
4. `swift build` exit 0；`qa/T-18/run.sh` 全 PASS；qa/T-09、qa/T-10 仍全绿。

---

### T-19 为什么：查询条 + 垂直 trace

- **Verdicts**：code: not run — 无独立评审 · security: skipped — 只改摆法 · qa: pass — qa/T-19 5/5；qa/T-07 9/9（C2、C9 改成行为口径）、qa/T-11 8/8、qa/T-12 7/7 回归 · doc: pass — 任务行经 PM 于 2026-11-24 更新
- **Shape**: solo
- **Milestone**: M2.5
- **依赖**：T-16 之后；与 T-17/T-18 不共享文件，可并行
- **进度**：2026-11-24 完成。页头下方加了查询条（`LPSearchField`）+ 竖过来的 `RouteLine`（`axis: .vertical`、`onInk: false`）+ 右侧判定详情：输入 host 就地取 `engine.explain(host:)`，改一个字 trace 就重画，页面里没有 `app.go(to:)`，不跳页。空态是「一句事实 + 三个示例 chip」，整页 0 个主按钮。四个 tab 的 segmented Picker 换成左对齐 chips，`mounted` 挂载表与 opacity 显隐照旧（切 tab 不销毁已挂载页面）。

  一处按实情收窄：任务书说「四个 tab 的既有能力不丢：指标 / 诊断 / 连接 / 规则」，实际这一页的第四个 tab 是「探测」不是「规则」（规则在「怎么判」页）。没有新增第五个 tab，四个既有能力原样保留。

**这个任务做什么**
1. `WhyPage` 改成「查询条 + 垂直 trace + 右侧详情」：trace 用 `RouteLine(.vertical)` 表达命中链。
2. 空态改一句事实 + 示例 chips + 一个动作，去掉空态里的大号橙色按钮（§8）。
3. 四个 tab 的既有能力不丢：指标 / 诊断 / 连接 / 规则。

**文件所有权**
- 修改 `Sources/LeapinApp/Views/WhyPage.swift`
- 新增 `qa/T-19/run.sh`

**DoD**
1. 查询条在页头下方，输入 host 后 trace 原地更新，不跳页。
2. 空态只有一个动作，且不是大号主按钮。
3. 四个 tab 全部可达，指标与诊断的既有断言（qa/T-11、qa/T-12）仍绿。
4. `swift build` exit 0；`qa/T-19/run.sh` 全 PASS。

---

## M3 · iOS 语义（暂缓，2026-11-24 用户决定）

用户 2026-11-24 裁定：**先走 v5 路线（M2.5 的 W1 → W2 → W3），M3 之后再判断要不要做、要不要提前。**

所以 M3 目前没有任务行，也不占排期。它原来的目标不变：手机的首页回答「这台手机上的网络」——自己跑引擎、自己分流，Mac 只是可选配置源。等 W3 评审完，再把 M3 与「继续打磨 v5」放在一起给出对比。

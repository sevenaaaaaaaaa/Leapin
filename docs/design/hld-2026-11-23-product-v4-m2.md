# HLD · M2 工作层四动词

> 版本 m2-hld-2 · 2026-11-23 · 依据 `docs/PRODUCT-v4.md`（v4-draft-1，已确认）§2.2 / §2.3 / §4 M2。
> v2 消化了两份评审：`.dsh-crew/jobs/product-v4/reviews/M2-plan-review.md`（13 条）与 `m2-arch-notes.md`（12 条）。
> 本文写「怎么建」；「要什么」在 PRD，「谁先做」在 `docs/tasks/product-v4.md`。

## 1 目标与非目标

**目标**：工作层从 19 个接触面（13 个 Section + 6 个 sheet）收成 11 行侧栏：4 个动词 + 工具 5 + 收纳 2；四个动词共享同一份上下文；「为什么」里能就地生成规则并原地重测；首屏写清接管范围。

**非目标**：不做 TUN / 特权 helper；不重写抓包、规则求值、重写引擎；不做视觉换皮；不动 iOS（M3）；不删任何仍被 tab 复用的视图内部实现。

## 2 现状事实（核对过，v1 写错的三处已改）

- `AppModel.Section` 13 个 case；主窗口 `sectionContent` 是穷举 switch。
- 侧栏 4 组 13 行；工具三件（回家 / 公司 / 分享）与导入、书签是 **sheet**，不是 Section。
- 现有跨页机制只有 `pendingRewriteLine`（`LeapinApp.swift:122`，抓包 → 重写）；**没有 `pendingRule`**。规则预填要从零建。
- 诊断能力在 `.diagnostics` → `DiagnosticsWorkspace`（`Design/NetworkAssistant.swift:324`）：命中链、DNS trace、直连 GET / 代理 HEAD 耗时（`:68-97`）、报告生成（`:340`）。`DiagnosticReportView` 只是结果卡（需要 `let report`），不能独立成页。
- `NetworkToolsView` 是三页工具：分享本地服务 / HTTPS 调试 / 工具与致谢，不是探测页。
- `Profiles`（652 行）是「配置与订阅」的完整页面，11 行里必须给它入口。
- `Platform.swift:103-150` 的 Debug 快照按名字实例化 13 个视图，删任何页都要同步这里；该文件另有一行他人未提交改动（`:137`），不能碰。
- 导入中心由 `showImportCenter` / `beginImport()` 驱动；`showImporter` 是系统文件选择器。

## 3 目标 IA：11 行

| 组 | 行 | 落点 | 快捷键 |
| --- | --- | --- | --- |
| 工作 | **走哪** | `dashboard` → `GoWherePage`：总览 tab（新首屏）/ 配置与订阅 tab（复用 `ProfilesView`） | ⌘1 |
| 工作 | **怎么判** | `rules`：规则 + 策略组 + 学习建议 | ⌘2 |
| 工作 | **改成什么** | `rewrite`：重写 / Mock / 脚本 / 去广告 四 tab | ⌘3 |
| 工作 | **为什么** | `why`（新增 rawValue；`capture` 作为 alias 保留深链）：连接 / 指标 / 探测 / 诊断 四 tab | ⌘4 |
| 工具 | SSH | `ssh` | — |
| 工具 | NAS | `nas` | — |
| 工具 | 回家 | sheet `showHome` | — |
| 工具 | 公司内网 | sheet `showCompany` | — |
| 工具 | 分享 / HTTPS 调试 | sheet `showNetworkTools`（page 0 / page 1） | — |
| 收纳 | 导入 | `app.beginImport()`（导入中心；书签并入） | — |
| 收纳 | 设置 | `settings`（内核管理并入） | — |

- `Section` 在 M2 期间**不删**（除 Privacy，见 T-14）；侧栏与「前往」菜单只列这 11 行；命令面板按同一计划过滤。
- ⌘1..⌘4 绑四动词；命令面板保持 ⌘K（原计划的 ⌘0 与「一个菜单项一个快捷键」冲突，作废）。

## 4 页面去留与能力迁移（19 → 12）

| 现状 | 去留 | 能力搬到哪 |
| --- | --- | --- |
| Dashboard | 重写 | 走哪 · 总览：配置 / 出口 / 速率 / 拦截 / 接管范围 + 四入口 |
| Profiles | 保留 | 走哪 · 配置与订阅 tab（原视图整体复用） |
| Rules | 保留 + 扩 | 怎么判：规则 / 策略组 / 学习建议 |
| Rewrite | 保留 + 扩 | 改成什么：重写 / Mock / 脚本 / 去广告，共用一套列表与 apply |
| AdBlock | 并入 | 改成什么 · 去广告 tab（视图复用，列表与 apply 收进 RewriteDeck） |
| Capture | 保留 + 扩 | 为什么 · 连接 tab（加搜索注入点） |
| Observation | 并入 | 为什么 · 指标 tab（原视图，去掉页头） |
| DiagnosticsWorkspace | 并入 | 为什么 · 诊断 tab：命中链 / DNS trace / 直连与代理耗时 / 报告生成 |
| DiagnosticReportView | 并入 | 诊断 tab 内部的结果卡（不独立成页） |
| NetworkTools | 保留在工具层 | 分享本地服务 / HTTPS 调试 / 致谢（sheet 三页；不并入动词） |
| ImportCenter | 保留 | 收纳 · 导入（beginImport） |
| 书签 / WorkspaceSheets | 并入 | 导入中心 |
| Learn | 降级 | 怎么判底部「学习建议」入口 |
| Privacy | 删除 | 评分删除；追踪器列表 → 去广告列表；DNS / 日志 / 钥匙串 → 设置「隐私与数据」；出站建议 → 为什么 · 诊断；系统代理事实 → 走哪首屏 |
| SSH / NAS | 保留 | 工具层 |
| 回家 / 公司 / 分享 | 保留 | 工具层（sheet） |
| Settings | 保留 + 扩 | 收纳 · 设置；ManagedKernelPanel → 内核组 |
| MenuBarPanel / FloatingStatus | 不动 | M1 已交付 |

## 5 路由与上下文

```swift
public enum WorkbenchVerb: String, CaseIterable, Sendable { case goWhere, howJudged, whatChanged, why }

public struct RouteSubject: Sendable, Equatable {
    public enum Source: String, Sendable { case capture, rule, dashboard, manual }
    public var host: String
    public var port: Int?
    public var source: Source
    public var at: Date
}

@MainActor public final class RouteContext: ObservableObject {
    @Published public private(set) var subject: RouteSubject?
    public func focus(_ s: RouteSubject)
    public func peek(for verb: WorkbenchVerb) -> RouteSubject?   // 只读
    public func take(for verb: WorkbenchVerb) -> RouteSubject?   // 该动词取一次，之后再取为 nil
    public func clear()
}

public struct RuleDraft: Sendable, Equatable {   // 规则生成原子，不写死 DIRECT
    public var host: String
    public var policy: String
    public var source: RouteSubject.Source
}
```

- **S2（原地）**：为什么页连接行点「改成走公司」→ 页内弹出 `RuleDraft` 编辑器（不跳页）→ 保存后调用**新增的** `NetworkAssistantModel.submit(host:policy:)`（解析 host → `RuleDraft.makeRuleSetEntry` → `diagnose(target)`）原地重测 → 结果回到同一页。`NetworkRuleChange` 的 policy 从入参来，不再写死 DIRECT。
- **跨页**：为什么 → 怎么判（带 host）用 `focus + go`；怎么判消费 `take(for: .howJudged)` 后预填规则编辑器；保存后不跳回，给「去重测」按钮再带 host。
- 同一 subject 可被不同动词各取一次；tab 容器先挂载哪个 tab 都不会吃掉别的动词的上下文。

## 6 任务拆分（权威在 `docs/tasks/product-v4.md`）

| id | 任务 | 文件 | 依赖 |
| --- | --- | --- | --- |
| T-05 | 工作层纯逻辑：动词 / 上下文 / 侧栏计划 / RuleDraft | 新 `Workbench.swift`、新 `WorkbenchTests.swift` | — |
| T-06 | App 壳：11 行侧栏 + why/dashboard 落点 + WhyPage/GoWherePage 空壳 | `LeapinApp.swift`、新 `WhyPage.swift`、新 `GoWherePage.swift` | T-05 |
| T-07 | 为什么页壳：四 tab + CaptureView 搜索注入 | `WhyPage.swift`、`CaptureView.swift` | T-06 |
| T-08 | 走哪：总览重写 + 配置 tab | `GoWherePage.swift`、`DashboardView.swift`、`ProfilesView.swift` | T-06（GoWherePage 串行） |
| T-09 | 改成什么：四 tab + 共用 apply | `RewriteView.swift`、`AdBlockView.swift`、新 `RewriteDeck.swift` | — |
| T-10 | 怎么判：策略组 + 学习 + 带 host 跳转 | `RulesView.swift` | T-05 |
| T-11 | 指标 tab | `WhyPage.swift`、`ObservationView.swift` | T-07 |
| T-12 | 诊断 tab + 原地重测 | `WhyPage.swift`、`Design/NetworkAssistant.swift`、`Runtime/NetworkTask.swift`、`DiagnosticReportView.swift` | T-11 |
| T-13 | 收尾：Privacy 迁移 + 删页 + Platform debug 同步 | `LeapinApp.swift`、`Platform.swift`、`SettingsView.swift`、删 `PrivacyView.swift` | T-06、T-09、T-10、T-11、T-12 |
| T-14 | S2 走查与 M2 汇总验收 | `qa/T-14/run.sh`、`qa/T-14/report.md` | 全部 |

**串行链**：`LeapinApp.swift` T-06 → T-13；`WhyPage.swift` T-06 → T-07 → T-11 → T-12；`GoWherePage.swift` T-06 → T-08。每条并行任务写自己的 `qa/T-xx/run.sh`。

## 7 M2 DoD 映射

| PRD M2 DoD | 任务 | 判法 |
| --- | --- | --- |
| 1 侧栏 ≤11 行 | T-06 | 静态断言行/组/落点 + 人工 |
| 2 首屏四入口 + 状态 | T-08 | 四入口标题与状态行静态断言 + 截图 |
| 3 一键生成规则并原地重测 | T-07/T-12 | S2 人工走查 + NetworkAssistant 调用的静态断言 |
| 4 怎么判跳为什么带 host | T-10 + T-05 | WorkbenchTests（take 语义）+ 人工 |
| 5 四类共用列表与 apply | T-09 | `applyRewrite` 四处调用且无第二入口（grep 模式写死）+ 人工各建一条 |
| 6 五页能力无丢失 | T-09/T-11/T-12/T-13 | 按 §4 表逐项走查；AppBlock/Privacy 逐条 |
| 7 首屏接管范围 | T-08 | `coverage.declaration` 静态引用 + 截图 |

## 8 测试与构建纪律

- 一个任务一个 scratch：`/tmp/<task-id>-scratch`；同一时刻只跑一个 swift 构建（21:03 的 ProxyServer 假红就是共用 scratch 造成的）。
- 纯逻辑（T-05）单测；UI 任务跑自己的 `qa/T-xx/run.sh`（静态断言 + 编译）；S2 人工。
- 每个任务先写失败测试；布局类写不出单测的，在 DoD 写明原因与人工步骤。
- M1 未提交改动留在工作区（用户未要求 commit）；M2 任务不得碰 M1 文件，除任务表显式列出。
- `Platform.swift` 由 T-13 拥有；只更新 Debug 快照的 switch，不动 `:137` 那行他人改动。

## 9 已拍板 / 待用户

**已拍板**：why 新增 rawValue 且 capture 为 alias；工具保留 5 行；S2 原地重测；RouteContext 用 peek/take；规则原子 RuleDraft；Platform debug 块保留并同步；一任务一 scratch。

**已定（2026-11-23，PM）**：① **不提交 baseline**——用户没有授权 git 写操作，`git log` 保持 13e199b；M2 评审按「文件 + hunk 归属」进行；T-06 不得改 `MenuBarLabel` 与 `⌘⇧Y` / `⌘⇧P` 那两行，其余「前往」菜单跟着 11 行走；提交与发版留到交付前由用户点头。② 工具行不加角标（保持 5 行简洁）。

**待用户**：Privacy 的「出站建议」是否真的搬到诊断（目前没有对应视图，T-13 先写「—」并注明）。

*本文由 lead（PM）撰写；v2 待第二轮评审。*

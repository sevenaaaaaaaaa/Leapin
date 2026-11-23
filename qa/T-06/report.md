# T-06 验收报告 · 11 行侧栏 + why / dashboard 落点 + 两个空壳

- 任务行：`docs/tasks/product-v4.md` 的 T-06（M2）
- 脚本：`qa/T-06/run.sh`（bash，`set -uo pipefail`，有 FAIL → exit 1）
- scratch：`${T06_SCRATCH:-/tmp/t06-scratch}`（复用，不清理）
- 日志：`/tmp/t06-qa-logs/`
- 结论：**6 PASS / 0 FAIL，退出码 0**（2026-11-23 22:1x 快照；当时 T-08/T-09/T-10 仍在改树）

## 结果

| 检查 | 结果 | 证据摘要 |
| --- | --- | --- |
| C1 构建 | PASS | exit 0；12 warning，落在本任务四个源文件上 0 个 |
| C2 11 行侧栏 | PASS | 侧栏读 `WorkbenchSidebar.groups`；旧 4 组 13 行表与 `Section.allCases.prefix(10)` 已消失；计划侧 3 组 / 11 行 / 4 个动词落点 |
| C3 ⌘1..⌘4 | PASS | 「前往」菜单从 `WorkbenchSidebar.rows` 生成；四动词按 `row.shortcut` 挂 `keyboardShortcut`；⌘⇧P / ⌘⇧Y / MenuBarLabel / MenuBarExtra 均未动 |
| C4 导入行 | PASS | `.importCenter → beginImport()`；三件工具行各走自己的 sheet；侧栏内 `showImporter` 0 处 |
| C5 两个壳与映射 | PASS | WhyPage 四 tab（连接=`CaptureView(initialSearch:)`）/ GoWherePage 两 tab（配置=`ProfilesView(带参数)`）；`.why`、`.capture` → WhyPage、`.dashboard` → GoWherePage；`routes` 下发 |
| C6 WorkbenchTests | PASS | 24 条全过 |

## 断言更新记录（旧断言被后续任务按预期改掉）

1. **T-07 落地后按预期更新（PM 指定）**：连接 tab 从空壳 `CaptureView()` 变成注入式 `CaptureView(initialSearch: seed)`。C5 改为「`case .connections: CaptureView(` 前缀 + `initialSearch:`」；退回无参空壳仍会 FAIL。
2. **T-08 落地后按预期更新（本次一并处理）**：第一次重跑时 C5 仍是红的，唯一原因是 `配置=ProfilesView()` 命中 0——工作树里 GoWherePage 已按 T-08 的 DoD（「ProfilesView 只加一个作为 tab 时不显示页面大标题的参数」）写成 `ProfilesView(showsPageHeader: false)`。C5 相应改为「`case .profiles: ProfilesView(` 后必须还有参数」，不钉参数名；退回无参空壳仍会 FAIL。
   - 说明：这一条不在 PM 本次点名范围内（PM 只点了 CaptureView），但它是同一条原则（后续任务的已验证变更让旧断言失效），且 T-08 的任务行与文件所有权明确写了这个参数，所以一并改并要求报告。**若 PM 认为 T-08 未落地前不该动，这行可单独回退。**

## 口径与限制

- **C1 的 12 条 warning**：本轮是复用 scratch 的增量构建，只覆盖本轮实际重编的文件；`LeapinApp` 等目标重编，所以看到 12 条——本任务四个源文件上 0 条。
- **本结果是一个快照**：跑的时候 T-08/T-09/T-10 还在改同一棵树（`ProfilesView`/`DashboardView`/`RewriteView`/`RulesView` 均为 modified）。6/6 说明「此刻这套断言与此刻的树一致」，不等于这些文件冻结。
- **C5 的静态性**：断言的是「构造形式」，不是「tab 真的能点」。tab 切换、默认 tab、从别页 focus 后带 host 跳转属人工项。

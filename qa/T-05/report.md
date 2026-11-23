# T-05 验收报告 · 工作层纯逻辑（动词 / 上下文 / 侧栏计划 / 规则原子）

- 任务行：`docs/tasks/product-v4.md` 的 T-05（M2）
- 脚本：`qa/T-05/run.sh`（bash，`set -uo pipefail`，有 FAIL → exit 1）
- scratch：`${T05_SCRATCH:-/tmp/t05-scratch}`（复用，不清理）
- 日志：`/tmp/t05-qa-logs/c1-build.log`、`c2-test.log`、`c5-regression.log`
- 结论：**5 PASS / 0 FAIL，退出码 0**

## 结果

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| C1 构建 | PASS | `swift build --scratch-path /tmp/t05-scratch --disable-sandbox` exit 0，0 error: |
| C2 WorkbenchTests | PASS | `Executed 24 tests, with 0 failures`；逐条 passed 24 |
| C3 纯逻辑四件套 | PASS | 3 组 11 行；shortcut 值 `1234`（4 个 case）；`peek(for:)` / `take(for:)` 各 1 处；`inserting(into:)` / `makeRuleSetEntry(existing:)` 各 1 处 |
| C4 不写死 DIRECT | PASS | 代码行 `"DIRECT"` 0 处；`RuleDraft.rule` 用 `policy: policy` 1 处 |
| C5 回归抽样 | PASS | `--filter 'ResidentStatusTests|ResidentIconTests|SystemProxy'` exit 0：15 + 6 + 7 + 3 = 31 条全过 |

## C5 为什么是抽样（按 PM 授权，报告里说明）

DoD 4 要求「全量 `swift test` 全绿」。本轮按 PM 指示只跑抽样：`ResidentStatusTests`（15）+ `ResidentIconTests`（6）+ `SystemProxyFlagTests`（7）+ `SystemProxyErrorTests`（3）= 31 条，覆盖 T-01/T-02/T-03/T-04 四个已验收任务的用例集，**但这不是全量**。T-05 只新增纯数据文件、不改既有类型，抽样能覆盖「没碰坏邻居」，覆盖不到的是其它 target（LeapinCore/Net/Policy/Control/Sync/Script/Integrations）的既有用例——那些要靠 `qa/run-all.sh` 之外的一次全量跑，本轮没做。

## 检查的边界（写清楚，便于以后维护）

1. **C3 的计数口径**：按 `Group(name:` 与 `Row(title:` 的字面出现数计——3 组 11 行是这么得出来的。若以后把行改成变量展开或换构造名，这条会假红，需要同步改断言（这是静态断言的固有代价）。
2. **C3 的 shortcut**：只从 `public var shortcut: String {` 块里取 `return "N"`，要求四个 case 且值恰为 1/2/3/4。改文案不影响它，改映射会红。
3. **C4 判代码不判注释**：`sed 's://.*$::'` 去掉行注释后统计 `"DIRECT"`；文件里用反引号提到 DIRECT 的解释性文字不算实现。真正要防的是 `policy: "DIRECT"` 这种写死默认值，改了就红。
4. **脚本自带环境闸**：开跑前最多等 60s 让机器上的 `swift-build/swift-test` 静下来（eng-5 当时可能在用 `/tmp/t06-scratch`）。本脚本 scratch 独立，等到上限仍在构建则打印 WARN 继续，不会因此假绿也不会白等。

## 未覆盖项（不伪造）

- DoD 4 的**全量** `swift test` 未跑（只做抽样，见上）。
- DoD 2 的「去重与置顶」由 C2 的 24 条用例覆盖，本脚本只验计数与源码结构，不复述断言内容。
- T-05 的「不 import SwiftUI」未单独断言——它由 `swift build`（LeapinRuntime 不链接 SwiftUI）与文件内容间接保证，没有写成独立检查项。

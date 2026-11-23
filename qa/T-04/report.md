# T-04 验收报告 · 系统代理标志按事实回读

- 任务行：`docs/tasks/product-v4.md` 的 T-04（bug，M1 安全评审 B-2）
- 脚本：`qa/T-04/run.sh`（bash，`set -uo pipefail`，有 FAIL → exit 1）
- scratch：`${T04_SCRATCH:-/tmp/t04-scratch}`（复用，不清理）
- 日志：`/tmp/t04-qa-logs/c1-build.log`、`/tmp/t04-qa-logs/c2-test.log`

## 结果

**5 PASS / 0 FAIL，退出码 0**

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| C1 构建 | PASS | `swift build --scratch-path /tmp/t04-scratch --disable-sandbox` exit 0，0 error: |
| C2 单测 7+3 | PASS | 汇总含 `Executed 10 tests, with 0 failures`；SystemProxyFlagTests 7 条、SystemProxyErrorTests 3 条逐条 passed |
| C3 成功分支回读 | PASS | `do {` 第 2 行 → `refreshSystemProxyStatus()` 第 11 行（在 `} catch` 第 15 行之前）→ `systemProxyReadbackMessage` 1 处；方法体内直接写 `systemProxyActive` 0 处；`systemProxyIsOurs` 四规则齐：`running && enabled && ["127.0.0.1", "localhost"].contains(host) && port == ourPort` |
| C4 测试不跑真实命令 | PASS | 代码行内 `Process( / posix_spawn / popen / SystemProxy.` 0 处；字面命中 1 次（第 5 行注释） |
| C5 T-03 回归 | PASS | T-03 的三条用例仍在且 SystemProxyErrorTests 3/3 全过 |

C2 的分组证据（`/tmp/t04-qa-logs/c2-test.log`）：

```text
Test Suite 'SystemProxyErrorTests' passed ... Executed 3 tests, with 0 failures (0 unexpected)
Test Suite 'SystemProxyFlagTests' passed ... Executed 7 tests, with 0 failures (0 unexpected)
	 Executed 10 tests, with 0 failures (0 unexpected) in 0.048 (0.049) seconds
```

## 口径说明

1. **C1 的 warning**：`/tmp/t04-scratch` 在本轮之前已存在（eng 建过），实际没重编，warning 显示 0 是「没编译」而不是「零 warning」。
2. **C3 判的是接线，不是行为**：静态证明「成功分支先回读、再按回读结果记账」。行为由 C2 里的纯函数用例（flag 四态 + readback 文案）分块覆盖；**「toggle 真的把 lastError 写成 nil」这一步没有单测**，见下。
3. **C4 判「调用」不判「字面」**：第 5 行注释里出现 `SystemProxy.statusAsync()`，代码行 0 处调用。

## 未覆盖项（不伪造）

- T-04 的「不可自动化」项：**真实 `networksetup` 与机器上既有代理的冲突**（先设一个别的 HTTP 代理，再点「接管 开」，面板应显示「未接管」）需要人工一次。
- T-04 的 DoD 4 是人工项，未自动验证。

## 必须上报的跨任务问题（不是 T-04 的缺陷，是 T-03 的断言过时）

T-04 把「成功清错」的位置从 `applySystemProxySuccess`（接缝）挪到了行内 `lastError = Self.systemProxyReadbackMessage(...)`。结果是：

- `applySystemProxySuccess` 在 `Sources/` 里**已经没有任何调用者**（只剩定义与两处测试调用），引擎注释也写了 "Nothing in the engine calls it"。
- 因此 **`qa/T-03/run.sh` 的 C3 现在会 FAIL**（它断言成功分支调用 `applySystemProxySuccess`）。静态复跑该段逻辑的实得：

```text
FAIL C3  清错位置不符：入口 lastError 赋值 0 处（要求 0）、do { 行=2、applySystemProxySuccess 行=无、} catch 行=15、catch 内 lastError 赋值 1 处（要求 ≥1）
```

- 连带：`bash qa/run-all.sh` 现在会在 T-03 处红（T-04 本身全绿）。
- 另有一条更实的问题：`SystemProxyErrorTests.testSuccessClearsTheErrorLeftByAFailedAttempt` 直接调 `engine.applySystemProxySuccess(true)`，**它测的是一个生产路径不再使用的接缝**；真实成功路径（回读 → message nil → lastError nil）只有静态断言（本报告 C3）和两个纯函数用例，没有一条用例串起来证明。

这三条都需要 PM 决定（改 T-03 的 DoD/C3、或把接缝留在生产路径、或补一条串起来的行为测试）。**QA 没有自行改 T-03 的断言。**

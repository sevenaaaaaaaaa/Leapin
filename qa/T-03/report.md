# T-03 验收报告 · 系统代理切换成功后清除上一条错误

- 任务行：`docs/tasks/product-v4.md` 的 T-03（bug，由 T-01 评审发现）
- 脚本：`qa/T-03/run.sh`（bash，`set -uo pipefail`，有 FAIL → exit 1）
- scratch：`${T03_SCRATCH:-/tmp/t03-scratch}`（复用，不清理）
- 日志：`/tmp/t03-qa-logs/c1-build.log`、`/tmp/t03-qa-logs/c2-test.log`

## 结果

**4 PASS / 0 FAIL**（脚本退出码 0，来自 2026-11-23 21:00 的 `bash qa/run-all.sh` 完整跑）

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| C1 构建 | PASS | `swift build --scratch-path /tmp/t03-scratch --disable-sandbox` exit 0，0 error: |
| C2 单测 | PASS | `Executed 3 tests, with 0 failures`，逐条 passed 3 个 |
| C3 清错次序 | PASS | 方法体内 `lastError = nil` 第 4 行、`do {` 第 5 行（先清后 do）；`applySystemProxySuccess(enabled)` 第 11 行，在 `do`（第 5 行）与 `} catch`（第 12 行）之间；helper 自身清错 1 处 |
| C4 测试不跑真实命令 | PASS | `Process( / posix_spawn / popen / SystemProxy.` 均 0 处 |

## 口径说明（这条必须看清，否则会误解成放水）

**C4 判「执行」，不判「字面出现」。** 任务的原话是「SystemProxyErrorTests.swift 里不出现 networksetup（测试不许跑真实系统命令）」。实测：

- 字面出现 **3 次**：第 9 行文档注释、第 38 行注释、**第 52 行 `engine.lastError = "上一次开启失败：networksetup 报错"`（fixture 字符串）**。
- 可执行入口 **0 处**：没有 `Process(`、`posix_spawn`、`popen`、`SystemProxy.` 调用，所以一次真实命令都不会跑。

也就是说：**如果按字面 grep 判，这条会 FAIL（3 次命中）**。我按「不执行真实命令」判 PASS，并把字面次数打进证据行。这不是我改判标准——括号里的目的写的就是「不许跑真实系统命令」。若 PM 要的是字面也不许出现，请改测试文案（把 fixture 里的 `networksetup` 换成「系统命令报错」之类），或明确这条按字面判，我再把 C4 换成严格版。

## 未覆盖项（不伪造）

- T-03 的「不可自动化」项：**真实 `networksetup` 的失败→成功序列**需要人工点一次；脚本刻意不触发它（那会让本机系统代理被改）。
- DoD 4「制造一次失败、再成功一次，面板异常块消失」是人工项，未自动验证。
- C3 只证「静态次序正确」；「清错真的生效」由 C2 的 `testSuccessClearsTheErrorLeftByAFailedAttempt` 断言（`lastError == nil`）。

## 脚本与这次运行的差异

21:00 那一跑之后改了两处：C3 证据行把「L4/L5」改成「方法体内第 4/5 行」（原写法会被读成文件行号），C1 证据行加「复用 scratch」标注。判定逻辑没动，未重跑（按 lead 的暂停指令）；已 `bash -n` 过。

## 2026-11-23 DoD 更正后的 C3（B-1）与重跑

安全评审 B-1 指出「入口清 `lastError`」会连带清掉 `saveProfile` / 回滚写进同一槽的错误，DoD 已追加更正：**只在成功分支 `applySystemProxySuccess` 内清，入口不清**。C3 随之改为三条断言：

1. 入口（`do` 之前）没有对 `lastError` 的赋值（0 处）；
2. 成功分支在 `do` 之后、`} catch` 之前调用 `applySystemProxySuccess`；
3. `catch` 里仍写 `lastError`（失败照旧上报，≥1 处）。

这比原来的「先清后 do」更窄：原来入口清也能过，现在入口清反而会 FAIL——因为那是 B-1 要修掉的行为。

**重跑（2026-11-23，`bash qa/run-all.sh`）**：T-03 `4 PASS / 0 FAIL`，C3 证据行：

```text
PASS C3  toggleSystemProxy 方法体内：入口（do 之前）lastError 赋值 0 处（要求 0，B-1 更正后不在入口清）；do { 在第 2 行，成功分支 applySystemProxySuccess(enabled) 在第 8 行（do 之后、} catch 之前）；} catch 在第 9 行，catch 内 lastError 赋值 1 处（要求 ≥1）；applySystemProxySuccess 自身清错 1 处
```

C2 的 3 条单测仍然全绿（`testSuccessClearsTheErrorLeftByAFailedAttempt` 先让一次失败写入错误，再走成功分支，断言 `lastError == nil`）——**行为层面的「成功一次清掉上一条失败」没有被这次收窄削弱**，只是实现位置换了。

**仍然有效的口径提醒**：C4 判「执行」不判「字面」，`networksetup` 字面 3 次（L9/L38 注释、L52 fixture 字符串）、可执行入口 0。若 PM 要按字面判，这条会 FAIL，需要改 fixture 文案。

**后续注意**：T-04 会继续改 `toggleSystemProxy`（成功分支先 `refreshSystemProxyStatus` 再定标志）。届时「成功分支调用 `applySystemProxySuccess`」这条断言可能需要跟着 T-04 的 DoD 再调；本次不改。

## 2026-11-23 T-04 落地后：C3 失效（等 PM 决定，未自行改）

T-04 把成功清错从 `applySystemProxySuccess`（接缝）挪进行内 `lastError = Self.systemProxyReadbackMessage(...)`，`applySystemProxySuccess` 在 `Sources/` 已无调用者。于是本脚本的 C3 现在 FAIL：

```text
FAIL C3  清错位置不符：入口 lastError 赋值 0 处（要求 0）、do { 行=2、applySystemProxySuccess 行=无、} catch 行=15、catch 内 lastError 赋值 1 处（要求 ≥1）
```

行为本身没坏（成功且回读为 ours 时 message 为 nil，lastError 被清），坏的是断言钉的实现位置。可选修法：
1. T-03 DoD 再追加一条更正，C3 改成「成功分支在 do 之后、catch 之前对 lastError 赋值，且不再依赖 applySystemProxySuccess」；
2. 或把接缝留在生产路径上（与 T-04「命令成功不是事实」相冲突，不推荐）。

另：`testSuccessClearsTheErrorLeftByAFailedAttempt` 现在测的是生产不再调用的接缝，建议补一条「回读为 ours → lastError 清空」的行为用例（需要可注入的回读，属设计决策）。

**当前状态：`bash qa/run-all.sh` 会在 T-03 处红；T-04 全绿。**

## C3 第二次更正：机制无关（2026-11-23，T-04 落地后）

清错位置已经从 `applySystemProxySuccess`（接缝）挪进行内 `lastError = Self.systemProxyReadbackMessage(...)`，按 PM 的第二次 DoD 更正，C3 不再钉函数名，改判三件事：

1. 入口（`do` 之前）没有 `lastError` 赋值（B-1 的边界，保留）；
2. 成功分支（`do` 之后、`} catch` 之前）有一处清错动作，且**不是写死字符串**（写死说明是「记一条错」不是「清错」）；
3. `catch` 里仍写 `lastError`（失败照旧上报）。

现行证据行：

```text
PASS C3  toggleSystemProxy 方法体内：入口（do 之前）lastError 赋值 0 处（要求 0，B-1）；成功分支（do 第 2 行之后、} catch 第 15 行之前）清错动作 1 处、写死字符串 0 处（要求 ≥1 / 0）：lastError = Self.systemProxyReadbackMessage(enabled: enabled,；catch 内 lastError 赋值 1 处（要求 ≥1，失败照旧上报）。不钉具体函数名（二次更正）
```

**这条断言能红吗**（在 /tmp 副本上变异验证，不动仓库）：
- 入口加一行 `lastError = nil` → FAIL（入口 lastError 赋值 1 处，要求 0）；
- 成功分支删掉 `lastError = Self.systemProxyReadbackMessage(...)` → FAIL（清错动作 0 处，要求 ≥1）。

**保留的限制（不伪造）**：静态只能证明「成功分支里有这个动作」，证不了它的返回值确实是 `nil`。**真实成功路径（回读 → message 为 nil → `lastError` 清空）目前没有端到端单测**——`testSuccessClearsTheErrorLeftByAFailedAttempt` 调的是生产已不再使用的接缝 `applySystemProxySuccess`。要补就得让回读可注入，属设计决策，QA 不代做。

**全量重跑**：`bash qa/run-all.sh`（T-01..T-04）→ 4 个任务全部通过，RUNALL_EXIT=0；T-03 `4 PASS / 0 FAIL`。

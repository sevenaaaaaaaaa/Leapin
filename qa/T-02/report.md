# T-02 验收报告 · 菜单栏图标三态

- 任务行：`docs/tasks/product-v4.md` 的 T-02
- 脚本：`qa/T-02/run.sh`（bash，`set -uo pipefail`，有 FAIL → exit 1）
- scratch：`${T02_SCRATCH:-/tmp/t02-scratch}`（复用，不清理）
- 日志：`/tmp/t02-qa-logs/c1-build.log`、`/tmp/t02-qa-logs/c2-test.log`

## 结果

**5 PASS / 0 FAIL**（脚本退出码 0，来自 2026-11-23 21:00 的 `bash qa/run-all.sh` 完整跑）

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| C1 构建 | PASS | `swift build --scratch-path /tmp/t02-scratch --disable-sandbox` exit 0，0 error: |
| C2 单测 | PASS | `Executed 6 tests, with 0 failures`，逐条 passed 6 个 |
| C3 四态四字形 | PASS | `degraded=exclamationmark.shield.fill`、`failed=xmark.shield.fill`、`idle=shield.slash`、`normal=shield.lefthalf.filled`，唯一字形 4 个 |
| C4 单一状态源 + 延迟徽标 | PASS | MenuBarLabel（15 行）读 `ResidentStatusStore` 1 处；块内 `running ?` 0 处；徽标行 `if let badge = status.badge, tone == .normal {` |
| C5 无彩色图标 | PASS | MenuBarLabel 内 NSImage 0 / isTemplate 0；LeapinApp.swift 内 NSImage 0 / isTemplate 0；全仓库 `isTemplate = false` 0 |

## 口径说明（避免误读）

1. **C1 的 warning 计数**：这一跑用的是已存在的 `/tmp/t02-scratch`（eng-1/eng-2 建过），实际只重编了 `LeapinIntegrations`，所以 warning 显示 0 是「没重编」，不是「代码无 warning」。另跑过一次全量构建（`/tmp/t02-warncheck`，61.75s，exit 0）核对：全包 58 条 warning，落在 `ResidentIcon.swift` 0 条、`LeapinApp.swift` 0 条 —— T-02 的文件确实零 warning。
2. **C4 的范围**：`running ?` 的 0 计数只在 `MenuBarLabel` 结构体内成立。`LeapinApp.swift` 其他地方（启动/停止按钮，约 860-911 行）仍有 `running ?`，那些不是图标判断，所以不在 C4 范围里。
3. **C4 的「延迟徽标只在 normal 出现」**：断言的是「读 `status.badge` 的那一行同时带 `tone == .normal` 条件」，或块内有 `guard tone == .normal`。改写实现时如果换了等价写法，需要同步改这条断言。

## 未覆盖项（不伪造）

- T-02 的「不可自动化」项：**真实宕机时状态栏字形的肉眼确认**需要真机跑一次引擎失败，本脚本不覆盖。
- 视觉层面（图标在菜单栏里的实际观感、深色/浅色壁纸下的对比）未自动验证；模板渲染只由「无 NSImage / 无 isTemplate」间接约束。

## 脚本与这次运行的差异

21:00 那一跑之后，脚本只改了一处**证据文案**：C1 的 PASS 行加了「复用 scratch」标注，防止把 0 warning 读成「零 warning」。判定逻辑与阈值没动，未重跑（按 lead 的暂停指令）。

## 2026-11-23 更正后的断言（现行）与重跑

R2-1 改了接线：MenuBarLabel 不再 `@ObservedObject` 整个引擎（每个 `@Published` 都会重绘状态栏），改成 `let engine = LeapinEngine.shared` + 三条 `onReceive`。C4 因此补两条静态检查：

- **必须**出现 `onReceive(engine.$state`（窗口全关时图标只能靠自己的事件订阅更新）；
- **不得**出现 `Timer`（不许定时器兜底）。

这两条和原有的三条（读 `ResidentStatusStore`、无 `running ?` 两态判断、徽标受 `tone == .normal` 约束）一起进 PASS 条件。

**重跑（2026-11-23，`bash qa/run-all.sh`）**：T-02 `5 PASS / 0 FAIL`，其中 C4 证据行：

```text
PASS C4  MenuBarLabel（33 行）读 ResidentStatusStore 1 处；块内 'running ?' 两态判断 0 处（要求 0）；onReceive(engine.$state 订阅 1 处（按事件更新，不靠别处重绘）；块内 Timer 0 处（要求 0，不许定时器兜底）；延迟徽标行受 tone == .normal 约束：if let badge = status.badge, tone == .normal {
```

注意：区块从 15 行变成 33 行（多了订阅与 `sync()`），所以「读 ResidentStatusStore」现在落在 `sync()` 里的 `ResidentStatusStore.shared.update(from: engine)`——渲染路径不读 store，只看 `@State tone`。这与 C4 的原意一致（仍然只有一个状态源），但读法变了：**不是每个视图都直接订阅 store，而是由引擎事件驱动 store 更新、图标取 `tone`**。

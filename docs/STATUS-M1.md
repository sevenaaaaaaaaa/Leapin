# M1 交接台账 · 2026-11-23

> 用途：停止当前阶段时，把「做完了什么、没做什么、东西在哪、怎么接着干」写死，避免下次从记忆里重建。
> 本文件只记录事实；产品口径仍以 `docs/PRODUCT-v4.md` 与 `docs/tasks/product-v4.md` 为准。

## 0 收口记录（2026-11-24）

**用户决定：带缺口收口。** §3.2 的四项只能人工确认（关窗 8 小时 RSS、13 寸屏面板不裁切、真实失败时图标字形、切换 ≤1 秒）与 §3.3 的六条已知取舍，接受为遗留，不在本轮补。

**一处更正**：§3.1 写「T-04 未开工」已经过时——T-04（系统代理标志按事实回读）在本仓库已完成，`qa/T-04` 4/4，`Tests/LeapinRuntimeTests/SystemProxyFlagTests.swift` 覆盖。M1 的已完成 / 未完成以 `docs/tasks/product-v4.md` 与 `.dsh-crew/jobs/product-v4/state.json` 为准，本文保留原记录不再改写。

## 1 一句话状态

M1（常驻层）的**代码部分已完成并验收**（T-01 / T-02 / T-03），自动化检查 16 项全绿、单测 427 通过 0 失败；**还有 1 个安全评审发现的任务（T-04）未做**，以及 4 项只能人工确认的验收。没有提交 git，没有发版，`/Applications/Leapin.app` 仍是 1.13.13。

## 2 已完成

| 任务 | 内容 | 证据 |
| --- | --- | --- |
| T-01 | 常驻层一个状态源：`ResidentStatus` + `ResidentStatusStore`；菜单栏面板收成「现在 / 切换 / 异常 / footer」；节点切换、端口、接管开关、页面导航都一步可达；浮窗与面板读同一份 | 15 条单测；`qa/T-01` 7/7；code review 两轮；doc review 两轮 |
| T-02 | 状态栏图标四态（未运行斜线盾 / 正常空盾 / 降级感叹号盾 / 失败叉盾），事件驱动、窗口全关也更新；延迟徽标只在正常态显示 | 6 条单测；`qa/T-02` 5/5；code review 三轮（R2-1 已修） |
| T-03 | 系统代理切换成功后清掉上一条失败，避免面板/图标长期停在降级；入口不再误清别的子系统的错误 | 3 条单测；`qa/T-03` 4/4；安全评审 B-1 已修 |

自动化总账（最后一次全量，2026-11-23 21:15 前后）：

- `swift build`：exit 0，改动文件零新增 warning。
- `swift test`：430 个用例，**427 通过 / 0 失败 / 3 跳过**（跳过的是需要 mitmproxy 的既有用例），exit 0。
- `bash qa/run-all.sh`：T-01 7/7、T-02 5/5、T-03 4/4，**16 项全过**。

## 3 未完成

### 3.1 T-04（未开工，任务行已写）

安全评审 B-2：`toggleSystemProxy` 成功后按入参写 `systemProxyActive`，不读回系统真实状态。机器上原有企业代理、或 `networksetup` 退出 0 但未生效时，常驻层会显示「接管范围：系统代理」，实际直连。
修法与文件所有权见 `docs/tasks/product-v4.md` 的 T-04；状态 `todo`。

### 3.2 只能人工确认的四项

| 项 | 为什么不能自动化 | 怎么做 |
| --- | --- | --- |
| 关窗连续 8 小时 RSS 增长 < 20MB | 需要真实时间与真实流量 | 启动 App、关窗口、放一夜，记录 `ps -o rss= -p <pid>` 前后值 |
| 13 寸屏（1440×900 缩放）面板展开不被裁切 | 需要真实屏幕 | 在 13 寸 Mac 上点开菜单栏面板，看底部是否出屏 |
| 状态栏图标在真实失败时变叉盾 | 需要真实引擎失败 | 占住 7890 再启动，或制造脚本降级，看图标字形 |
| 切换配置 / 场景 ≤ 1 秒 | 需要真实配置与计时 | 两个配置间切换，秒表/录屏计时（失败回滚与原因已由引擎与面板覆盖） |

### 3.3 已知但不在本轮修的点

- `uncoveredProcesses` 目前恒为 `nil`：接管范围永远显示「部分进程未覆盖」，「有 N 个 / 未检测到」两条分支只有测试覆盖（PRD §2.5 允许「不能检测就写部分」）。
- `ObservationView` 仍保留第三处速率采样（属 M2「为什么」重写范围）。
- 浮窗隐藏时 `FloatingStatusView` 的 1 Hz ticker 随视图移除而停，但面板关闭后 store 不采样——图标走事件驱动，速率只在使用中的面上刷新，属预期取舍。
- 菜单栏面板打开期间节点延迟/选中不再每秒刷新（只在打开、状态/配置变化、动作后取快照）；这是评审 B1 的取舍，若产品要「15s 慢速补刷」需另开任务。
- T-03 的 C3 是静态次序检查；`applySystemProxySuccess` 的行为有单测，但「接线」本身只有静态检查守。
- T-04 落地后，`qa/T-03` 的 C3 可能要按 T-04 的新分支再调一次（已在 qa/T-03 报告里记）。

## 4 工作区里有什么（未提交）

修改（5）：

- `Sources/LeapinApp/LeapinApp.swift`（T-02：MenuBarLabel）
- `Sources/LeapinApp/Views/FloatingStatusView.swift`（T-01）
- `Sources/LeapinApp/Views/MenuBarPanel.swift`（T-01 + 两轮评审修复）
- `Sources/LeapinRuntime/TouchFlowEngine.swift`（T-03）
- `Sources/LeapinApp/Platform.swift`（**不是本任务的改动**：一行 `host.appearance = NSAppearance(named: .aqua)`，属他人未提交工作，评审时不要算进 T-01）

新增（代码/测试）：

- `Sources/LeapinRuntime/ResidentStatus.swift`
- `Sources/LeapinRuntime/ResidentIcon.swift`
- `Tests/LeapinRuntimeTests/ResidentStatusTests.swift`
- `Tests/LeapinRuntimeTests/ResidentIconTests.swift`
- `Tests/LeapinRuntimeTests/SystemProxyErrorTests.swift`

新增（文档/验收）：

- `docs/PRODUCT-v4.md`、`docs/tasks/product-v4.md`
- `qa/run-all.sh`、`qa/T-01/`、`qa/T-02/`、`qa/T-03/`（各含 run.sh + report.md）
- `.dsh-crew/jobs/product-v4/state.json`（进度，不入库）
- 评审报告：`.dsh-crew/jobs/product-v4/reviews/T-01-code-review.md`、`T-01-doc-review.md`、`M1-security-review.md`

无 git 分支、无 commit、无 push。`dist/` 与 `/Applications/Leapin.app` 未更新。

## 5 怎么接着干

```bash
cd /Users/sevenaaaaaaa/TouchFlow
swift build --scratch-path /tmp/t01-scratch --disable-sandbox
swift test  --scratch-path /tmp/t01-scratch --disable-sandbox
bash qa/run-all.sh
```

- 试 App：`swift run --scratch-path /tmp/t01-scratch LeapinApp`。
- 重新生成 App：`./scripts/build-app.sh` → `dist/Leapin.app`（release，较慢）。
- 清掉重来：`rm -rf /tmp/t01-scratch /tmp/t02-scratch /tmp/t03-scratch` 后全量构建（约 7 分钟/个）。**不要删 .build 以外的仓库文件**。
- 任务状态与下一件事：`.dsh-crew/jobs/product-v4/state.json`；M1 已置 `review`，T-04 为 `todo`。

## 6 中止时的判断

- 代码可编译、测试全绿，工作区是**可继续**的，不是半截坏树。
- 唯一未接线的新能力是 T-04 的「按事实回读」；在它完成前，接管范围那行在「机器上已有别的代理」这一种情况下会说错。
- 没有发布任何东西，所以不存在需要回滚的线上状态。
- 2026-11-23 决定：**不做 baseline commit**（未获 git 写授权）；工作区即基线，M2 评审按文件 + hunk 归属。M1 的五份文件在 M2 期间保持不动。

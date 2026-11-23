# T-01 验收报告 · 常驻层（一个状态源，三块面板）

- 任务：T-01 · `docs/tasks/product-v4.md`（DoD 七条 + 不可自动化一条）
- 依据：`docs/PRODUCT-v4.md` §2.5 诚实条款
- 被测仓库：/Users/sevenaaaaaaa/TouchFlow（branch main，改动未提交）
- 脚本：`qa/T-01/run.sh`（bash，`set -uo pipefail`）
- 重跑：`bash qa/T-01/run.sh`（默认 `T01_CLEAN=1`，先清空 /tmp/t01-scratch 再构建；`T01_CLEAN=0` 复用增量目录）
- 日志：`/tmp/t01-qa-logs/c1-build.log`、`/tmp/t01-qa-logs/c2-test.log`
- 结论：**7 PASS / 0 FAIL，退出码 0**

## 完整输出（真跑，未编辑）

```text
T-01 验收 · 仓库 /Users/sevenaaaaaaa/TouchFlow
scratch=/tmp/t01-scratch（T01_CLEAN=1）· 日志=/tmp/t01-qa-logs
----------------------------------------------------------------
PASS C1  swift build --scratch-path /tmp/t01-scratch --disable-sandbox → exit 0；日志 0 个 error:、57 个 warning:，其中落在本次改动三个文件上的 0 个
PASS C2  swift test --filter ResidentStatusTests → exit 0；汇总行「Executed 15 tests, with 0 failures (0 unexpected) in 0.006 (0.007) seconds」；逐条 passed 用例 15 个
PASS C3  两个视图里 lastBytesIn|lastBytesOut|lastSample 命中 0 次（要求 0），Sources/LeapinRuntime/ResidentStatus.swift 里 ResidentRateMeter 出现 2 次
PASS C4  body 顶层恰 4 项且顺序为 nowCard|switchCard|if showsIssues { issueCard }|footer；'if showsIssues' 命中 1 次（issueCard 条件渲染）；面板 .frame(width: 276) ≤ 280
PASS C5  Sources/LeapinApp/Views/MenuBarPanel.swift 同时含节点/端口/系统代理/导航四类入口，命中次数： node:menuBarSelect=1 port:open(.settings)=1 port:mixedPort=1 proxy:toggleSystemProxy=1 nav:ForEach(4页)=1
PASS C6  declaration 三分支齐全：未检测到绕过进程=1、有 N 个进程未覆盖=1、部分进程未覆盖=1；面板按 status.coverage.declaration 渲染 1 处（§2.5 写进 App）；测试里 Uncovered 用例 1 个、systemProxy 三文案断言 4 处
PASS C7  已改文件仅 MenuBarPanel.swift、FloatingStatusView.swift（外加他人未提交的 Platform.swift：新增 1 行 / 删除 0 行，唯一新增即 host.appearance）；Sources/ Tests/ 下新增仅 ResidentStatus.swift、ResidentStatusTests.swift；docs 未跟踪项=[docs/PRODUCT-v4.md docs/tasks/product-v4.md]（PM 文档，非代码）
----------------------------------------------------------------
T-01 结果：7 PASS / 0 FAIL（C1 构建 · C2 单测 · C3 速率唯一 · C4 三块+footer · C5 一步到达 · C6 覆盖声明 · C7 未改禁区）
RUN_EXIT=0
```

## 逐条结果

| 检查 | 结果 | 关键证据 |
| --- | --- | --- |
| C1 构建 | PASS | `swift build --scratch-path /tmp/t01-scratch --disable-sandbox` exit 0；0 error:，57 warning:，三个改动文件上 0 warning |
| C2 单测 | PASS | `Executed 15 tests, with 0 failures`；逐条 passed 15 个用例 |
| C3 速率差分唯一 | PASS | 两个视图 `lastBytesIn|lastBytesOut|lastSample` 命中 0；`ResidentStatus.swift` 里 `ResidentRateMeter` 2 次 |
| C4 三块+footer | PASS | body 顶层恰 4 项，顺序 nowCard / switchCard / `if showsIssues { issueCard }` / footer；`.frame(width: 276)` ≤ 280 |
| C5 一步到达 | PASS | menuBarSelect=1、open(.settings)=1、mixedPort=1、toggleSystemProxy=1、ForEach 四页导航=1 |
| C6 覆盖声明 | PASS | declaration 三分支齐全；面板渲染 `status.coverage.declaration`；测试含 Uncovered 用例、三文案断言 4 处 |
| C7 未改禁区 | PASS | 只改 MenuBarPanel.swift、FloatingStatusView.swift；新增仅 ResidentStatus.swift、ResidentStatusTests.swift；Platform.swift 仅 1 行 `host.appearance` 新增、0 删除 |

### C7 的判定口径（写清楚，便于复核）

- `git diff --name-only` = `Sources/LeapinApp/Platform.swift`、`Sources/LeapinApp/Views/FloatingStatusView.swift`、`Sources/LeapinApp/Views/MenuBarPanel.swift`。
- `git diff -U0 -- Sources/LeapinApp/Platform.swift`：新增 1 行、删除 0 行，唯一新增即 `host.appearance = NSAppearance(named: .aqua)` → 判为“他人未提交改动，本次未触碰”。
- `git ls-files --others --exclude-standard` 中 Sources/ 与 Tests/ 下只有 `Sources/LeapinRuntime/ResidentStatus.swift`、`Tests/LeapinRuntimeTests/ResidentStatusTests.swift`。
- 未跟踪的 `docs/PRODUCT-v4.md`、`docs/tasks/product-v4.md` 是本次任务文档（PM 产出，非代码），不计入 C7。
- 说明：git 无法区分同一工作区里一行改动的作者；C7 用任务表给定的“Platform.swift 只有 host.appearance 一行”作为判定标准。

## 检查能不能红（变异反证，在 /tmp 副本上做，不动仓库）

| 变异 | 对应检查证据变化 |
| --- | --- |
| 往面板副本加一行 `private var lastBytesIn` | C3 命中 0 → 1（会 FAIL） |
| `.frame(width: 276)` → `320` | C4 宽度 276 → 320（>280，会 FAIL） |
| 删掉 `if showsIssues { issueCard }` 顶层行 | C4 顶层项数 4 → 3（会 FAIL） |
| 删掉含 `menuBarSelect` 的调用行 | C5 node 1 → 0（会 FAIL） |
| 删掉导航 ForEach 行 | C5 nav 1 → 0（会 FAIL） |
| 删掉「未检测到绕过进程」分支 | C6 该分支 1 → 0（会 FAIL） |

结论：C3–C6 的 grep 判定不是恒真。C1/C2 由编译器与 XCTest 自己判红，不可能恒真。

## DoD 与 C 项的对应（供里程碑复核）

- DoD 1（五种输入：空闲 / 运行中 / 脚本降级 / 引擎失败 / 有未覆盖声明）：对应用例
  `testIdleStatusSaysStoppedAndClaimsNoCoverage`、`testRunningStatusCarriesOneRouterDecision`、
  `testScriptDegradationTurnsTheInkHalfRed`、`testEngineFailureTurnsTheInkRed`、
  `testUncoveredProcessesAreAFactNotAWarning`。C2 只验“15 个用例全绿”，**“从红到绿”的过程证据不在这里**，需由实现方的 test-first 记录提供。
- DoD 2 → C3；DoD 3 / DoD 4 → C4 + C5；DoD 7 → C7；§2.5 → C6。
- DoD 5 的后半句（13 寸屏 1440×900 下展开不被屏幕裁切）**未机器验证**：需要真实屏幕与窗口几何，本脚本只验宽度 ≤ 280。
- DoD 6 的“零新增 warning”：C1 记录本机全量构建 57 条 warning，落在本次改动的三个文件上的 0 条（其余在 FloatingPanel.swift、TouchFlowEngine.swift、TunTCPRelay.swift、Rewrite.swift）；“新增”需与基线对比，此处给出的是当前实测值。

## 未覆盖项（不伪造）

- **关窗连续运行 8 小时 RSS 增长 < 20MB：未测**。原因：需要真实运行 8 小时并连续采样 RSS，本机 QA 窗口内无法完成，且任务表已把它放到里程碑人工验收；本任务只承诺“新增对象不持有定时器”，此项已旁证：`ResidentStatus.swift` 内无 `Timer.publish` / `DispatchSource` / `Task.sleep`（唯一 `while` 是单位换算循环）；`FloatingStatusView` 的 1 Hz ticker 在 HEAD 版本就存在，非本次新增。

## 观察（不是 FAIL，供里程碑评审判断）

1. `uncoveredProcesses` 在 Sources/ 里只有 `ResidentStatus.swift` 自己引用，两个调用点都走默认值 nil，因此**运行期声明恒为「接管范围：系统代理 · 部分进程未覆盖」**；「有 N 个进程未覆盖」「未检测到绕过进程」两条分支目前只有测试覆盖，未接检测。按 §2.5「不能检测就写部分进程未覆盖」这属于合规实现，但评审时应知道计数分支还没接线。
2. `ResidentStatusStore` 用 `@Published` + 调用方驱动采样；面板 `liveLoop()` 在前台以 1 Hz 跑，视图消失即停（`.task` 取消）。这与“不持有定时器”一致。

## 本次 QA 的写盘范围

只写了 `qa/T-01/run.sh` 与本文件 `qa/T-01/report.md`；未改 `Sources/`、`Tests/`、`docs/`；未 `git add` / `git commit`；构建与日志落在 `/tmp`。变异试验在 `/tmp/t01-mut` 的副本上做，仓库文件未动。

## C7 断言更新（2026-11-23 · 范围变化导致，不是放宽标准）

T-02（菜单栏图标三态）与 T-03（系统代理切换成功后清除上一条错误）已并入同一工作区，工作区不再只有 T-01 的改动。旧 C7 的允许清单只列了 T-01 的两个文件，会把 T-02 / T-03 的正常落地说成越界——这是**假阳性**，不是待修的缺陷。按 M1 里程碑允许清单改写：

- 允许修改：`Sources/LeapinApp/Views/MenuBarPanel.swift`、`Sources/LeapinApp/Views/FloatingStatusView.swift`、`Sources/LeapinApp/LeapinApp.swift`、`Sources/LeapinRuntime/TouchFlowEngine.swift`
- 允许新增：`Sources/LeapinRuntime/ResidentStatus.swift`、`Tests/LeapinRuntimeTests/ResidentStatusTests.swift`、`Sources/LeapinRuntime/ResidentIcon.swift`、`Tests/LeapinRuntimeTests/ResidentIconTests.swift`、`Tests/LeapinRuntimeTests/SystemProxyErrorTests.swift`
- `Sources/LeapinApp/Platform.swift` 仍只允许 `host.appearance` 一行（新增 1 / 删除 0 / 命中 1）
- `docs/` 与 `qa/` 不计入

**没有放宽的部分**：清单外的已改文件仍然 FAIL；`Platform.swift` 多于一行仍然 FAIL；`Sources/`、`Tests/` 下清单外的新增仍然 FAIL。清单来源是 `docs/tasks/product-v4.md` 里 T-01 / T-02 / T-03 的「文件所有权」，不是"什么都放行"。

**这条断言现在能证明什么、不能证明什么**：
- 能证明：整个 M1 工作区没有越界文件（没有改到 `DashboardView`、引擎的其他部分、视图之外的东西），`Platform.swift` 没被本次工作动过。
- 不能证明：T-01 单独只改了两个文件。工作区未提交，git 无法把同一棵树里的改动按任务切开；逐任务归属要靠提交边界（本次 QA 不做 `git add` / `git commit`）。这一点是口径变化带来的真实损失，记在这里而不是让它悄悄消失。

## 并发事故记录（2026-11-23 21:03，我造成的）

**发生了什么**：21:03 我在没有先看有没有别人在跑的情况下，发起了第二次 `bash qa/run-all.sh`。同时 lead 的 `bash qa/run-all.sh`（PID 22552，21:01:50 启动）正在 T-01 的 `swift build` 里编译。我的 T-01 脚本第一件事是 `rm -rf /tmp/t01-scratch`（当时默认 `T01_CLEAN=1`），而对方正在用这个目录 → 删除与编译并发。

**证据**：
- 我的输出 `/tmp/runall2.out`：`rm: /tmp/t01-scratch/out/Intermediates.noindex: Directory not empty`（边删边被重建）。
- 我的构建日志：`Another instance of SwiftPM (PID: 23123) is already running using '/tmp/t01-scratch', waiting until that process has finished execution...`
- 对方输出 `/tmp/runall.log`：同一分钟 `FAIL C1 ... error: SwiftCompile normal arm64 .../LeapinNet/Proxy/ProxyServer.swift failed with a nonzero exit code`，紧接着 `PASS C2 ... Executed 15 tests, with 0 failures`（测试重编后正常）。
- 结论：**对方那条 C1 FAIL 是我的 `rm -rf` 造成的假失败，不是代码问题**；ProxyServer.swift 本身没有改动，也没有编译错误。

**我做的处置**：按精确 PID 只杀了自己的进程树（23132 swift-build → 23108 T-01 → 23103 run-all → 23102/23101 包装 shell），确认全部退出；对方进程（22549/22552）未动，仍在运行。我这边没有任何进程残留。

**改了什么（防止再犯）**：
- `qa/T-01/run.sh` 的 `T01_CLEAN` 默认值从 `1` 改成 `0`：默认**复用** `/tmp/t01-scratch`，不删目录；要一次干净的全量构建（例如核对 warning 数）时显式 `T01_CLEAN=1`，并且先确认没有别的构建在用这个目录。脚本头部写了这条原因。
- C1 的 PASS 行现在会写明本轮是「全量构建」还是「复用 scratch」，避免把「没重编所以 0 warning」读成「代码零 warning」。

**这份报告里贴的输出（21:00 那一跑）与当前脚本的差异**：判定逻辑没变，之前之后只改了两处文案/默认值（CLEAN 默认值、C1 证据行）。按 lead 的暂停指令，改完后没有重跑，只做了 `bash -n`。

## C7 第三次口径调整（2026-11-23 · 改为只判本任务边界）

前两版 C7 判的是「整棵树只许有 M1 允许清单里的改动」。累计里程碑里这条必然反复误报：T-02 加 `ResidentIcon*`、T-03 加 `SystemProxyErrorTests`、T-04 加 `SystemProxyFlagTests`，每落一个任务清单就要改一次，而且红的是「清单没跟上」，不是「有人越界」。本轮已按 PM 指示改成只判 T-01 自己的边界：

1. 四个交付物存在且非空：`MenuBarPanel.swift`、`FloatingStatusView.swift`、`ResidentStatus.swift`、`ResidentStatusTests.swift`；
2. `Platform.swift` 仍是 `+1 行 host.appearance / 0 删除`（这条保留，它防的是「顺手把别人的未提交改动一起改掉」）；
3. **删掉**「新增文件只能是我这两个」的整树断言。

**这条断言现在能证明什么、不能证明什么**：
- 能证明：T-01 的四件交付物真的在、不是空壳；`Platform.swift` 没被人多改一行。
- 不能证明：工作区里没有越界文件。**整树洁净度由 PM 在提交前统一检查，不在任务脚本里判**——脚本只看得到「当前工作区」，看不到「这次改动属于哪个任务」，在未提交的树上做归属判定只会假红。

## 全量重跑（C7 改写 + T-03 C3 二次更正后）

`bash qa/run-all.sh`（T-01..T-04）→ **4 个任务全部通过，RUNALL_EXIT=0**。T-01 的 C7 现行为：

```text
PASS C7  T-01 交付物四个存在且非空：MenuBarPanel.swift=546 行 FloatingStatusView.swift=192 行 ResidentStatus.swift=419 行 ResidentStatusTests.swift=216 行；Platform.swift 新增 1 行 / 删除 0 行 / host.appearance 命中 1 次（要求 1/0/1）；整树洁净度不在本脚本判（PM 提交前统一检查）
```

（以上两节 C7 口径描述以此为准；前面「M1 允许清单」那两节是历史记录，已不适用。）

# M2 交接台账 · 2026-11-23

> 用途：停止当前阶段时，把「做完了什么、没做什么、东西在哪、怎么接着干」写死，避免下次从记忆里重建。
> 本文件只记录事实；产品口径仍以 `docs/PRODUCT-v4.md` 与 `docs/tasks/product-v4.md` 为准。
> 每个任务的判据与结论在任务行的 **Verdicts** 与 `qa/T-xx/run.sh`，本文只汇总。

## 0 收口记录（2026-11-24）

**用户决定：带缺口收口。** §5 的六项人工 / 真机确认（S2 90 秒端到端、面板与首屏四个数字逐字一致、13 寸屏面板展开不被裁切、关窗 8 小时 RSS、报告导出真的落盘、Mihomo 下禁用与说明）与 §6 的八条非阻塞缺口，接受为遗留，不在本轮补。

其中一条已被后续动作改掉口径，记在这里免得重复排查：`qa/T-08` C2 原本锁「四事实的函数名」，CRD 0002 已把它改成行为判据（数标签，不锁控件形态）。其余各条仍按 §6 原样挂着。

## 1 一句话状态

M2（工作层四动词）**代码部分完成**：T-05..T-14 全部落地，14 个任务验收脚本全绿，全量单测 **458 通过 / 0 失败 / 3 跳过**，`swift build` exit 0、本轮改动文件 0 条 warning。
没有 commit、没有 push、没有发版；`/Applications/Leapin.app` 仍是 1.13.13。
剩下的是**只能人或真机确认**的项（§5），以及 8 条已记录的非阻塞缺口（§6）。

## 2 已完成

| 任务 | 内容 | 证据 |
| --- | --- | --- |
| T-05 | 工作层纯逻辑：四动词 / `RouteContext` peek·take / 11 行侧栏计划 / `RuleDraft`（policy 不写死） | WorkbenchTests 24 条；`qa/T-05` 5/5 |
| T-06 | App 壳：11 行侧栏 + why / dashboard 落点 + 两个页面壳 | `qa/T-06` 6/6 |
| T-07 | 「为什么」四 tab + 连接搜索注入；切 tab 不销毁，seed 只写首帧 | `qa/T-07` 9/9 |
| T-08 | 「走哪」首屏：五事实 + 四入口 + 接管范围；面板/浮窗未开时首屏自己驱动共享 store | `qa/T-08` 7/7 |
| T-09 | 「改成什么」四 tab 共用 `applyRewrite`；脚本只读 + 启停（按位置，不按名字） | `qa/T-09` 7/7 |
| T-10 | 「怎么判」策略组两套来源 + 学习入口 + 带 host 跳「为什么」+ 永不命中/被遮蔽标记 | `qa/T-10` 7/7 |
| T-11 | 「为什么 · 指标」嵌入 `ObservationView(embedded: true)`，去页头、不新增采样 | `qa/T-11` 8/8 |
| T-12 | 「为什么 · 探测 / 诊断」接同一工作区；原地 `RuleDraft` 改路 → `submit(host:policy:)` → 原地重测；报告导出 .md | `qa/T-12` 7/7 |
| T-13 | Privacy 逐项迁移后删页；旧 rawValue 各落一个视图；Platform 快照 / Dock / 页头同步 | `qa/T-13` 7/7 |
| T-14 | 汇总验收脚本（9 个子任务账本 + 11 行/四动词/Privacy 不可达/并入页无入口）+ S2 人工计时模板 | `qa/T-14` 6/6；模板 `qa/T-14/report.md` |

## 3 自动化总账（2026-11-23 23:25 前后，最后一次全量）

- `swift build --scratch-path /tmp/t12-scratch --disable-sandbox` → **exit 0**；本轮改动文件 warning **0** 条（全仓 56 条历史 warning 都在他人未提交文件：`TouchFlowEngine.swift` / `FloatingPanel.swift` 等）。
- `swift test --scratch-path /tmp/t12-scratch --disable-sandbox` → **exit 0**；**458 passed / 0 failed / 3 skipped**（跳过的是需要 mitmproxy 的既有用例）。
- `bash qa/run-all.sh` → **14 个任务全部通过**：

| 任务 | 结果 | 任务 | 结果 |
| --- | --- | --- | --- |
| T-01 | 7/7 | T-08 | 7/7 |
| T-02 | 5/5 | T-09 | 7/7 |
| T-03 | 4/4 | T-10 | 7/7 |
| T-04 | 5/5 | T-11 | 8/8 |
| T-05 | 5/5 | T-12 | 7/7 |
| T-06 | 6/6 | T-13 | 7/7 |
| T-07 | 9/9 | T-14 | 6/6 |

（`qa/run-all.sh` 把每个子任务的结果写进 `${TMPDIR}/qa-run-all-results.tsv`，T-14 在回归里读这份账本、不重复跑九个子脚本。T-14 的**单独模式**也实测过一次：逐个调用 T-05..T-13 全 PASS，再跑自己的 6 条断言，6/6。）

## 4 评审与修复

### 4.1 T-07 / T-08 / T-09 / T-10（既有评审报告 `reviews/T-07-10-code-review.md` + 本轮修复）

| 任务 | blocking | 修法 | 复核 |
| --- | --- | --- | --- |
| T-07 | 切 tab 重挂载会二次 seed，把用户搜索词顶掉 | 四 tab 叠在 ZStack 里按 `mounted` 保活、`opacity` 显隐；`CaptureView` 只在首帧吃 seed | `qa/T-07` C9 |
| T-08 | 面板/浮窗都没开时 store 没人喂帧：出口恒空、速率恒 0、拦截数不涨 | 首屏 `.task` 先取 `menuBarSnapshot`（出口）再 1 Hz 驱动共享 store；离开页面即取消，差分仍只在 store 一次 | `qa/T-08` C6 |
| T-09 | 无 blocking | optional：脚本行 id 撞车改为按位置；`Change.script` 跟着改成 index（见 4.2 B1） | `qa/T-09` C5 |
| T-10 | 无 blocking | optional：诊断随规则**内容**刷新（不只条数）；负载均衡组类型大小写归一 | `qa/T-10` C4/C5 |

T-08 另外恢复了被「删统计块」顺带删掉的两个快捷动作（导入与转换订阅 / 管理线路）。

### 4.2 T-11..T-14（独立评审 `m2-reviewer`，只读，2026-11-23）

4 条 blocking，全部修复并复核：

| # | 问题 | 修法 |
| --- | --- | --- |
| B1 | 脚本启停整体失效：`Row.id` 改成位置后，写路径仍把 id 当脚本名 | `Change.script(index:enabled:)`，`commitScript` 用下标并校验越界；视图传 `row.index` |
| B2 | 诊断正忙时保存改路：sheet 关掉、规则没写、没有任何提示 | `submit` 的 busy 分支写原因；编辑器 `onSave` 返回错误串并留在 sheet 里显示；入口按 busy / 内核禁用 |
| B3 | 「规则已存在」时 receipt 与 undo 说假话，还挤掉上一次真实改动的撤销点 | 只在真正写入时更新 `receipt`/`applied`；已存在时只重测并说明「配置未改动」 |
| B4 | `qa/T-12` C3 对「submit 内调 diagnose」恒绿 | 断言锚到 `submit` 函数体；已做红测（删掉那行 → C3 FAIL，恢复 → PASS） |

optional 里修了：O1 隐藏 tab 抢聚焦（`DiagnosticsWorkspace.isActive`）、O2 探测 tab 里看不见结果的本地检查按钮、O3 本地检查后「重新检查」死键/串到旧 host、O4 导出失败无声 + .md 类型、O8 Mihomo 下改路入口先禁用。
O5（T-08 DoD 与 C6 互相矛盾）按「更正不改原文」写进 T-08 的 DoD 3 追加段；O6 / O7 记为缺口（§6）。

### 4.3 评审角色缺口（重要）

本会话没有 `crew_*` 角色工具（插件未挂载），所以：
- T-07..T-10 的评审来自既有评审报告（`reviews/T-07-10-code-review.md`）＋本轮 PM 逐条核对；
- T-11..T-14 由一个独立子代理（`m2-reviewer`，只读，无构建权限）评审，报告要点见 4.2；
- 没有独立 QA 角色：`qa/T-12`、`qa/T-14` 由 PM 按 DoD 写，其余脚本沿用之前的版本；`qa/run-all.sh` 与账本由 PM 维护。

## 5 只能人工 / 真机确认（M2 收口前）

| 项 | 为什么不能自动化 | 怎么做 |
| --- | --- | --- |
| S2 端到端 90 秒 | 需要真实站点、真实耗时与人的判断 | 按 `qa/T-14/report.md` 的 8 步走查并填计时表 |
| 面板与首屏四个数字逐字相同 | 需要两个面同时可见 | 打开菜单栏面板与主窗口首屏，截图对照（M1 DoD 2 的窗口一致性） |
| 13 寸屏（1440×900 缩放）面板展开不被裁切 | 需要真实屏幕 | 13 寸 Mac 上点开面板看底部 |
| 关窗连续 8 小时 RSS 增长 < 20MB | 需要真实时间与流量 | 启动 App、关窗、放一夜，比较 `ps -o rss= -p <pid>` |
| 报告导出真的落盘 | 系统保存面板 | 诊断 tab 生成报告 → 导出 → 打开 .md |
| Mihomo 内核下「改成走公司…」禁用与说明 | 需要 Mihomo 配置 | 切 Mihomo 看按钮是否灰、悬停说明是否正确 |

## 6 已知缺口与待排期（非阻塞）

1. **run-all 没有看门狗**（评审 O6）：14 个脚本各自构建/测试；CLAUDE.md 记录过 SwiftPM 偶发卡死，一旦卡住整轮会挂住。建议下一步给每脚本加后台 PID + 超时。
2. **首屏 1 Hz 循环在窗口最小化/App 后台时仍醒着**（评审 O7）：关窗会随视图销毁而停；最小化不停。与 M1「关窗不养后台」不冲突，但可再收。
3. **指标 tab 的 ⌘F 聚焦请求还没接 isActive**：`ObservationView` 的构造字符串被 `qa/T-11` C1/C2 固定，本轮只给 `DiagnosticsWorkspace` 加了门；先开指标、再开探测/诊断时可能两处同时接聚焦。
4. **T-09 剩余 optional 4 条**：AdBlock 四个开关不经 `applyRewrite`（口径是「列表写引擎只有 Deck」）、白名单编辑器本地副本漂移、`commitScript` 失败时 enabled 仍为 true、`pendingDelete` 存 index 的模态陈旧。
5. **T-10 剩余 optional 3 条**：Mihomo 下临时规则横幅「全部清除」仍可点、IPv4 字面量被当 host 接受、IDN/单标签主机保守拒绝。
6. **`uncoveredProcesses` 恒 nil**（M1 遗留）：接管范围永远显示「部分进程未覆盖」。
7. **`ObservationView` 仍是第三处速率采样**（M1 遗留；M2 未合并，属后续统一）。
8. **qa 脚本口径本轮有 4 处更正**，原因都写在脚本注释或任务行里：`qa/T-01` C7（Platform 由 T-13 拥有，判据改为「那行仍在 + 无 T-01 符号」）、`qa/T-09` C5（Change.script 改 index）、`qa/T-12` C3（锚定 submit 函数体）、`qa/T-12` C5（两行构造 + `retestAction`）；`qa/T-08` DoD 3 追加了「Timer 0」的口径更正。

## 7 工作区里有什么（未提交）

修改（M2）：`Sources/LeapinApp/LeapinApp.swift`、`Platform.swift`、`Design/CommandPalette.swift`、`Design/NetworkAssistant.swift`、`Views/{WhyPage,GoWherePage,DashboardView,ProfilesView,CaptureView,ObservationView,RewriteDeck,RewriteView,AdBlockView,RulesView,SettingsView}.swift`、`Sources/LeapinRuntime/NetworkTask.swift`。
修改（M1 遗留）：`Views/{MenuBarPanel,FloatingStatusView}.swift`、`LeapinApp.swift`（MenuBarLabel）、`Sources/LeapinRuntime/TouchFlowEngine.swift`、`Platform.swift` 的那行 `host.appearance`。
删除：`Sources/LeapinApp/Views/PrivacyView.swift`。
新增（代码/测试）：`Sources/LeapinRuntime/{ResidentStatus,ResidentIcon,Workbench}.swift`、`Sources/LeapinApp/Views/{WhyPage,GoWherePage,RewriteDeck}.swift`、`Tests/LeapinRuntimeTests/{ResidentStatus,ResidentIcon,SystemProxyError,SystemProxyFlag,Workbench}Tests.swift`。
新增（文档/验收）：`docs/PRODUCT-v4.md`、`docs/tasks/product-v4.md`、`docs/design/{DESIGN-v5.md,hld-2026-11-23-product-v4-m2.md,mockups/}`、`docs/STATUS-M1.md`、本文件、`qa/run-all.sh`、`qa/T-01..T-14/`（各 `run.sh`，部分有 `report.md`）。
进度文件：`.dsh-crew/jobs/product-v4/state.json`、`reviews/`（不入库）。
无 git 分支、无 commit、无 push；`dist/` 与 `/Applications/Leapin.app` 未更新。

## 8 怎么接着干

```bash
cd /Users/sevenaaaaaaa/TouchFlow
swift build --scratch-path /tmp/t12-scratch --disable-sandbox
swift test  --scratch-path /tmp/t12-scratch --disable-sandbox
bash qa/run-all.sh
```

顺序建议：① 按 §5 做完人工项 → ② 把结论贴回 T-14 的 `report.md` → ③ 用户点头后再 commit（提交信息英文，`feat(dashboard): ...` 风格，正文写清 S2 与测试数字）→ ④ M3 才动 iOS。M3 未开工，任务行在 `docs/tasks/product-v4.md` 末尾。

# T-15 人工核对清单（W1）

> 脚本 `bash qa/T-15/run.sh` 只能验代码层（8/8 PASS）。下面是脚本验不了、必须人看的六件事。
> 每条都写了「看什么、判据、不通过时改哪里」。

## 脚本已验（2026-11-24，8/8）

| 项 | 结果 |
| --- | --- |
| C1 构建 | exit 0，error 0，Theme.swift 0 warning |
| C2 字号下限 | 全仓 <11pt 0 处 |
| C3 v5 token | paper/sheet/ink/line/selectionFill + LPType/LPSpace/LPRadius 齐备 |
| C4 玻璃收敛 | 内容区 0 处（浮层 5 处 + 抓包页内浮卡 1 处保留） |
| C5 页头 | 壳渲染 1 处，页面内重复标题 0 处 |
| C6 侧栏选中态 | ink 6% + 2px 朱红左条，旧浅朱红底 0 处 |
| C7 主按钮 | 工作页清点见输出；逐屏核对见下 |
| C8 单测 | 458 passed / 0 failed |

## 人工核对（六条）

1. **5 屏截图**：走哪 / 怎么判 / 改成什么 / 为什么 / 设置。存在 `docs/shots/design/v5-w1-<页>.png`。
   判据：每屏只有一个墨色焦点带；标题 28 看得见；正文不再是 9–10pt。
2. **逐屏主按钮 ≤1**：数每屏填充朱红的按钮。
   当前清点：GoWherePage 0、WhyPage 1（RuleDraftEditor）、RewriteView 2（页面 + RuleEditorSheet）、RulesView 2（页面 + AddRuleSheet）、ProfilesView 2（导入配置 / 全部测速，分属两个 tab）、DashboardView 0、MenuBarPanel 1。
   判据：同一屏（含 sheet）不出现两个朱红实心按钮。
3. **一级模块 ≤5**：数每屏页头之外的大块。
4. **对比度 AA**：正文对纸面 ≥4.5:1，次要文字同样；焦点环在纸面上可见。
5. **目标 ≥24pt**：侧栏行、tab、图标按钮的点击区。
6. **3 秒测试**：5 人里 ≥4 人能说出「这页干什么、该点哪」。这条只能实测，脚本不替代。

## 已知遗留（不在 T-15 范围，W2/W3 处理）

- 工具页主按钮仍是多个：`ImportCenter`（4）、`LearnView`（2）、`NetworkToolsView`（3）、`SSHView`（2）、`WorkspaceSheets`（最多 2）。W3 一并收。
- `CaptureView` 页内浮卡保留玻璃（它确实浮在内容之上），W3 决定去留。
- 侧栏图标仍是 SF Symbols 单色，W3 的品牌部分再动。
- `docs/shots/` 被 `.gitignore` 忽略，截图入库与否待定。

## 怎么跑

```sh
bash qa/T-15/run.sh        # 代码层 8 项
```

看界面：`swift build` 后运行 `LeapinApp`，或按 `docs/RELEASE.md` 出一个本地 .app。

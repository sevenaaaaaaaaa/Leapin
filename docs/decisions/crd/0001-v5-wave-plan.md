# CRD 0001 · 把 v5 三波纳入计划，新建 M2.5

- **状态**：accepted
- **谁提的**：用户（2026-11-23 会话，从四个选项里选「新建 M2.5，W1 先做先评审」）
- **决定人**：用户
- **触及**：`docs/tasks/product-v4.md`（新增 M2.5 段与 T-15）、`docs/design/DESIGN-v5.md` §11（补落点）、`state.json`（新增里程碑与任务）

## 用户要什么

`DESIGN-v5.md` 已经把界面复盘和 v5 规范写完，但三波（W1 token、W2 四动词重排、W3 品牌）没有进任何里程碑，任务表也只到 T-14。要求现在排进去，先做 W1 并停下来评审。

## 为什么

M2 交的是「四动词的功能」，不是「v5 的构图」。复盘 §1 列的十条——轴线打架、两种卡片语言并存、9–10pt 字、mono 泛滥、选中态读作警告、三种材质叠加——一条也没消。

先做 W1 的理由：W2 的四个页面重排全部复用 W1 的 token 与页头，晚做等于返工一次。

## 代价

- W1 动 `Theme.swift` 与全部视图的字号、玻璃、选中态，是全仓横向改动；只改「怎么摆」，不改任何功能 DoD。
- `swift test` 458 条逻辑上不受影响，但仍需重跑确认。
- 5 屏截图与 3 秒测试要人做，脚本替代不了。

## 裁定

**accepted**，决定人：用户。

## 新增的 DoD 项

7 条，写入 `docs/tasks/product-v4.md` 的 T-15 DoD 段。

## Applied

- `docs/tasks/product-v4.md`：新增「M2.5 · v5 构图落地」段与 T-15 行。
- `docs/design/DESIGN-v5.md` §11：标注 W1 = T-15 已进任务表，W2/W3 待 W1 评审后写行。
- `state.json`：milestones 增 M2.5（running），tasks 增 T-15。

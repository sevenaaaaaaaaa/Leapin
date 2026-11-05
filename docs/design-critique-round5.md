# TouchFlow · 第五轮视觉评审

> **对象**：~/TouchFlow · 提交 `历史提交`（Visual: ledger refinements — empty ledger, capture inspector, rules footer, type scale）
> **坐标约定**：本轮新图（18:37–18:42）为 1040×752 **1×**，1px = 1pt；旧图（18:21–18:23）为 2×。文中"实测"一律来自 PIL 像素扫描 / grep 源码，不是目测。
> **基准**：Awwwards / Webby 级桌面专业工具。**交付线 6.5 · 获奖线 8.0（且任何一维不得低于 7.7）**。
> **权限边界**：只读（read / grep / python 像素测量 / 局部放大裁切）。未改 .swift，未构建，未启动 App，未 commit，未补拍。

---

## 1. 加权分

**7.75**（62.0 ÷ 8 = 7.75）。上轮 7.48，**+0.27**。

## 2. 八维分数

| # | 维度 | 本轮 | 上轮 | 一句证据 |
|---|------|:---:|:---:|---|
| 1 | typography | **8.1** | 7.2 | mono 91 处字面量里 90 处落在 10/12（**97.8%**，上轮 51%），系统字号只剩 9/10/12/13/14/18/20/22/26/34，全站仅 1 处 mono(7)（TouchFlowApp.swift:616 品牌副行） |
| 2 | whitespace | **7.6** | 7.1 | 总览底部空纸换成"本地端点 / 分流解释器"两张 instrument 卡、规则表补了 footer；但支撑账页的两处行线在 1× 交付图里读不出来（§3.1） |
| 3 | visual_hierarchy | **7.6** | 7.6 | "代理已就绪，但系统流量还没经过它"告警条是本轮最好的层级改进；但总览仍三处"已停止"+ 两处启停入口，去广告"未加载"与四个开关全开并存 |
| 4 | color | **8.0** | 8.0 | 停=墨填充、起=朱红填充，语义对了；mint"使用中"仍是全 App 唯一填充状态药丸（ProfilesView.swift:274），暗色无本轮证据 |
| 5 | motion | **7.4** | 7.2 | 详情面板 `.move(.trailing)+.opacity` 0.18s 且带 reduceMotion（CaptureView.swift:108-110）；全局仍是 33 处动画 / 4 条曲线 / 无共享元素（§3.3） |
| 6 | micro_interaction | **7.4** | 7.2 | 详情 esc/×、行选中改中性底+4px 朱红胶囊、快捷键改行内 chip；但按钮仍无焦点环，且主按钮标签被挤成两行（§3.2） |
| 7 | responsive | **7.4** | 7.3 | 1040 下抓包详情改为右侧 56% 覆盖层，半空详情列的问题解决；但 900 宽与暗色无本轮构建证据，只能按单一宽度给分（§4） |
| 8 | originality | **8.5** | 8.2 | 双向地震仪第一次带数据交付：上实线/下虚线同 x 位置、峰值 22.2 KB/s、2px 朱红游标；"空白账页"+ 端点/解释器卡让"仪器"这个隐喻这轮才立住 |

---

## 3. 仍然 ≤ 7.6 的三条（可修 / 结构性取舍）

### 3.1 whitespace 7.6 — 账页语法在 1× 交付图里不存在 · **可修**

- 规则表：逐行线是 `0.5pt × TF.stroke.opacity(0.5)`（RulesView.swift:191）。实测 rules.png 的空白列 x 520–640、y 216–721，**没有任何一个像素低于 250**（面板底色 251）——9 行数据完全是靠 38px 行距和 ~380pt 的横向空当在分离。
- 抓包账页：`0.5pt × TF.stroke.opacity(0.35)`（CaptureView.swift:310-316）。实测只读出 3 条（y=314 / 385 / 456，均值 243），代码声明的 5 条里另外两条读不出来，y=456 到面板底还有约 290px 纯空。
- 这不是"空得难看"，是**想用极淡的线声明"这是一页账"，但线在交付分辨率下被吃掉了**。同一次提交里，去广告页的行分隔是 `(230,230,226)`，在 1× 下清晰可见（adblock.png y=319/382/440/498）——**同一个 App，两套可见性**。
- 修法：规则表逐行线与表头线、与去广告行线同源（1pt，TF.stroke 全量）；抓包账页同理。0.5pt × 低透明度在任何 1× 导出里都会消失。

### 3.2 micro_interaction 7.4 — 按钮的两处硬伤 · **可修**

- **无焦点环**：`TFPrimaryButtonStyle`（Theme.swift:251）/`TFGhostButtonStyle`（Theme.swift:273）没有 `@FocusState` 分支，而 `TFSwitch` 有（Theme.swift:343/365/372）。键盘 Tab 到主按钮时视觉上没有任何"我在这里"的提示，WCAG 2.4.7 不合规；这也让"墨/朱红"这套按钮语义在纯键盘操作下失效。
- **标签折行**：profiles.png 里"导入配置"被压成两行（"导入"/"配置"，12pt semibold，按钮高从 ~28 变 ~44）。原因是 ProfilesView.swift:107-119 的 label 没有 `.lineLimit(1)`/`.fixedSize()`，四个动作按钮在 370pt 卡内互相挤压，只有主按钮塌了——同行另外三枚仍是单行，反而是视觉焦点先坏。
- 修法：按钮样式加 `focused` 描边（复用 TFSwitch 的 2pt accent）；label 加 `.lineLimit(1)` + `.fixedSize(horizontal: true, vertical: false)`，或把四枚按钮拆成两行。

### 3.3 motion 7.4 — 动效是"有"而不是"一套语言" · **可修**

- 33 处动画 / 4 条曲线：`.easeOut` 25、`.snappy` 6、`.spring` 1、`.easeInOut` 1（grep 全量）。同类"出现"三个家族：页面切换 `easeOut(0.18)`（TouchFlowApp.swift:391）、指标数字 `snappy(0.28)`（DashboardView.swift:432）、详情面板 `easeOut(0.18)`（CaptureView.swift:110）。
- 无共享元素转场：列表行 → 详情面板是"面板从右侧推入"，被选中的行不做任何让位/形变/高亮延伸，空间关系是**声明**出来的（56% 宽度）而不是**演**出来的。
- `accessibilityReduceMotion` 只覆盖 6 个文件（Theme / Interactions / PrivacyView / Shared / AdBlockView / CaptureView）；页面切换（TouchFlowApp.swift:391）、指标数字（DashboardView.swift:432）、图例数值（DashboardView.swift:406）都不受控。
- 修法：定义 3 个语义时长（出现 0.18 / 数值 0.28 / 归属 0.24）+ 一个匹配几何（matchedGeometryEffect 把行内的 method chip 或 accent 胶囊带进面板头部）；reduceMotion 上提到一个 modifier 统一守住。

---

## 4. 证据边界（影响 responsive 得分，不计为缺陷）

- /tmp/tffinal2 混了两批构建：**18:21–18:23** 的 dark-dashboard / dark-capture / narrow-dashboard / narrow-capture / narrow-settings / ssh / nas / learn 早于 `历史提交`；**18:37–18:42** 的 dashboard / rules / adblock / capture / privacy / profiles / settings / work-* 才是本轮。
- 铁证：narrow-capture.png（18:22）里仍是本轮已经删掉的 7 行顶部骨架屏 + 底部空态条。
- 因此 responsive 只能用一个宽度（1040）给分（7.4），暗色本轮零样本；"900 宽 + 56% 覆盖层 + 暗色三件事"本轮均未验证。补拍 6 张（900 宽三张 + 暗色三张）即可回收 0.2–0.3，不需要改代码。

---

## 5. 上轮五条 · 对账

1. **永久骨架屏** → 已删 ✔。总览 RECENT 只剩一行说明，抓包变为面板顶部"暂无 HTTP 请求 + CTA + 空白账页"（但账页线不可见，见 §3.1）。
2. **隐私读数** → 已修 ✔。刻度标签 mono 10 全不透明；"—" 与 26pt 的 "0" 同字宽同基线，读数行不再断。
3. **规则表脱离账页** → 部分 △。footer（共 9 条 · DIRECT 8 · 代理 1 · 首次命中裁决）确实把面板底边锚住了；但逐行线在交付图里为 0，9 行之后仍有 ~175px 空账页。
4. **侧栏分组节奏** → 已修 ✔。四个组间距 43/43/44/43px，`groupIndex == 1 ? 6 : 18` 的补丁已删（TouchFlowApp.swift:509-518）。
5. **抓包 <820** → 已修 ✔。改为右侧 56% 覆盖层 + esc/×，1040 下可边看列表边看详情，行选中用中性底 + 朱红胶囊（900 宽未验证）。

---

## 6. 判定

**交付线 6.5 早已越过；获奖线 8.0 未到——均分 7.75 差 0.25，硬条款（任一维 ≥ 7.7）卡在 motion 7.4 / micro_interaction 7.4 / responsive 7.4。** 剩下的是"可见性"（线在交付分辨率下看不见）和"一致性"（按钮、动效、证据批号）两类收尾活，不是方向问题。

# TouchFlow · 视觉与交互规范（Editorial Instrument）

> 目标：macOS 原生网络工具，视觉参照 Awwwards / Webby 级工艺标准。方向不是通用 SaaS 渐变，
> 而是「克制的仪器感」：暖纸、墨色、发丝线、等宽数据、单一信号色。所有决定都以可读性与可信度为先。

## 1. 设计原则

1. **纸与墨**：界面底色是纸（暖灰白 / 近黑），内容用发丝线分区，不用漂浮卡片、投影或玻璃。
2. **一个信号色**：朱红 `accent` 只用于「主操作 / 选中 / 关键状态」。其余状态色（good / warn / danger）只出现在点、线、窄条和文字上，不做大面积填充。
3. **数字是主角**：所有指标用 SF Mono 等宽数字，标签用 8.5–10pt 全大写 mono，带 1.1–1.7 字距。数字不做逐块缩放，统一字号。
4. **一句话人话**：每页最多一处衬线（New York）斜体，用于解释当前状态的短句；其余一律 SF Pro。
5. **每屏一个填充主按钮**：其余动作用幽灵按钮（发丝描边）或纯文字操作，避免视觉竞价。
6. **图标恒定中性**：图标只为识别服务，不参与色彩语义。

## 2. Token

| Token | Light | Dark |
| --- | --- | --- |
| `bg` | `#F6F4EF` | `#0A0A0B` |
| `bgDeep` | `#EFEBE3` | `#050506` |
| `panel` | `#FCFBF8` | `#151517` |
| `panelSolid` | `#FFFFFF` | `#171719` |
| `panelRaised` | `#FFFFFF` | `#1F1F22` |
| `stroke` / `strokeStrong` | 墨色 10% / 17% | 白色 12% / 20% |
| `text` / `textSecondary` / `textTertiary` | `#16150F` / `#5F5C53` / `#6F6B60` | `#F3F1EA` / `#A6A39A` / `#87847B` |
| `accent` | `#C63A12` | `#FF7A4D` |
| `accentFill`（按钮底） | `#B83510` | `#C2410F` |
| `dangerFill`（停止类按钮） | `#B32636` | `#C0323F` |
| `mint` / `amber` / `violet` / `danger` | `#0C7A55` / `#8F5E07` / `#5446B8` / `#B32636` | `#35D19B` / `#E8B04A` / `#B0A3FF` / `#FF6B74` |

对比度（脚本实测，白字 / 正文）：
- 白字 on `accentFill`：#B83510 = 5.91:1，`#C2410F` = 5.18:1，`#B32636` = 6.02:1 → 均过 AA。
- 正文 `textTertiary`：light `#6F6B60` on `#FCFBF8` = 5.14:1；dark `#87847B` on `#151517` = 4.86:1 → 过 AA。

## 3. 字阶

| 用途 | 字体 / 字号 |
| --- | --- |
| 页面标题 | SF Pro 22 / semibold / tracking −0.6 |
| Hero 主数字（配置名） | SF Pro 34 / semibold / tracking −1.1 |
| 页面副标题 | SF Pro 12 / secondary |
| 区块标题 | SF Pro 14.5 / semibold / tracking −0.2 |
| 区块副标题 | SF Mono 10 / tertiary |
| 正文 | SF Pro 12（全 App 无 11pt 正文） |
| 强调 / 表内小标题 | SF Pro 13 |
| 说明 | SF Pro 12 / tertiary（同级字号，靠颜色分级） |
| 指标数字 | SF Mono 34（主）/ 21（从），仪表条统一 mono |
| 小标签 / 眉标 | SF Mono 10（分组标签 7–8.5）/ tracking 1.1–1.7 / uppercase 风格；数据值 SF Mono 12 |
| 一句人话 | New York（serif）italic 13–15 |

## 4. 组件

- **TFPanel（`.tfPanel(padding:)`）**：`panel` 底 + `stroke` 发丝边 + 10pt 圆角，无阴影。只在 `raised` 时用极浅阴影。
- **Instrument strip**：单块面板内若干指标，用 1×44 竖发丝线分隔；标签 mono 9 全大写，数字 mono 26。
- **TFPrimaryButtonStyle / TFGhostButtonStyle**：填充朱红（白字、白 14% 内描边、按压缩放 0.985）；幽灵为 `Color.primary.opacity(0.045)` 底 + 12% 描边（语义色，暗色下自动正确）。两套样式都包 `TFButtonFocusRing`：读到最近可聚焦祖先的 `\.isFocused`，在按钮外 3pt 处描 2pt 朱红环（corner 10），键盘焦点因此对所有按钮自动可见，无需逐处接 `@FocusState`。
- **TFSwitch**：34×18 胶囊（可传 width），on = accent 填充，off = `text` 22%，白色 knob + 极轻投影；弹簧 0.26 / 0.82；`.focusEffectDisabled()` 去掉系统蓝环。
- **TFLineField / TFSelectField**：下划线式输入；聚焦时底线变 accent 1.5pt（0.14s 动画），选择器用 popover 列表（选中项 semibold + accent 勾）。
- **TFSearchField**：圆角 7 的浅墨底，聚焦时不做整框描边，只在底部出现 1.5pt accent 下划线（与输入框同一套焦点语言）。
- **流量地震仪（签名器件）**：总览仪表条下方 30pt 条带，Canvas 双通道 —— 下载画在基准线上方（墨色实线），上传画在下方（tertiary 虚线），右端朱红游标 + 端点圆点；左侧 216pt 图例给实时速率，图下轴标「60 秒前 · 峰值 X/s · 现在」。纵轴用共享 `rateCeiling`（每秒衰减 6%）+ sqrt 映射，避免单点尖峰把整条曲线压平。空闲时只有基准线与零位游标，页面在「什么都没发生」时也讲真话。
- **TFCopyButton**：复制后 1.1s 变 mint 勾，用于端点、终端输出、导入报告。
- **TFAppear**：入场 = opacity + 8pt 上移，0.38s，支持 delay；`accessibilityReduceMotion` 时直接出现。
- **状态表达**：状态点 6pt + 文字；危险/成功不做整块底色，只在点线边条上着色。
- **TFRow 选中**：中性墨色 5.5% 底 + strokeStrong 发丝描边 + 左侧 2×15 accent 胶囊，不再用浅朱红底（那读作错误或待删除）。
- **空账页**：列表为空时保留列头与说明，下面只画 5 条极浅横线（发丝 35%），不画占位胶囊——「还没写」不能长得像「正在加载」。
- **表尾合计**：规则表底部 mono 10「共 N 条 · DIRECT n · 代理 n …… 首次命中裁决」，给长表一个收束点。

## 5. 布局与响应式

- 导航按域分组而不是平铺十页：**工作区**（总览）/ **代理**（分流规则、去广告）/ **观测**（抓包）/ **工具**（SSH、NAS、智能学习）/ **系统**（隐私、配置、设置）。分组标签 mono 8.5 / tracking 1.7 / tertiary，行间距靠 18pt 上留白而非卡片分割；窄窗折叠时退化为 1px 分隔线。快捷键仍按原十页顺序 ⌘1–⌘0。
- 窗口最小 900×640（原 1040×700），默认 1240×820。
- `geo.width < 960` → 侧栏折叠为 68pt 图标栏（保留选中左侧 2×14 accent 胶囊 + tooltip）；页面头部右侧三个控件合并为一个 30pt 胶囊工具栏。
- 页面内边距 32（左右）/ 16（上）/ 24（下）。
- 抓包：内容宽 ≥820 时分栏（列表 / 详情，各 `minWidth 336`）；<820 时只留列表，选中请求后从右侧推出 56% 宽的检视层（顶部「请求详情 / REQUEST」+ esc 提示 + 关闭按钮，esc 或关闭收起）。1040 与 900 宽均无溢出，且没有「空详情栏占半屏」。
- 设置页按**窗口宽度**而非内容宽度切栏：`windowWidth ≥ 1000` 两列（左 代理端口/DNS，右 启动与常驻/抓包与解密/高级）；`< 1000` 单列，卡片区限宽 620pt 居中，避免 900 宽时两列把端口值、DNS 上游挤成中间截断。窗口宽度经根视图 `GeometryReader` 写入 `EnvironmentValues.tfWindowWidth`（macOS 没有 compact size class）。
- 去广告、隐私在 900 宽下仍为两列，字段标签固定 88pt、值域最大 228pt 并做尾部截断。

## 6. 动效与微交互

动效只有一套令牌（`TFMotion`，定义在 Theme.swift），全 App 不再出现散落的裸 `.animation(.easeOut(duration:…))`：

| Token | 曲线 | 用途 |
| --- | --- | --- |
| `TFMotion.press` | easeOut 0.12 | 按压、筛选切换、复制勾选 |
| `TFMotion.quick` | easeOut 0.14 | 焦点下划线、hover、局部状态 |
| `TFMotion.standard` | easeOut 0.18 | 页面切换、抽屉、命令面板 |
| `TFMotion.emphasized` | snappy 0.28 | 指标变化、检视层推出 |
| `TFMotion.spring` | spring 0.26 / 0.82 | 开关滑块 |
| `TFMotion.enter` | easeOut 0.38 (+delay) | 首屏错峰入场 |

| 场景 | 行为 |
| --- | --- |
| 页面切换 | ZStack + `.id(section)`，opacity + 6pt offset（standard） |
| 指标变化 | `.contentTransition(.numericText())` + emphasized |
| 按钮 | 按下 0.985 缩放 + 0.86 透明（press）；键盘焦点描 2pt 朱红环 |
| 复制 | 图标切换 1.1s 后复原 |
| 抓包新行 | 左侧 2×15 accent 条 1.2s 淡出（不整体动画，避免列表跳动） |
| 入场 | TFAppear 阶梯 delay 0 / 0.04 / 0.08 / 0.12 / 0.16 |
| 减少动态 | 声明式用 `.tfAnimation(token, value:)`（内部读 `accessibilityReduceMotion` 置 nil）；命令式用 `TFMotion.run(token) { … }`（打开时直接落位）；持续动画（状态点脉冲、不确定进度条）单独 guard。覆盖所有 App 层动画。 |

## 7. 页面清单（10 页）

1. **总览**：hero（配置名 + 一句状态 + 主操作 + 系统代理/解密开关）→ 五格仪表条（1 主 4 从）+ 双向流量地震仪（下载实线 / 上传虚线）→ 最近连接（首屏可见，空态为 skeleton）→ 端点/解释器双栏；仅失败或已启动未接管时插入引导条。
2. **分流规则**：表头（# / 类型 / 匹配值 / 策略）与行像素对齐；右栏为无底「策略组 / 出站 / 规则集 / 快捷键」rail 区。
3. **去广告**：三格仪表条 + 4 行开关（发丝线分隔）+ 拦截测试 + 过滤列表/白名单双栏。
4. **抓包**：工具栏（搜索 / 暂停 / HTTPS 解密 / 导出 HAR / 清空）+ 状态筛选行 + 圆角列表；≥820 宽右栏详情，<820 宽改为右侧检视层；空态是列头 + 说明 + CTA + 空白横线账页。
5. **SSH**：下划线字段 + 密码/密钥下划线页签 + 主按钮「连接」+ 终端窗格（mono、标题栏显示 ssh target 与 IDLE/连接态）。
6. **NAS**：发现（扫描主按钮）/ 连接共享（空态带动作）/ 挂载说明。
7. **智能学习**：粘贴区 + 截图 dropzone 双栏，空文本时主按钮降级为幽灵，工作方式 01/02/03。
8. **隐私**：100 分制仪表（34pt 数字 + 阈值刻度尺）、三格计数器、加固清单、发现列表（空态带「去抓包」）；**无流量样本时不打分**，显示「无样本」+ 说明，计数器显示「—」。
9. **配置**：当前配置 hero（导入 / 粘贴订阅 / 导出菜单 / 打开目录）+ 全部配置列表 + 导入来源矩阵。
10. **设置**：代理端口 / 启动与常驻 / DNS / 抓包与解密 四卡，下划线字段与自定义选择器，未保存修改有跨页提示。

## 8. 验证

- 构建：`./scripts/build-app.sh debug` 通过；`swift build --build-tests` 无 error / warning。
- 测试：`swift test` 122 条全绿（Core 1 / Policy 41 / Net 69 / Integrations 11）。
- 端到端：`./scripts/smoke.sh` 7/7。
- 截图核对（1040×752，浅色 / 深色 / 900 宽三套，2026-11-05 最新一轮存 `/tmp/tffinal2/`）：10 页布局、分组导航、双向流量图、表头对齐、暗色 token、窄窗折叠侧栏均人工目视通过。
- 无障碍：reduce-motion 全量生效（声明式 `.tfAnimation` + 命令式 `TFMotion.run` 自动降级，脉冲/进度 loop 单独 guard）；按钮键盘焦点环覆盖两套按钮样式；开关有 `accessibilityRepresentation(Toggle)` 与中文 value；隐私评分刻度尺有完整朗读标签；对比度实测均过 AA。

## 8.1 评审轨迹

| 轮次 | 加权 | 结论 |
| --- | --- | --- |
| 初版（v1.1 交付态） | 4.1 / 10 | 正确但匿名 |
| 第二轮（Editorial Instrument 落地） | 6.7 / 10 | 可交付、不到获奖线 |
| 第三轮（字号收敛 / 首屏重排 / 墨阶策略 / 隐私诚实 / 地震仪） | 7.20 / 10 | 未到 8.0；Color 与 Originality 已跨线（8.0），余下为执行收尾 |
| 第三轮收尾（抓单单栏 / 隐私读数位 / 类型去 pill / 地震仪纵轴稳定 / 去广告真数字） | 未再评分 | 见 `docs/design-critique-final.md` 的 5 条待办已完成 5 条 |
| 第四轮（借鉴 Surge/OpenSurge：分组导航、双向流量图、mono 字阶收敛到 10/12） | 7.48 / 10 | 比第三轮 +0.28；Color 8.0 / Originality 8.2 已过线，Whitespace 7.1 最短 |
| 第五轮（去永久骨架屏改空白账页、隐私刻度可读、规则逐行线与表尾合计、窄窗详情检视层、字号收敛到 9/10/12/13/22/34） | 7.75 / 10 | +0.27；Typo 8.1 / Color 8.0 / Originality 8.5 过线，Motion·Micro·Responsive 7.4 未过 7.7 硬条款 |
| 第五轮收尾（账页线改 1pt 全量 stroke 确保 1× 可见；配置页四个头部按钮固定单行；900/暗色截图补拍） | 未再评分 | 见 `docs/design-critique-round5.md`；剩余为动效语言统一与按钮焦点环（结构性投入，未做） |
| 第六轮（动效收敛为 `TFMotion` 六条令牌 + 全量 reduceMotion；按钮焦点环；设置页 <1000 单列 620pt） | 待复评 | 直接消解第五轮 Motion 7.4 / Micro 7.4 / Responsive 7.4 三条短板：33 处裸动画归零为令牌调用，焦点态对所有按钮可见，900 宽不再挤压 |

## 9. 已知取舍

- 规则引擎仍为线性扫描（10 万规则 28ms），后缀 Trie 未做——视觉层不隐藏此事实，性能文档见 `docs/audit-runtime.md`。
- 导入报告、Onboarding、菜单栏面板沿用同一 token，但未做窄窗专项适配（它们不是常驻主界面）。

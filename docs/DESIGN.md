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
| 正文 | SF Pro 12.5–13（全 App 无 11pt 正文） |
| 说明 | SF Pro 11 / tertiary |
| 指标数字 | SF Mono 34（主）/ 21（从），仪表条统一 mono |
| 小标签 / 眉标 | SF Mono 8.5–10 / tracking 1.1–1.7 / uppercase 风格 |
| 一句人话 | New York（serif）italic 13–15 |

## 4. 组件

- **TFPanel（`.tfPanel(padding:)`）**：`panel` 底 + `stroke` 发丝边 + 10pt 圆角，无阴影。只在 `raised` 时用极浅阴影。
- **Instrument strip**：单块面板内若干指标，用 1×44 竖发丝线分隔；标签 mono 9 全大写，数字 mono 26。
- **TFPrimaryButtonStyle / TFGhostButtonStyle**：填充朱红（白字、白 14% 内描边、按压缩放 0.985）；幽灵为 `Color.primary.opacity(0.045)` 底 + 12% 描边（语义色，暗色下自动正确）。
- **TFSwitch**：34×18 胶囊（可传 width），on = accent 填充，off = `text` 22%，白色 knob + 极轻投影；弹簧 0.26 / 0.82；`.focusEffectDisabled()` 去掉系统蓝环。
- **TFLineField / TFSelectField**：下划线式输入；聚焦时底线变 accent 1.5pt（0.14s 动画），选择器用 popover 列表（选中项 semibold + accent 勾）。
- **TFSearchField**：圆角 7 的浅墨底，聚焦时不做整框描边，只在底部出现 1.5pt accent 下划线（与输入框同一套焦点语言）。
- **流量地震仪（签名器件）**：总览仪表条下方 30pt 条带，Canvas 画 1px 基准线 + 60 个采样点的墨色折线 + 右端朱红游标；空闲时只有基准线与零位游标，页面因此在「什么都没发生」时也讲真话。
- **TFCopyButton**：复制后 1.1s 变 mint 勾，用于端点、终端输出、导入报告。
- **TFAppear**：入场 = opacity + 8pt 上移，0.38s，支持 delay；`accessibilityReduceMotion` 时直接出现。
- **状态表达**：状态点 6pt + 文字；危险/成功不做整块底色，只在点线边条上着色。

## 5. 布局与响应式

- 窗口最小 900×640（原 1040×700），默认 1240×820。
- `geo.width < 960` → 侧栏折叠为 68pt 图标栏（保留选中左侧 2×14 accent 胶囊 + tooltip）；页面头部右侧三个控件合并为一个 30pt 胶囊工具栏。
- 页面内边距 32（左右）/ 16（上）/ 24（下）。抓包两栏 `minWidth 336`，1040 与 900 宽均无溢出。
- 所有双列页面（设置、去广告、隐私）在 900 宽下保持两列不挤压，字段标签固定 88pt、值域最大 228pt 并做中段截断。

## 6. 动效与微交互

| 场景 | 行为 |
| --- | --- |
| 页面切换 | ZStack + `.id(section)`，opacity + 6pt offset，0.18s easeOut |
| 指标变化 | `.contentTransition(.numericText())` + snappy 0.28 |
| 开关 | 弹簧 0.26 / 0.82 |
| 按钮 | 按下 0.985 缩放 + 0.86 透明（0.12s） |
| 复制 | 图标切换 1.1s 后复原 |
| 抓包新行 | 左侧 2×15 accent 条 1.2s 淡出（不整体动画，避免列表跳动） |
| 入场 | TFAppear 阶梯 delay 0 / 0.04 / 0.08 / 0.12 / 0.16 |
| 减少动态 | `accessibilityReduceMotion` 全局生效（TFAppear / 数值过渡 / 脉冲点） |

## 7. 页面清单（10 页）

1. **总览**：hero（配置名 + 一句状态 + 主操作 + 系统代理/解密开关）→ 五格仪表条（1 主 4 从）+ 流量地震仪 → 最近连接（首屏可见，空态为 skeleton）→ 端点/解释器双栏；仅失败或已启动未接管时插入引导条。
2. **分流规则**：表头（# / 类型 / 匹配值 / 策略）与行像素对齐；右栏为无底「策略组 / 出站 / 规则集 / 快捷键」rail 区。
3. **去广告**：三格仪表条 + 4 行开关（发丝线分隔）+ 拦截测试 + 过滤列表/白名单双栏。
4. **抓包**：工具栏（搜索 / 暂停 / HTTPS 解密 / 导出 HAR / 清空）+ 状态筛选行 + 圆角两栏（列表 / 详情）。
5. **SSH**：下划线字段 + 密码/密钥下划线页签 + 主按钮「连接」+ 终端窗格（mono、标题栏显示 ssh target 与 IDLE/连接态）。
6. **NAS**：发现（扫描主按钮）/ 连接共享（空态带动作）/ 挂载说明。
7. **智能学习**：粘贴区 + 截图 dropzone 双栏，空文本时主按钮降级为幽灵，工作方式 01/02/03。
8. **隐私**：100 分制仪表（48pt 数字 + 阈值刻度尺）、三格计数器、加固清单、发现列表（空态带「去抓包」）。
9. **配置**：当前配置 hero（导入 / 粘贴订阅 / 导出菜单 / 打开目录）+ 全部配置列表 + 导入来源矩阵。
10. **设置**：代理端口 / 启动与常驻 / DNS / 抓包与解密 四卡，下划线字段与自定义选择器，未保存修改有跨页提示。

## 8. 验证

- 构建：`./scripts/build-app.sh debug` 通过；`swift build --build-tests` 无 error / warning。
- 测试：`swift test` 122 条全绿（Core 1 / Policy 41 / Net 69 / Integrations 11）。
- 端到端：`./scripts/smoke.sh` 7/7。
- 截图核对（1040×752，浅色 / 深色 / 900 宽三套）：10 页布局、表头对齐、暗色 token、窄窗折叠侧栏均人工目视通过。
- 无障碍：reduce-motion 全量生效；开关有 `accessibilityRepresentation(Toggle)` 与中文 value；隐私评分刻度尺有完整朗读标签；对比度实测均过 AA。

## 8.1 评审轨迹

| 轮次 | 加权 | 结论 |
| --- | --- | --- |
| 初版（v1.1 交付态） | 4.1 / 10 | 正确但匿名 |
| 第二轮（Editorial Instrument 落地） | 6.7 / 10 | 可交付、不到获奖线 |
| 第三轮（字号收敛 / 首屏重排 / 墨阶策略 / 隐私诚实 / 地震仪） | 7.20 / 10 | 未到 8.0；Color 与 Originality 已跨线（8.0），余下为执行收尾 |
| 第三轮收尾（抓单单栏 / 隐私读数位 / 类型去 pill / 地震仪纵轴稳定 / 去广告真数字） | 未再评分 | 见 `docs/design-critique-final.md` 的 5 条待办已完成 5 条 |

## 9. 已知取舍

- 规则引擎仍为线性扫描（10 万规则 28ms），后缀 Trie 未做——视觉层不隐藏此事实，性能文档见 `docs/audit-runtime.md`。
- 导入报告、Onboarding、菜单栏面板沿用同一 token，但未做窄窗专项适配（它们不是常驻主界面）。

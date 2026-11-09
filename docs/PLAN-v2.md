# Leapin v1.1 提升计划与交付报告（五项）

> 来源：用户清单（2026-11-05）——再做一次完整的交互提升 / 最后做一次入口优化 / 把所有格式支持做一下提升 / 做一次性能优化 / 做一次稳定性提升。
> 约束：不新增 SPM 依赖（本机无 github.com）；只用 Foundation / Network / Security / Vision / CryptoKit / AppKit / SwiftUI；不改 Package.swift 的 target 结构；所有改动必须 `swift build` 零 error、`swift test` 全绿。
> 状态：**五项全部完成**。验收数字见 `docs/VERIFICATION.md`（v1.1），审计细节见 `docs/audit-ui.md` / `docs/audit-formats.md` / `docs/audit-runtime.md`。

## 执行顺序（实际）

P1 交互 + P2 入口（同属 App 层，lead 串行，避免并行改同一批文件）
→ P3 格式（format-auditor 并行，写 `Sources/LeapinPolicy/Format/**`、`ProfileStore`）
→ P4 性能 + P5 稳定性（runtime-auditor 串行，同一批网络文件）
→ lead 收口：导出/远程订阅补齐、App 接线、全量验证、文档。

## P1 交互提升 ✅

- [x] `⌘1…⌘0` 切换 10 个页签；`⌘K` 命令面板（20+ 项：页签 / 动作 / 6 种格式导出 / 订阅导入，模糊搜索 + 分组 + 快捷键角标）
- [x] `⌘F` 聚焦当前页搜索；面板 `↑/↓` 移动、`↩` 执行、`esc` 关闭（`CommandPalette.swift:134-136` 的 `onKeyPress`）
- [x] 交互原语：`LPToast`（success/warning/error + 动作按钮）、`LPConfirmDialog`（`Interactions.swift:210`，破坏性操作二次确认）、`LPSwitch`（自绘，含空格/回车切换与焦点环）、`LPChip`（单行不换行）
- [x] 规则页：搜索 + 类型/策略过滤计数、行选择、右键菜单、新增规则表单实时校验、`⌘R` 重载
- [x] 抓包页：暂停/继续、状态筛选拆独立行（`filterRow`）+ 搜索 210pt、`⌘F` 聚焦、复制为 cURL、清空确认、HAR 导出
- [x] 空态带 CTA、长操作有 ProgressView 与禁用态、失败 toast 带可读原因
- [x] 减弱动态效果（`LPMotion` 读取 `NSWorkspace.accessibilityDisplayShouldReduceMotion`）、1040×700 无裁切（截图回归）
- [x] 11 处 `accessibilityLabel`（面板入口、toast、清空/复制按钮等）；`LPSwitch` 支持键盘聚焦

## P2 入口优化 ✅

- [x] 首启引导（3 步 + 跳过，`lp.onboarded` 记忆，菜单「重新显示上手引导」可重放）
- [x] 菜单栏面板：启停代理、系统代理、实时计数（连接/请求/拦截/流量）、复制端点、直达页签、退出
- [x] URL scheme `leapin://section/<id>` 深链直达；Dock 菜单条目
- [x] 全局快捷键 `⌘⇧Space` 从任意 App 唤起命令面板（`Platform.swift:30`）
- [x] 首页建议与「启动后优先打开的页签」偏好持久化（`startSection`）；登录时自动启动（`LaunchAtLogin` + 设置页开关）
- [x] 总览页「下一步建议」单步 CTA（未启动 / 未开系统代理 / 未装 CA / 未开去广告）
- [x] 配置页「粘贴订阅链接」一键导入远程订阅（剪贴板 → 下载 → 导入 → 报告）

## P3 格式支持提升 ✅

- [x] 导入：Clash YAML（proxy-groups 参数、rule-providers、nameserver-policy、fake-ip-filter、BOM）、Surge conf、Leapin JSON、base64 订阅（ss SIP002 / 旧式 ss / trojan / vless / vmess / hysteria2）、hosts、ABP、纯规则文本、rule-set（yaml / list）
- [x] 导出：Clash / Surge / JSON / **hosts** / **ABP** / **Clash rule-set**（后三项本轮补齐，见 `ProfileExporter` 扩展）；HAR 保持既有契约
- [x] 远程 `http(s)://` 订阅：`LeapinEngine.importRemoteProfile`（20s 超时、只允许 http/https、UTF-8→isoLatin1 兜底、空体/非 2xx 可读报错）
- [x] 解析诊断不静默丢：`ImportReport` / `ImportIssue`（kind + 行号 + 原文 + display），导入后 toast →「导入报告」sheet，可复制
- [x] 未知出站协议保留 `rawType` 与额外字段，导出原样写回（vmess/vless/hysteria/hysteria2/tuic/wireguard/snell/unsupported）
- [x] 往返等价：Clash→Profile→Clash→Profile、Surge 同理（`FormatTests` 20 条）；导出方向 `ExportFormatTests` 5 条（只搬 REJECT、后缀不误拦、hosts 每行两字段）
- [x] 大文件：5 万行规则导入 216ms（-O）/ 459ms（-Onone）
- [x] `leapin` 支持 `--input-format` 别名（`ProfileFormat.cliName`）与 `--help`

## P4 性能优化 ✅

- [x] `scripts/bench.sh` 基线：规则 decide（0/1k/10k/100k）、AdBlock（10 万条）、DNS 冷热、100 并发短连接与 FD
- [x] `AdBlockEngine` cosmetic 索引：2 万条从 O(n²) 卡死 → 81ms 建索引，匹配走 suffixKeys
- [x] `RuleEngine.match()` 免 trace 快路径（`decide` 由 `match` 组合），规则 0/1k/10k/100k 装载 + 判定 21/26/89/725ms
- [x] 连接表 / 流事件 / 抓包存储硬上限与淘汰；UI 16ms 批量 flush，不再单条 flow 全量重绘
- [x] 数字入 `docs/VERIFICATION.md §5`
- [ ] `RuleEngine` 域名后缀 Trie（POL-02）：**未做**，需重排「最小下标优先」裁决顺序，属结构性改动；10 万规则下单次 28ms 仍可接受（真实配置 < 2k 条 → 282µs）

## P5 稳定性提升 ✅

- [x] `fatalError` / `try!` / `as!` 在非测试代码中归零
- [x] 端口冲突（退出码 1 + 可读文案）、上游不可达（502/000，进程存活）、TLS 失败（不累积 FD）、DNS 超时、证书生成失败均有可读错误
- [x] 所有 socket/文件句柄在成功/失败/取消路径关闭（`BytePump` 用 `withTaskCancellationHandler`；`clientUpstreams` 在 `stop()` 关闭）
- [x] 代理停止 / App 退出先回滚系统代理；系统代理指向实际 `listeningPort`；`enable` 失败自动 `try? disable()`
- [x] `scripts/stress.sh`：3 轮 × 500 并发 + 随机中断 + 端口冲突 + 上游不可达 + TLS 失败，PASS=22 FAIL=0，FD 14→14，RSS 28.7–36.0MB
- [x] 新增失败路径测试；`swift test` 122 tests / 0 failure

## 验证命令

```bash
swift build --build-tests
swift test                  # 122 tests, 0 failures
./scripts/build-app.sh debug
./scripts/smoke.sh          # 7/7
./scripts/bench.sh
./scripts/stress.sh         # PASS=22 FAIL=0
```

## 仍未验证（诚实清单）

HTTPS MITM 真机装 CA 点击验证、真实 SSH 远程登录、真实 NAS 挂载、allowLAN 多设备、数小时长时间运行、PROCESS-NAME 真实进程分流。

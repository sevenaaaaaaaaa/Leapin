# LeapinIntegrations 交付说明

模块：`Sources/LeapinIntegrations/`（依赖 `LeapinCore`，无新增 SPM 依赖）
测试：`Tests/LeapinIntegrationsTests/PlaceholderTests.swift`（10 个用例）
公共 API：与 `docs/ARCHITECTURE.md` 第 3 节 `LeapinIntegrations` 段逐字一致；Runtime / App / leapin 已按同一份签名编译通过。

```
swift build --target LeapinIntegrations   # Build complete!
swift test --filter LeapinIntegrationsTests
# Executed 11 tests, with 0 failures (0 unexpected) in 0.690 (0.691) seconds

swift test          # 整包：Core/Policy 通过；LeapinNetTests 当前被本模块之外的
                    # CaptureTests 失败+挂起阻塞（CaptureTests.swift:26 CA 解析断言），
                    # 与本模块无关，未能跑完整包汇总
```

文件布局：

| 路径 | 内容 |
| --- | --- |
| `Support/CommandRunner.swift` | 外部命令统一执行器（超时 / stderr 捕获 / 错误映射） |
| `SSH/SSHSession.swift` | `actor SSHSession`、askpass 临时脚本、进程与管道生命周期 |
| `NAS/NASDiscovery.swift` | `NASDevice`、`_smb/_afpovertcp/_nfs/_http` Bonjour 浏览 |
| `NAS/NASMounter.swift` | `openInFinder` / `mountSMB` / `unmount` / `revealInFinder` |
| `Learn/LearnedApp.swift` | `LearnedApp`、`OCRResult`、`RuleSuggestion` |
| `Learn/AppCatalog.swift` | 内置 55 个应用/服务目录 |
| `Learn/AppListParser.swift` | 纯文本 / CSV / Markdown 表格 / JSON 列表解析 |
| `Learn/ScreenshotOCR.swift` | Vision `VNRecognizeTextRequest` OCR |
| `Learn/RuleSuggester.swift` | 域名后缀规则建议（去重 / 排序 / 上限 200） |
| `Privacy/TrackerCatalog.swift` | 74 个跟踪器域名 + 分类 / 严重度 |
| `Privacy/PrivacyAudit.swift` | 命中统计、按应用聚合、0–100 评分 |
| `System/SystemProxy.swift` | `networksetup` 代理读取与开关 |

## 1. SSH（已实现，含限制）

真实实现，未使用占位或假数据：

- 命令行：`/usr/bin/ssh -tt -p <port> -o ServerAliveInterval=15 -o ConnectTimeout=10 <hostKeyArgs> [-i <key> -o IdentitiesOnly=yes] user@host`。
- `knownHosts` 支持策略字符串 `accept-new` / `yes` / `no` / `ask`（原样传给 `StrictHostKeyChecking`），也支持文件路径（转换为 `-o UserKnownHostsFile=<path> -o StrictHostKeyChecking=yes`）；传入空串时默认 `accept-new`。
- 密码认证：在 0700 临时目录写入 0600 `askpass.sh`，内容为
  `#!/bin/sh` + `printf '%s\n' "$LEAPIN_SSH_PASSWORD"`；密码只通过 `Process.environment` 的 `LEAPIN_SSH_PASSWORD` 传递，**从不进入 argv、不写日志**；同时设置 `SSH_ASKPASS`、`SSH_ASKPASS_REQUIRE=force`、`DISPLAY=:0`。会话结束（`disconnect()`、连接失败、`deinit`）都会删除脚本与临时目录，失败路径也有测试断言无残留。
- stdout 与 stderr 合并到同一个 `Pipe`，`readabilityHandler` 解码 UTF-8 后回调 `outputHandler`（在私有串行队列调用，UI 需自行切主线程）。ANSI 颜色默认保留，另提供 `SSHSession.stripANSI(_:)` 供需要纯文本的调用方使用。
- 连接成功的判定：首包到达，或 3 秒后进程仍存活；进程提前退出则抛 `LeapinError.connectionFailed`，消息带 stderr 尾部（最多 600 字符）。`ssh` 不存在时抛 `unsupported`。
- `write` 原样写入 stdin，不自动补换行（App 自己拼 `\n`）；未连接时写日志后静默返回。
- `resize` 做了 `TIOCSWINSZ` 最佳努力调用，但 `Process` 给的是管道而不是 pty master，所以实际是 no-op（远端的列宽不会跟随窗口变化）。这是本实现已知的主要限制，注释已说明；上远程 `vim`/`top` 会出现宽度不自适应。

未实现：SFTP 文件传输、端口转发开关、主机指纹展示/确认流程、多路复用（`ControlMaster`）、把 stderr 与 stdout 分流展示。

## 2. NAS 发现与挂载

发现（已实现）：

- 同时浏览 `_smb._tcp`、`_afpovertcp._tcp`、`_nfs._tcp`、`_http._tcp`（`NWBrowser` + `.bonjour(type:domain:"local.")`，`NWParameters.tcp`）。
- 解 Bonjour 转义（`\032` 十进制 → 空格、`\.` → 字面点），实例名转主机名时把空格换成 `-` 并补 `.local`；默认端口 445 / 548 / 2049 / 80。
- 按小写 host 去重，同一台机器广播多个服务时优先保留 `_smb._tcp`；结果按名称排序后回调。`stop()` 会 cancel 所有 browser 并清空缓存。
- 回调在私有串行队列执行（`NASView` 自己 hop 到主 actor）。

挂载（已实现）：

- `openInFinder(host:share:)`：拼 `smb://host/share` 交给 `NSWorkspace.open`，由 Finder/Keychain 处理凭据，**不经手密码**，最安全；Finder 拒绝时抛 `connectionFailed`。
- `mountSMB(host:share:user:password:)`：挂载点 `~/Volumes/<share>`（自动创建），写 0600 临时脚本，脚本用环境变量 `LEAPIN_SMB_USER` / `LEAPIN_SMB_PASSWORD` 拼接 `mount_smbfs` 的 URL，20 秒超时；成功后用 `/sbin/mount` 复核该路径确实已挂载，返回挂载 URL；失败时把密码（含百分号编码形式）从错误文本里抹掉再抛出。
- **已知风险（写进代码注释）**：`mount_smbfs` 只接受 URL 里的密码，因此密码最终会出现在 `mount_smbfs` 自己的 argv 中，可被同用户进程短暂读到；我们的 `Process.arguments` 与日志里没有密码，脚本在 `defer` 中删除。要彻底避免只能走 Finder 那条路。
- 额外提供 `unmount(_:)`（`/sbin/umount`）与 `revealInFinder(_:)`（Finder 中显示卷），非契约必需但 UI 有用。

未实现：NAS 型号/容量识别（未解析 Bonjour TXT 记录，`model` 恒为 nil）、AFP/NFS 的实际挂载（只发现不挂载）、凭据记住到 Keychain（由 UI 的 `Keychain` 负责）。

## 3. 学习（App 目录 / 解析 / OCR / 规则建议）

- `AppCatalog.builtin`：55 条，含微信、QQ、淘宝、天猫、支付宝、抖音、小红书、B 站、网易云、微博、知乎、京东、美团、饿了么、百度、百度网盘、高德、钉钉、飞书、腾讯视频、爱奇艺、优酷、Telegram、WhatsApp、Instagram、X、Discord、Slack、Zoom、Line、Spotify、YouTube、Netflix、Apple Music、Twitch、GitHub、Notion、Steam、Docker Hub、npm、PyPI、ChatGPT、Claude、Gemini、Figma、Dropbox、Google Drive、Gmail、Outlook、Microsoft Teams、iCloud、Google、Amazon、Wikipedia。域名均为厂商真实运营域名；共享域名（如 `163.com`）标注在对应条目，不编造。少数 App 给了真实 bundle id（微信 / QQ / Slack / Discord / Spotify），其余留空而不是猜。
- `AppListParser.parse(text:)`：支持纯文本逐行、CSV（`,` `;` `\t`）、Markdown 列表与表格（跳过 `| --- |` 分隔行与表头词）、JSON 数组（字符串元素或 `{name, domains, bundleID}` 对象，也接受 `{apps:[...]}` 包裹）。域名支持带 `https://` 的 URL、`www.` 前缀、去尾部点；拒绝 IP、无 TLD、含空格的 token。有域名 → 直接建条（`source="user"`，若命中目录则合并目录域名）；无域名 → 目录模糊匹配（精确名、别名表如 wechat→微信、bundle id、双向包含）；仍匹配不到 → 保留 name、空 domains、`source="user"`。同一条目按名称去重合并域名。
- `ScreenshotOCR`：`VNRecognizeTextRequest`，`.accurate`、`recognitionLanguages=["zh-Hans","en-US"]`、`usesLanguageCorrection=true`；从 `URL` 或 `CGImage` 识别，按 Vision 坐标（左下原点，`midY` 降序 + `minX` 升序）还原阅读顺序，返回全文（`\n` 连接）、逐行文本、top candidate 置信度均值。无图像预处理（放大/二值化），低分辨率截图可能识别率一般。
- `RuleSuggester.suggest(apps:flows:catalog:)`：只产出 `DOMAIN-SUFFIX` 规则，`policy` 默认 `PROXY`。可信度：用户/识别提供的域名 0.85（OCR 来源 0.78）、目录域名 0.75、目录域名被流量证实 0.92、流量中源应用与域名同时命中 0.90、仅流量无归属 0.60；统一 clamp 到 0.50–0.95。理由为中文（例如「抓包中出现 3 次：cdn.douyin.com → 抖音」）。按域名去重（保留最高可信度）、按 confidence 降序（同分短域名优先）、最多 200 条。过滤 IP、`.local`/`.lan`/`.arpa`/`localhost`。
- 未实现：解析截图里的图标/包名、按进程路径反查 `sourceApp`（用的是 `FlowEvent.sourceApp`）、规则批量冲突检测。

## 4. 隐私

- `TrackerCatalog`：74 个真实域名，覆盖 Google Analytics / GTM / DoubleClick / AdMob(app-measurement)、Meta pixel、X、LinkedIn、TikTok、Pinterest、Reddit 广告、AppsFlyer、Adjust、Branch、Kochava、Amplitude、Mixpanel、Segment、Hotjar、FullStory、Sentry、Bugsnag、NewRelic、Datadog、Bugly、Criteo、Taboola、Outbrain、Moat、AppNexus、Rubicon、PubMatic、OpenX、Casale、TradeDesk(adsrvr)、BidSwitch、Smart、Comscore、Quantcast、InMobi、AppLovin、Unity Ads、ironSource、Vungle、Chartboost、Mintegral、Pangle，以及国内友盟、CNZZ、百度统计(`hm.baidu.com`)、百度联盟(`pos.baidu.com`)、TalkingData、GrowingIO、神策、个推、极光、51.LA。分类：广告 / 分析 / 归因 / 崩溃上报 / 数据代理；严重度 1–3。
- `PrivacyAudit.audit(flows:trackerDomains:)`：对 `FlowEvent.host` 做后缀匹配（最长后缀优先，`ads.doubleclick.net` → `doubleclick.net`），按 `(app, tracker域名)` 去重成 `PrivacyFinding`，`app` 取 `flow.sourceApp`，缺失时用「未知应用」；`trackersBlocked` 为命中的 flow 条数。
- 评分（公式写在代码注释里）：基础 100；每个不同 `(app, 域名)` 命中扣 `3 × severity`；同一应用命中 ≥3 个不同跟踪器再扣 5；结果 clamp 到 0–100。无 flows 或空跟踪器集合 → `findings=[]`、`trackersBlocked=0`、`score=100`，不崩溃。
- 未实现：按时间窗口/会话聚合、DNS 加密与 HTTPS 解密开关对评分的影响（UI 文案提到这些因素，但本模块只按流量证据算分）、自定义跟踪器列表的持久化。

## 5. 系统代理

- `SystemProxy.status()`：只读。服务名解析顺序：`route -n get default` 的 `interface:` → `networksetup -listnetworkserviceorder` 反查服务名 → `-listallnetworkservices` 中优先 `Wi-Fi` / `USB 10/100/1000 LAN` / `Ethernet` / `Thunderbolt Bridge` → 第一个启用项。依次尝试 `-getwebproxy` / `-getsecurewebproxy` / `-getsocksfirewallproxy`，第一个 `Enabled: Yes` 的即返回；全部失败或服务名为空 → `enabled=false`，不抛错。
- `enable(host:port:socksPort:)`：设置 web / secure web 为 `host:port`，SOCKS 为 `host:socksPort`，再分别 `-set*state on`；`disable()` 把三者状态设为 off（不清空已填的 host/port，便于下次快速开启）。
- 所有 `networksetup` / `route` 调用走 `CommandRunner`，10 秒超时、读 stdout+stderr、非零退出转 `connectionFailed`（消息含 stderr 尾部）；`networksetup` 不存在时抛 `unsupported`。
- `enable` / `disable` 在命令返回后回读 `-getwebproxy` 等状态做后置校验：`networksetup` 有时退出码为 0 却未真正生效（例如缺少管理员权限），此时抛 `connectionFailed("networksetup did not enable/disable the proxy …; administrator privileges may be required")`，不会静默成功。服务名为空 / `networksetup` 不存在分别在 `resolveService()` 抛 `connectionFailed("no active network service found")` / `unsupported`。
- `status()` 按设计不抛错（UI 只读展示，异常时返回 `enabled=false`）。
- 未实现：PAC 脚本、代理例外列表（bypass domains）、需要认证的代理、按服务分别配置（总是作用于当前活动服务）、SOCKS 仅开/关的独立入口。

## 6. 未实现（诚实清单）

- **Kill Switch（加分项，主动放弃）**：`pf` 需要 root（`pfctl -e -f` / anchor 都需要 sudo），而一旦规则写错会直接切断用户网络；按任务要求「不能静默失败」，本模块选择**不提供半成品实现**，避免误用。若后续要做，建议在 `leapin` 层要求显式 `sudo`，并在写入前 `pfctl -n -f` 干跑校验 + 保存回滚锚点。
- SSH：SFTP、端口转发、`ControlMaster` 复用、指纹确认 UI。
- NAS：AFP/NFS 挂载、设备型号与容量、Keychain 凭据保存。
- 学习：图像预处理、批量规则冲突检测、从进程路径反查应用。
- 隐私：时间窗口聚合、DNS/HTTPS 开关对评分的贡献、自定义名单持久化。
- 系统代理：PAC、bypass 列表、按服务选择。

## 7. 测试证据

`Tests/LeapinIntegrationsTests/PlaceholderTests.swift`（11 个用例，全部通过）：

1. `testCatalogIsPopulatedWithPlausibleDomains` — 目录 ≥30（实际 55）、名称唯一、每个域名小写、无空格、无 scheme、≥2 段、TLD 为字母。
2. `testParsePlainTextMatchesCatalogAndKeepsUnknownApps` — 中英混排 + 目录命中的兜底 + 未知应用保留空域名。
3. `testParseCSVAndMarkdownTable` — CSV（含表头）与 Markdown 表格两条路径。
4. `testParseJSON` — 字符串元素、对象元素、目录域名合并。
5. `testRuleSuggesterDeduplicatesAndSorts` — 域名唯一、confidence ∈ [0.5,0.95]、kind=`domainSuffix`、policy=`PROXY`、按 confidence 非递增、≤200。
6. `testRuleSuggesterMatchesFlowsToCatalogDomains` — `cdn.douyin.com` 后缀命中 `douyin.com` 且归属「抖音」、confidence ≥0.9。
7. `testPrivacyAuditEmptyAndHits` — 空输入 score=100 / 无 findings；三个命中（GA、DoubleClick 子域、Adjust 子域）→ findings=3、按 severity 降序、分类正确。
8. `testSystemProxyParsingAndStatusDoesNotCrash` — 纯解析 `-getwebproxy`、`-listallnetworkservices`、`-listnetworkserviceorder`；只读调用 `SystemProxy.status()`，**不修改系统代理**。
9. `testSSHSessionReportsFailureWithoutCrashing` — 连 `127.0.0.1:1` 必须抛 `connectionFailed`、`isConnected=false`、失败后 askpass 临时目录无残留。
10. `testSSHBinarySmoke` — `/usr/bin/ssh` 可执行、`ssh -V` 返回 OpenSSH 版本（本机无可用远程 sshd，SSH 只做二进制与失败路径冒烟）。
11. `testOCRRecognisesRenderedText` — 用 AppKit 画一张含「微信 weixin.qq.com」的图片交给 Vision，命中关键字；Vision 不可用时 `XCTSkip` 并说明原因（本机可用，0.3 s）。

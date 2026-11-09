# Leapin 格式支持全链路审计

- 仓库：~/Leapin（HEAD 历史提交，工作区仅有 2 个未跟踪的 Design/*.swift 与 docs/PLAN-v2.md）
- 审计范围：MiniYAML / Models / RuleParser / RuleSetLoader / FilterParser / AdBlockEngine / HARExporter / ProfileImportExport / ProfileStore / ProfilesView / leapin
- 审计方式：**只读**。未修改任何 .swift，未执行 swift build（避免与主窗口抢锁）。调研用的可执行验证放在 /tmp 的独立拷贝里完成（见附录 A）。
- 目标格式：Clash Meta / Clash Premium、Surge 5、base64 订阅、hosts、ABP、rule-set（yaml/list）、HAR。明确不在范围内：Sing-box。
- 约束基线：不新增 SPM 依赖（本机无 github.com）；不改 Package.swift 的 target 结构；swift-tools 6.0 + Swift 5 language mode；禁 fatalError / try! / 强制解包（测试除外）；swift build 零 error + swift test 全绿。

---

## 1. 现状概览

1. 格式链路是「**能跑通 happy path，但处处丢数据**」：Clash 只认 5 类出站（ss/trojan/http/https/socks5），Surge 只认 4 个段，其余一律静默 `continue` / `break`，用户看不到任何提示。
2. 模型层（Sources/LeapinCore/Models.swift）本身就是瓶颈：`OutboundConfig.extra` 是 `[String: String]` 扁平字典，`PolicyGroup` 没有 provider 语义，`Profile` 没有 rule-providers / nameserver-policy / fake-ip-filter / geox —— 这些字段**不是解析器漏读，而是模型无处安放**。
3. 往返（round-trip）目前不成立：`quote()` 覆盖不足会产出非法 YAML，`clashType()` 把未知类型写成 `direct`，Surge 的 `http-listen` 导入写 `mixedPort`、导出读 `httpPort`，导出后无法再导回。
4. MiniYAML 是自研子集：实测**BOM 会让整份 Clash 解析成空**，块标量 `|\>` 只支持 mapping 值，锚点/merge 会让文档从中间**静默截断**（不报错）。
5. 最硬的结构性障碍：格式层放在 LeapinRuntime，而 Package.swift 里**没有 LeapinRuntimeTests**，在「不改 target 结构」的约束下，PLAN P3 要求的 ≥12 条格式测试**当前无处可写** —— 必须先做文件归位。

---

## 2. 格式支持矩阵

| 格式 | 导入 | 导出 | 往返 | 主要缺口 |
| --- | --- | --- | --- | --- |
| Clash Meta / Premium YAML | 部分（仅 5 类出站、无 providers） | 有（丢 hosts/udp/传输参数） | ✗ 断裂 | CI-01..09、EX-01..05 |
| Surge 5 conf | 部分（General/Proxy/Proxy Group/Rule） | 有（无 [Host]/[MITM]） | ✗ 断裂 | SI-01..06、EX-06..08 |
| Leapin JSON | 完整 | 完整 | ✓ 等价 | 无 schemaVersion（EX-10） |
| hosts 文件 | 仅在 ABP 解析路径内识别（一行多域只留首个） | ✗ 无 | — | FP-05、EX-09 |
| ABP / AdGuard 列表 | 部分（丢 `$domain`、正则、多域 cosmetic） | ✗ 无 | — | FP-01..08、EX-09 |
| rule-set（纯文本 list） | 部分（policy-less 生效但回落 DIRECT） | ✗ 无 | — | RP-03、RS-01、EX-09 |
| rule-set（Clash YAML `payload:`） | ✗ 不支持 | ✗ 无 | — | RP-04、RS-01/05 |
| base64 订阅 / `ss://` / `trojan://` | ✗ 完全没有实现 | — | — | EN-02 |
| HAR 1.2 | ✗ 无导入（架构定义为单向导出） | 有 | — | HR-01..04 |

---

## 3. MiniYAML 能力边界（实测，非推测）

测试方法：把 `Sources/LeapinCore/MiniYAML.swift` 拷到 /tmp/tfmini，用 `xcrun swiftc -O` 编译一个 main.swift 逐条打印解析结果。

| 语法特性 | 现状 | 实测结果 | 证据 |
| --- | --- | --- | --- |
| UTF-8 BOM | ✗ 未剥离 | 顶层键变成 `\u{FEFF}proxies`，`root["proxies"]` 取不到 → **整份 Clash 静默导入为空** | MiniYAML.swift:73-83 |
| CRLF | ✓ | 正常（`components(separatedBy: .newlines)`） | MiniYAML.swift:73 |
| 行内 map / list（flow） | ✓ | 正常，含引号内逗号与嵌套 flow | MiniYAML.swift:parseInline |
| 序列套序列（`- - x`） | ✗ | 解析成标量 `- x` | MiniYAML.swift:95-124 |
| 块标量（mapping 值 `k: \|`） | 部分 | 支持 `\|`/`>`，**不支持 chomp 指示符** `\|-`/`\|+`/`>+` | MiniYAML.swift:144-145 |
| 块标量（序列项 `- \|`） | ✗ | 得到 `{payload=[\|]}`，后续内容全丢 | MiniYAML.swift:95-124 |
| 块标量内容保真 | ✗ | 收集阶段已剥注释与空行 → 块内的 `#` 与空行必丢 | MiniYAML.swift:73-83 |
| 锚点 / 别名 / merge（`&a` `*a` `<<:`） | ✗ | 只解析到 `&a` 那一行，**其余行静默截断且不报错** | MiniYAML.swift:131（`guard line.indent == indent else { break }`）+ :87-90（不校验 index 是否读完） |
| 多文档 `---` | ✗ | 当空行跳过并合并成一份 | MiniYAML.swift:80 |
| 多行 plain scalar | ✗ | `a: one` 换行缩进 `two` → 只得 `{a=one}`，后续行丢（同上截断机制） | MiniYAML.swift:131 |
| 重复 key | 后者胜 | `rules` 被覆盖不报错 | MiniYAML.swift:128-149 |
| 引号 key / 单引号双写转义 | ✓ | 正常 | MiniYAML.swift:keyValueSplit/unquote |
| 类型解析 | ✗ 全惰性 | 一律 `.scalar`；`bool` 把 `1`/`0` 当布尔 | MiniYAML.swift:YAMLValue.bool |
| `stringArray` | 宽松 | scalar 按逗号切开（会把 `1.1.1.1,8.8.8.8` 当两项，尚可接受） | Models/MiniYAML |

**结论**：MiniYAML 对 Clash 的主干（顶层 map、`proxies:` 序列、`rules:` 序列、flow map）够用，但**缺少三个「静默降级」安全阀**：BOM、锚点截断、块标量。这三个都不会抛错，用户只会看到「导入成功但规则是空的」。

---

## 4. 四类问题归类（先看现象，再看 §5 明细）

### 4.1 会直接拒绝（抛错或让整份配置失效）

- BOM 前缀 → Clash 整份解析为空（MY-01）。
- 8 种常见规则类型 → `unknownType`（RP-02，实测 `GEOSITE`/`DST-PORT`/`PROCESS-PATH`/`IP-SUFFIX`/`NETWORK`/`SUB-RULE`/`IP-ASN`/`SRC-PORT` 全报错）。
- Clash rule-set YAML 的 `payload:` 与 `+.domain`/`.domain` 成员 → 每行报错（RP-04，实测 3 条 error）。
- `[Host]`-only 的 Surge 文件 → 被嗅探成 Clash → YAML 顶层不是映射而抛错（EN-01）。
- `leapin export surge|json` → 不匹配任何 rawValue（EN-06）；虽然不抛错，但对用户等同「命令无效」。

### 4.2 能解析但丢字段（结构上无处安放）

vmess/vless/hysteria2/tuic/wireguard/snell/ssh 出站（MD-01）、ws-opts/grpc-opts/plugin/skip-cert-verify/alpn/fingerprint（MD-02/CI-01）、provider 型策略组（MD-03/CI-07）、rule-providers/proxy-providers/nameserver-policy/fake-ip-filter/geox-url/tun/sniffer（MD-04/CI-09）。

### 4.3 静默丢弃 / 静默改义（最危险，用户无感）

- 不认识的 proxy 类型整条 `continue`（CI-01）；不认识的策略组类型回落 `.select`（CI-07，relay→select 语义错）。
- policy-less 规则 → `policy=""` → 引擎回落 DIRECT（RP-03，RuleEngine.swift:86）。
- `$domain=` 作用域被丢，局部规则升级成全局拦截（FP-01）；路径规则 `|https://h/p` 升级成整域拦截（FP-02）；正则规则整行丢（FP-03）。
- hosts 一行多域只留首个（FP-05）；cosmetic 例外 `~excl##.ad` 变全局（FP-06）。
- 规则解析失败只 `LPLog.warn`（CI-08），UI 是二值 toast（EN-03）。

### 4.4 导出后无法再导入（round-trip 断裂）

- `quote()` 不转义 `#`、`&`、`*`、`!`、`|`、`>`、`{`、`[`、首尾空格、空串；而 `server`/`cipher`/`sni` 干脆不 quote（EX-01）→ 产出非法 YAML 或值漂移。
- `clashType()` 未知类型写成 `direct`（EX-02）→ 代理静默变直连。
- 导出丢 `dns.hosts`、`udp`、传输参数（EX-03）；`url-test` 组无 `url`/`interval`、空 `proxies` 组照写（EX-04/05）→ Clash 直接拒绝加载。
- Surge `http-listen` 导入→`mixedPort`、导出←`httpPort`（EX-08）；`password`/`name` 含逗号即错位（EX-07）。

---

## 5. 差距清单

> 证据列一律「文件:行（相对仓库根）」。工作量：S ≤ 半天，M ≈ 1-2 天，L ≥ 3 天。

### 5.1 Core：MiniYAML 与文本规范化

| ID | 证据（文件:行） | 问题 | 具体改法 | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| MY-01 | Sources/LeapinCore/MiniYAML.swift:73-83；Sources/LeapinRuntime/ProfileStore.swift:112；Sources/LeapinPolicy/AdBlock/FilterParser.swift:49-50 | 三处入口都不剥 BOM。MiniYAML 实测：BOM 后 `proxies` 键带 U+FEFF，整份 Clash 导入为空；FilterParser 实测首行变 keyword 规则（domain=nil） | 在 `MiniYAML.parse(_:)` 与 `Parser.init(text:)` 入口、`FilterParser.parse(_:)` 入口、`ProfileStore.importFile` 读文件后统一剥：`text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text` | 所有 Clash/YAML/hosts/ABP 导入 | P0 | S |
| MY-02 | MiniYAML.swift:73-83（预剥空行/注释）；:144-145；:95-124 | 块标量：序列项不支持；chomp 指示符 `\|-`/`\|+`/`>+` 未实现；收集阶段先剥注释与空行导致块内容损坏 | ① `Parser.init` 保留原始行（新增 `Line.raw`），注释/空行只在「跳过」判定里用，块标量读取用 raw；② `parseBlockScalar(parentIndent:folded:chomp:)` 解析 `\|`/`>` 后的 `-`/`+`；③ `parseSequence` 支持项值为块标量 | Clash rule-set yaml、多行 `script:`、Surge 多行值 | P1 | M |
| MY-03 | MiniYAML.swift:131；:87-90 | 锚点/merge 触发缩进不匹配 → `break` 静默截断剩余文档，且 `parseDocument` 不校验是否读完 | ① `parseDocument` 末尾 `guard index == lines.count else { throw MiniYAMLError.parse("unparsed trailing content", line: lines[index].number) }`（fail-loud）；② 见到 `&anchor`/`*alias`/`<<:` 显式抛 `unsupported feature`，走 ImportDiagnostics 告警 | 所有 YAML 导入的错误可见性 | P1 | M |
| MY-04 | MiniYAML.swift:80 | 多文档 `---` 被当空行，多个文档静默合并 | 只取第一个文档并在诊断里记 `multi-document` 一条 | Clash 多文档（罕见） | P2 | S |
| MY-05 | MiniYAML.swift:95-124 | 序列套序列解析成标量 `- x` | `isSequenceEntry` 命中后递归 `parseSequence`，而非当标量 | 少见 | P2 | S |
| MY-06 | MiniYAML.swift（`YAMLValue.bool` / `stringArray`） | `bool` 把 `1`/`0` 当布尔；无 tag 支持 | `bool` 只认 `true/false/yes/no/on/off`；`int` 优先于 `bool`；`stringArray` 仅对 `array` 生效，scalar 不按逗号切 | 端口/开关字段误读 | P2 | S |

### 5.2 Policy：规则语言（RuleParser / HostNormalizer）

| ID | 证据（文件:行） | 问题 | 具体改法 | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| RP-01 | Sources/LeapinPolicy/Rules/RuleParser.swift:134；:153-157；Sources/LeapinPolicy/Support/IPAddress.swift:225-229 | `*.domain` 的星号点未剥：只 `while value.hasPrefix(".")`。**实测** `DOMAIN-SUFFIX,*.google.com,PROXY` → value=`*.google.com`，`matchesSuffix("www.google.com")`=**false**，规则永不命中 | ① `makeRule` 的 `.domainSuffix` 分支剥 `*.` 前缀；② `DOMAIN-WILDCARD` 不再伪装成 `.domainSuffix`，新增 `RuleKind.domainWildcard`（或保留 `*.` 并在 `HostNormalizer.matchesSuffix` 先归一化 `suffix`）；③ `HostNormalizer.matchesSuffix` 内对 `suffix` 做同一归一化，避免两条路径再次分叉 | 引擎路由正确性（高频规则） | P0 | S |
| RP-02 | Sources/LeapinCore/Models.swift:45-80；RuleParser.swift:130-138 | 缺 GEOSITE / DST-PORT / SRC-PORT / PROCESS-PATH / IP-ASN / NETWORK / SUB-RULE / IP-SUFFIX / SRC-IP。**实测 8 种全部 `unknownType`** | `RuleKind` 增 case（`geoSite, dstPort, srcPort, processPath, ipASN, network, subRule, ipSuffix, srcIP`）；`resolveKind` 加映射；`makeRule` 加各自校验（端口 `UInt16`，ASN `Int`，`subRule` 复用 `parseOperands`）；`RuleEngine.evaluate` 加分支（`subRule` 走递归但需 `depth+1`，已有 :110 的 depth<16 保护） | Clash.Meta 规则集兼容、路由覆盖 | P0 | M |
| RP-03 | RuleParser.swift:56；Sources/LeapinPolicy/Rules/RuleEngine.swift:86 | policy-less 规则 `policy=""`，引擎 `policy.isEmpty ? "DIRECT"` → 命中即直连。**实测** `DOMAIN-SUFFIX,ads.com` → `policy=""` | ① `Rule` 增 `policyIsExplicit: Bool`（默认 true，`Codable` 用 `decodeIfPresent` 兜底）；② `RuleSetLoader.load(defaultPolicy:)` 给 rule-set 成员补策略；③ 导入 Clash 主配置时若发现 policy-less 规则，写一条 ImportDiagnostics 告警 | 分流语义（静默改义） | P0 | S |
| RP-04 | RuleParser.swift:67-87 | 只跳过 `rules:`，不识别 `payload:` 与 Clash rule-set 的 `+.x`/`.x` 成员。**实测** payload 段 5 行 → rules=2、errors=3 | `parseRules` 增 `ruleSetStyle` 参数；新增 `parseRuleSetMember(_:)`：`+.`→`DOMAIN-SUFFIX`、`.`→`DOMAIN-SUFFIX`、裸域→`DOMAIN`、带 `/`→`IP-CIDR`；跳过 `payload:` 并做「本行不是规则但也不是规则头」的判定 | Clash rule-provider / rule-set 全链路 | P0 | S |
| RP-05 | RuleParser.swift:146-151；:99-107 | `AND/OR/NOT` 的 `value` 被规范化成内部表示，导出时用 `value` 重建 → 无法回到原表达式 | `exportLine` 对逻辑类型优先输出 `rule.raw`（raw 已在 Models.swift:92 保留） | 往返等价 | P2 | M |
| RP-06 | RuleParser.swift:99-107 | 空 policy + 非空 modifiers 时，`fields.last?.isEmpty` 只删末尾空项 → 输出 `DOMAIN,x,,no-resolve` | 显式 `if !rule.policy.isEmpty { fields.insert(...) }`，不要依赖「最后一个空串」 | 导出可再导入 | P2 | S |
| RP-07 | IPAddress.swift:205-229 | `HostNormalizer` 无 IDN/punycode 归一 | `normalize` 增加 `precomposedStringWithCompatibilityMapping` 与全角转半角；punycode 用 `URLComponents`/`idna` 不可得时降级为「保留原样 + 诊断告警」 | 中文域名规则 | P2 | M |

### 5.3 Policy：ABP / hosts（FilterParser / AdBlockEngine）

| ID | 证据（文件:行） | 问题 | 具体改法 | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| FP-01 | FilterParser.swift:184-189；:5-21（FilterRule 无作用域字段） | `$domain=` 被识别却丢弃（`looksLikeOptions` 命中但不保存）→ 局部规则变全局拦截。**实测** `\|\|track.example.com^$domain=news.example.com` → domain=`track.example.com`，无 scope | `FilterRule` 增 `scope: [String]?` 与 `scopeNegated: [String]?`；`parseNetwork` 解析 `domain=`/`~domain=`；`AdBlockEngine.verdict` 增加 `requestHost` 入参判定作用域（不满足则跳过）。注意 `verdict(for:thirdParty:)` 签名要扩展 | 过拦（把广告域整站封了）+ 漏拦 | P0 | M |
| FP-02 | FilterParser.swift:205-231；Sources/LeapinPolicy/AdBlock/AdBlockEngine.swift:189-194；:226-229 | 路径规则被降级为整域规则。**实测** `\|https://cdn.example.com/ads/banner.js` → domain=`cdn.example.com`，对该域**所有**请求拦截 | `FilterRule` 增 `pathPrefix: String?`/`pathContains: String?`；`extractDomain` 只返回 host，路径部分写入新字段；`AdBlockEngine` 匹配时先判 host 再判 path（`keyMatches` 对 `*` 恒 true 的问题一并收口） | 误拦 CDN 全站 | P0 | M |
| FP-03 | FilterParser.swift:66-69 | 以 `/` 开头的正则规则整行丢弃。**实测** `/ads/banner/*$image` 未进 block | 新增 `parseRegexRule`：`/.../` → `FilterRule.isRegex=true` + `NSRegularExpression` 预编译（失败则诊断告警，不静默丢） | ABP 完整率 | P1 | S |
| FP-04 | FilterParser.swift:184-189 | 未知 `$options`（`removeparam`/`redirect`/`csp`/`denyallow`…）不当选项，整串当普通规则 → over-block。**实测** `\|\|x.example.com^$removeparam=utm_source` 正常拦截 | 选项表扩到常用集合；未知选项保留在 `options: [String]` 并降级为「按域拦截 + 诊断」 | 语义准确性 | P1 | S |
| FP-05 | FilterParser.swift:158-170（:166 `domains.first`） | hosts 一行多域只留第一个。**实测** `0.0.0.0 a.example.com b.example.com c.example.com` → 仅 `a.example.com` | `parseHosts` 返回 `[FilterRule]`，调用点 `append(contentsOf:)` | hosts 导入完整率 | P1 | S |
| FP-06 | FilterParser.swift:241-245 | `~excl.com##.ad` 的例外域被 `first { !hasPrefix("~") }` 跳过 → 空 → `*`。**实测** cosmetic domain=`*`，全局隐藏 | `normalizeDomainList` 返回 `(positive: [String], negative: [String])`；`CosmeticRule` 增 `excludedDomains` | 全局误隐藏 | P2 | S |
| FP-07 | FilterParser.swift:49-50 | BOM 首行成 keyword 规则（与 MY-01 同修） | 同 MY-01 | ABP 首行 | P2 | S |
| FP-08 | FilterParser.swift:241-245 | `a.com,b.com##.ad` 只取首个域。**实测** domain=`example.com`，`other.com` 丢 | `CosmeticRule` 的 domain 改 `[String]`，或按域展开成多条规则 | cosmetic 覆盖 | P2 | S |

### 5.4 Policy：规则集（RuleSetLoader）

| ID | 证据（文件:行） | 问题 | 具体改法 | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| RS-01 | Sources/LeapinPolicy/Rules/RuleSetLoader.swift:17 | 只调 `RuleParser.parseRules`：ABP、hosts、Clash rule-set yaml 一律不支持（yaml 每行报错） | `load` 内按内容嗅探：`payload:` → yaml；`\|\|`/`##` → ABP（复用 FilterParser 后转 Rule）；`0.0.0.0` → hosts；否则纯规则文本 | 规则集（PLAN P3 核心） | P1 | M |
| RS-02 | RuleSetLoader.swift:60-83 | 本地路径只试 `~/` 与 cwd，不接 `ProfileStore.ruleSetsDirectory`、不认 `file://`、不认 Clash 的 `path:` | 签名加 `resolveLocal: (String) -> URL?`（由 Runtime 注入 `ProfileStore`）；先 `fileURLWithPath`、再 `ruleSetsDirectory` 拼接、最后 cwd | rule-provider `path:` 落地 | P1 | S |
| RS-03 | RuleSetLoader.swift:85-98 | 15s 超时串行下载、无 ETag/If-Modified-Since、无大小上限 → 10 个源最坏 150s | `withThrowingTaskGroup` 并发（上限 4）；缓存 `ETag`/`Last-Modified` 到 `cacheDirectory`；`Content-Length` > 32MB 直接拒 | 启动耗时、离线可用性 | P1 | M |
| RS-04 | RuleSetLoader.swift:94 | 非 UTF-8 抛错；BOM 不剥 | `String(data:encoding:)` 失败时退 `ISO-8859-1` + 告警；入口剥 BOM | 编码兼容 | P2 | S |
| RS-05 | RuleSetLoader.swift:17；RuleParser.swift:130-138 | provider 的 `+.b.com`/`.c.com` 域名模式 `unknownType` 被丢（与 RP-04 同源） | 同 RP-04 | provider 规则 | P1 | S（随 RP-04） |

### 5.5 Core：数据模型（Models.swift）

| ID | 证据（文件:行） | 问题 | 具体改法 | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| MD-01 | Sources/LeapinCore/Models.swift:5-12 | `OutboundType` 仅 6 种，缺 vmess/vless/hysteria/hysteria2/tuic/wireguard/snell/ssh/anytls → 这些代理**无法表达** | 扩枚举（保持 `String` rawValue 以兼容旧 JSON）；未知值新增 `.other(String)`？→ 建议不要 associated value（Codable 复杂），改 `typeRaw: String` 保真 + `kind: OutboundType` | Clash/Surge 主流程、Dialer 分支 | P0 | M |
| MD-02 | Models.swift:14-41 | `extra: [String: String]` 扁平字典，装不下 `ws-opts: {path, headers}`、`grpc-opts`、`plugin-opts` | 方案 A（保真优先，S）：加 `options: [String: String]` 扁平化键（`ws-opts.path`）；方案 B（结构优先，M）：加 `transport: OutboundTransport`（enum: tcp/ws/grpc/http/h2/quic + config）。二者可并存，A 先上 | 出站参数保真、往返 | P0 | M |
| MD-03 | Models.swift:104-154 | `PolicyGroupType` 只 5 种；`PolicyGroup` 缺 use/filter/include-all*/exclude-filter/disable-udp/lazy/strategy/hidden | `PolicyGroupType` 增 relay/random/round-robin/consistent-hashing；`PolicyGroup` 增 `rawType: String`（保真）、`use: [String]`、`filter: String?`、`includeAll: Bool`、`includeAllProxies: Bool`、`excludeFilter: String?`、`disableUDP: Bool`、`lazy: Bool`、`strategy: String?`、`hidden: Bool` | 策略组语义、PolicyResolver | P0 | M |
| MD-04 | Models.swift:231-254 | `Profile` 无 ruleProviders/proxyProviders/nameserver-policy/fake-ip-filter/geox/tun/sniffer/顶层 hosts/script，也无 `schemaVersion` | 新增轻量结构：`RuleProvider{name,type,behavior,url,path,interval,format}`、`ProxyProvider`、`DNSConfig.nameserverPolicy: [String: [String]]`、`DNSConfig.fakeIPFilter: [String]`、`GeoxConfig{mmdb,geosite,geoip}`、`Profile.schemaVersion: Int`（默认 1，`decodeIfPresent`） | Clash 结构保真、前进兼容 | P0 | M |

### 5.6 Runtime：Clash 导入（ProfileImportExport.swift）

| ID | 证据（文件:行） | 问题 | 具体改法 | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| CI-01 | Sources/LeapinRuntime/ProfileImportExport.swift:53-67（:55 `guard let type = mapOutboundType else { continue }`）；:96-106 | 未知出站类型整条静默丢弃（vmess/vless/hysteria/tuic/wireguard/snell/ssh 全消失，无日志） | `mapOutboundType` 扩到 MD-01 的枚举；仍未知 → 产出 `ImportIssue(severity: .dropped, line:?, snippet: name)` 而不是 `continue`；`parseOutbound(_ map:)` 独立成函数便于测 | Clash 导入主路径 | P0 | M |
| CI-02 | ProfileImportExport.swift:63 | `tls: (m["tls"]?.bool ?? false) \|\| (m["sni"]?.string != nil)` 启发式：有 sni 就开 TLS，ss+plugin、http 伪装场景会误开 | 只用 `tls`/`security`（Clash.Meta 的 `reality`/`tls`）字段；`sni` 仅作为 `servername` 属性 | 连接失败/握手错 | P1 | S |
| CI-03 | ProfileImportExport.swift:65 | `["udp": m["udp"]?.string ?? "false"]`：YAML 里 `udp: true` 是 bool，`.string` 返回 nil → 记录成 `"false"` | 用 `m["udp"]?.bool` 判定后写 `"true"/"false"`；或用 `OutboundConfig.udp: Bool?` 强类型字段 | UDP 行为静默改变 | P1 | S |
| CI-04 | ProfileImportExport.swift:26-28 | 只写 `port` 不写 `mixed-port` 时，`mixedPort` 保持 `ProfileDefaults` 的 7890 → 与系统已占用端口冲突；反之只写 `mixed-port` 时 `httpPort` 仍是默认值 | 语义映射：Clash `port` = HTTP/SOCKS 混合入口（v1 语义），`mixed-port` = 混合入口 → 两者同时映射 `mixedPort`，并保留 `httpPort` 仅来自 Surge `http-listen`；或新增 `entries: [Listener]`（M） | 端口冲突、启动失败 | P1 | S |
| CI-05 | ProfileImportExport.swift:36-38 | `dns.hosts` 多值只取第一个（`$0.string ?? $0.array?.first?.string`）；顶层 `hosts:` 完全不读 | `cfg.hosts` 改 `[String: [String]]` 或保留首值但写诊断；补读顶层 `hosts:` 合并 | hosts 解析正确性 | P1 | S |
| CI-06 | ProfileImportExport.swift:43-48 | `enhanced-mode` 只认 `fake-ip`；`nameserver-policy`、`fake-ip-filter` 完全忽略；`redir-host` 无处理 | 用 MD-04 的新字段承接：`nameserver-policy` → `[String: [String]]`，`fake-ip-filter` → `[String]`；`redir-host` 显式映射 `.redirHost`（DNSMode 需加 case） | Clash DNS 保真 | P0 | M |
| CI-07 | ProfileImportExport.swift:70-79（:73 回落 `.select`；:74 只读 `proxies`） | provider 型组（`use:`/`filter:`/`include-all`）变成**空组** → `PolicyResolver.validate` 报空组、启动失败；relay→select 语义错 | 读 `use`/`filter`/`include-all`/`include-all-proxies`/`exclude-filter`/`exclude-type`；`rawType` 保真；空组 + 有 provider 引用时在 `start()` 前解析 provider 并展开成员 | 策略组、启动 | P0 | M |
| CI-08 | ProfileImportExport.swift:82-92 | 规则失败只 `LPLog.warn`；`rules` 为空直接注入 `ProfileDefaults.baseRules`（含 `MATCH,PROXY`）→ 语义被替换且用户不知道 | 引入 ImportDiagnostics（EN-03）；空规则时**不**注入 baseRules，改为诊断 `no rules` + 保留空列表（由 `ProfileDefaults` 只在「新建配置」时用） | 导入语义正确性 | P0 | S |
| CI-09 | ProfileImportExport.swift（全文无 `rule-providers`/`proxy-providers` 引用） | 两个 provider 段完全不读；`geox-url` 不读不存 | 用 MD-04 结构承接；`geox-url` 存 `GeoxConfig`，并在「GEOIP 规则但缺 mmdb」时给诊断 | Clash.Meta 完整度 | P0 | M |

### 5.7 Runtime：Surge 导入

| ID | 证据（文件:行） | 问题 | 具体改法 | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| SI-01 | ProfileImportExport.swift:119-139 | `[Host]` 段落 `default: break` 整段丢弃（PLAN P3 明确要求） | 新增 `case "host"`：复用 hosts 行解析（`host = ip` 形式），写入 `dns.hosts`；`[MITM]`/`[URL Rewrite]`/`[Script]`/`[Proxy Provider]` 至少产生 `unsupported section` 诊断 | Surge 配置保真 | P1 | S |
| SI-02 | ProfileImportExport.swift:171-177 | `https` 类型 → `.http` 但 `tls` 不置 true（`tls` 仅由 `tls=true`/`sni=` 触发）；导出又写 `type: http` 而非 `https` | `mapOutboundType` 返回 `(.http, forceTLS: true)` 或在 `parseSurgeProxy` 里 `if typeRaw == "https" { tls = true }`；导出 `surgeType` 在 `tls && type == .http` 时写 `https` | 明文/密文错连 | P1 | S |
| SI-03 | ProfileImportExport.swift:211-217 | `smart`/`subnet`/`ssid`/`external` 等组类型 `return nil` 整组丢失 | 扩 `PolicyGroupType`（MD-03）+ 未知类型保留 `rawType` 并降级 `.select` 同时出诊断 | 组丢失 | P1 | S |
| SI-04 | ProfileImportExport.swift:218 | `members.filter { !$0.contains("=") }` 把 `url=...`/`interval=...`/`tolerance=...`/`policy-path=...` 连同参数值一起丢 | 先按 `k=v` 抽出组级参数（url/interval/tolerance/policy-path/timeout），剩余才是成员 | url-test 参数全丢 | P1 | S |
| SI-05 | ProfileImportExport.swift:189-197（:195 `skip-cert-verify: break`；:196 `default: break`） | `skip-cert-verify`/`obfs`/`ws`/`udp-relay`/`tfo`/`test-url`/`underlying-proxy` 全部丢弃且无提示 | 写入 `options`（MD-02）或强类型字段；`skip-cert-verify` 至少落 `OutboundConfig.allowInsecure` | 连接失败（自签/obfs） | P2 | M |
| SI-06 | ProfileImportExport.swift:145-155 | `[General]` 仅 4 键；`[MITM]`/`[URL Rewrite]`/`[Script]`/`[Replica]` 忽略 | 逐段补 `skip-proxy`/`exclude-simple-hostnames`/`dns-server`/`encrypted-dns-server`；其余段落统一诊断「未支持」 | Surge 兼容性 | P2 | M |
| SI-07 | ProfileImportExport.swift:122 | 段名判定要求整行 `[...]`；`[Proxy] # 注释` 这类行会失效 | 先剥行尾注释再判段名 | 容错 | P2 | S |

### 5.8 Runtime：导出（Clash / Surge）

| ID | 证据（文件:行） | 问题 | 具体改法 | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| EX-01 | ProfileImportExport.swift:309-314（quote）；:248-256（server/cipher/sni 未 quote） | `quote()` 只处理 `:`/`#`/`,`/首尾空格；`server`、`cipher`、`sni` 完全不 quote。值含 `&`/`*`/`!`/`\|`/`>`/`{`/`[`/空串时产出非法或漂移 YAML | 新增 `yamlScalar(_:)`：空串/以 `-?:,[]{}#&*!\|>%@\`` 开头/含 `: ` 或 ` #`/形如 `true/false/null/yes/no/~`/含换行 → 双引号 + 转义 `\\` 与 `"`；所有标量统一走它 | **导出后 Clash 无法加载** | P0 | S |
| EX-02 | ProfileImportExport.swift:315-318 | `clashType` 的 `default: return "direct"`：vless/vmess 导出成 `type: direct`，语义静默翻转 | 未知类型走 `rawType`（MD-01）；无法表达时**抛错或跳过并诊断**，绝不写 direct | 数据损坏 | P0 | S |
| EX-03 | ProfileImportExport.swift:224-273 | 导出不写 `dns.hosts`、不写 `udp`、不写 `options`（ws/grpc/plugin）、不写 providers | 按 MD-02/03/04 补齐输出；`options` 反扁平化（`ws-opts.path` → 嵌套 map） | 往返断裂 | P0 | M |
| EX-04 | ProfileImportExport.swift:260-267 | `url-test`/`fallback` 组只在有值时写 `url`/`interval`；Clash 对 `url-test` 要求必填 → 导出文件被 Clash 拒绝 | 组类型为 `urlTest`/`fallback` 且缺 url 时补默认 `http://www.gstatic.com/generate_204` + `interval: 300`，并写诊断 | 导出不可用 | P1 | S |
| EX-05 | ProfileImportExport.swift:263-264 | 空 `proxies` 的组照样输出（Clash 校验 `proxy group X: empty proxies` 报错） | `if g.proxies.isEmpty { continue }` + 诊断；或输出 `proxies: [DIRECT]` 占位（不推荐，会改语义） | 导出不可用 | P1 | S |
| EX-06 | ProfileImportExport.swift:276-307（:278 空 MANAGED-CONFIG） | 无 `[Host]`/`[MITM]` 输出；`#!MANAGED-CONFIG` 空头无 URL，Surge 会认为配置无效/无意义 | 输出 `[Host]`（来自 `dns.hosts`）；`MANAGED-CONFIG` 要么去掉，要么写成 `#!MANAGED-CONFIG <profile 名>` 并在注释里说明 | Surge 可用性 | P1 | S |
| EX-07 | ProfileImportExport.swift:289-296 | 名字与 password 未转义逗号/等号；http/socks5 先写位置参 `user, pass` 又追加 `password=` → 同字段双写 | 统一 `surgeEscape(_:)`（含 `,` `=` 换行时拒绝导出并诊断）；http/socks5 只写位置参，其余类型只写 `k=v` | 导出错位 | P1 | S |
| EX-08 | ProfileImportExport.swift:148-149（导入写 mixedPort）vs :282（导出读 httpPort） | `http-listen` 往返断裂：导入后 `httpPort` 不变、`mixedPort` 被改；导出又用 `httpPort` | 导入改为写 `httpPort`（与导出一致），或导出改为写 `mixedPort`；两者择一并加往返测试 | 端口漂移 | P1 | S |
| EX-09 | Sources/LeapinRuntime/ProfileStore.swift:101-108；:170-174 | `ProfileFormat` 只有 clash/surge/json → 无 hosts / ABP / rule-set 导出（PLAN P3 要求） | `ProfileFormat` 增 `.hosts`/`.abp`/`.ruleSet`；`export` 分支实现；UI 菜单与 leapin 同步 | PLAN P3 | P1 | M |
| EX-10 | ProfileStore.swift:184-190；Models.swift:231-254 | JSON 用 `sortedKeys+prettyPrinted` 可再导入（✓），但无 `schemaVersion`，未来字段变更无法迁移 | `Profile.schemaVersion = 1`，解码时 `decodeIfPresent ?? 1`，导出写入 | 前进兼容 | P2 | S |

### 5.9 Runtime：入口 / 诊断 / UI / CLI / 可测试性

| ID | 证据（文件:行） | 问题 | 具体改法 | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| EN-01 | ProfileStore.swift:110-120 | 嗅探只有三条规则：`.json` 后缀 / 含 `[Rule]``[Proxy]``[General]` / 否则 Clash。`[Host]`-only 的 Surge、base64 订阅、ABP 列表、hosts 文件全部误判 | 新增 `ProfileFormatDetector.detect(_ text: String, pathExtension: String) -> DetectedFormat`（纯函数，可测）：BOM→剥；`{...}`/JSON→json；base64 且解码含 `://`→ subscription；`payload:`→rule-set-yaml；`\|\|`或`##`→abp；`0.0.0.0 `→hosts；含 `[General]`等→surge；有 `proxies:`/`rules:`→clash；最后才抛 `unrecognized` | 所有导入入口 | P0 | S |
| EN-02 | 全仓无 base64 订阅实现（grep `base64` 仅 Sources/LeapinNet/Support/Bytes.swift、OutboundDialer.swift:103、HARExporter 注释） | PLAN P3 的「base64 订阅 + ss:// + trojan:// + http(s) 订阅链接」完全缺失 | 新增 `SubscriptionImporter`：`resolve(_ urlOrText:)` → 拉取/解码 base64 → 逐行 `ss://`（`SIP002`：base64(userinfo)@host:port#name）与 `trojan://`（URLComponents）→ `OutboundConfig`；失败行给诊断；注意不新增依赖（`Data(base64Encoded:)` 可用） | PLAN P3 主项 | P0 | L |
| EN-03 | ProfileImportExport.swift:86、:135（仅 LPLog.warn）；Sources/LeapinApp/LeapinApp.swift:219-228（二值 toast） | 没有 ImportDiagnostics（行号 + 原因 + 原文），用户只看到「导入成功/失败」 | 新增 `public struct ImportIssue { line: Int?; severity: .info/.warning/.dropped/.error; field: String?; message: String; snippet: String? }` 与 `ImportResult { profile, issues, stats }`；`ProfileImporter.clash/surge` 返回 `ImportResult`；UI 弹「导入报告」sheet（可滚动 + 复制） | 用户可见性、可测性 | P0 | M |
| EN-04 | ProfileStore.swift:111-123 | 每次导入都 `save` 新 UUID：重复导入同一文件会产生多份；无「更新已有」 | `importFile(at:into: UUID?)` 或按 `sourcePath`+name 去重；`ImportResult` 里返回 `replaced: Bool` | 配置管理体验 | P2 | S |
| EN-05 | Sources/LeapinApp/Views/ProfilesView.swift:27（副标题）、:38-40（导出菜单仅 3 项）、:70（承诺文案） | 文案承诺「策略组、规则、DNS、去广告列表都会保留」「导出支持 round-trip」，与实现不符 | 在 EN-03/EX-09 完成后同步文案；未实现前改为「Clash / Surge / JSON（实验性）」 | 用户预期 | P1 | S |
| EN-06 | Sources/leapin/main.swift:131-135（:132 `ProfileFormat(rawValue: $0)`）；:180（help 文案 `clash / surge / json`） | rawValue 是 `"Clash YAML"`/`"Surge Conf"`/`"Leapin JSON"`，CLI 传 `surge`/`json` 一律不匹配 → 静默回落 `.clash`，**export surge/json 实际导出的是 Clash** | `ProfileFormat` 加 `init?(cliName: String)` 映射 `clash/surge/json/hosts/abp/rule-set`；`exportProfile` 用 `cliName`，无匹配时报错而非回落；help 与之一致 | CLI 完全不可用（surge/json） | P0 | S |
| EN-07 | Sources/leapin/main.swift:124-129 | import 只打印名字/规则数/出站数，无失败行 | 与 EN-03 联动：打印 `issues` 摘要（前 20 条 + 总数），`--json` 输出机器可读 | CLI 可用性 | P2 | S |
| EN-08 | Package.swift:31-41（无 LeapinRuntimeTests）；Sources/LeapinRuntime/ProfileImportExport.swift:1-3（只依赖 Core+Policy） | 格式层在 Runtime → 在「不改 target 结构」的硬约束下**没有 test target 能 import 它**，PLAN P3 的 ≥12 条格式测试无处落地 | 把 `ProfileImportExport.swift`（含 `ProfileDefaults`，自包含，无 `Bundle.module`）整体移到 `Sources/LeapinPolicy/Format/`；SwiftPM 自动收录目录内文件，**无需改 Package.swift**；Runtime 侧不受影响（Runtime 依赖 Policy）。`ProfileStore.swift` 因用 `Bundle.module`（:145-149）保留在 Runtime，只把「嗅探 + 导入/导出派发」抽成 Policy 里的纯类型 | **决定后续所有测试能否存在** | P0 | S |

### 5.10 Net：HAR

| ID | 证据（文件:行） | 问题 | 具体改法 | 影响面 | 优先级 | 工作量 |
| --- | --- | --- | --- | --- | --- | --- |
| HR-01 | Sources/LeapinNet/Capture/HARExporter.swift:67（`url` 已脱敏）vs :73（`queryString(from: request.url)` 用原始 url） | 脱敏模式导出的 HAR 里，`url` 是脱敏的但 `queryString` 是**明文**的 → `?token=...&key=...` 直接泄露 | `queryString(from: url)` 传入已脱敏的 `url`；或对每个 value 再 `Redactor.redact` | **隐私泄露（已导出给第三方）** | P0 | S |
| HR-02 | HARExporter.swift:90-102 | `content` 无 `encoding` 字段，二进制 body 被 `String(decoding:)` 解成替换字符 → 数据损坏 | 非 UTF-8 时写 `"encoding": "base64"` + `Data.base64EncodedString()`；`text` 仅用于文本 | HAR 正确性 | P1 | S |
| HR-03 | HARExporter.swift:78-83（postData 无 params）、:104-113（cookies 恒空、无 pages/serverIPAddress） | HAR 1.2 规范缺项，部分工具会校验 | `pages` 至少 1 条 + `pageref`；`cookies` 从 `Cookie` 头拆；`serverIPAddress` 若有连接信息则填 | 第三方兼容 | P2 | M |
| HR-04 | 全仓无 HAR 导入 | 无导入（按 ARCHITECTURE 属单向导出） | 明确记为「设计如此」，不列为缺陷；若要支持，按 `log.entries[]` 反序列化为 `CapturedRequest` | — | P2（信息） | S |

---

## 6. 可落地的函数级改动点（按文件）

### 6.1 Sources/LeapinCore/MiniYAML.swift

```swift
// 新增
static func stripBOM(_ text: String) -> String            // parse(_:) 与 Parser.init 入口调用
private struct Line { let indent: Int; let text: String; let number: Int; let raw: String }
private mutating func parseBlockScalar(parentIndent: Int, folded: Bool, chomp: Chomp) -> String
private enum Chomp { case clip, strip, keep }
mutating func parseDocument() throws -> YAMLValue          // 末尾加 index == lines.count 校验
private func parseAnchor(_ body: String) throws -> Bool     // &/*/<< 显式抛 unsupported
```

- `Parser.init`：不丢弃 `#` 与空行到 `raw`；`lines` 仍只存有效行（保持现有行为），但块标量读取从 `rawLines` 取。
- 错误类型：`MiniYAMLError` 增 `.unsupportedFeature(String, line: Int)`、`.trailingContent(line: Int)`。

### 6.2 Sources/LeapinPolicy/Rules/RuleParser.swift

```swift
static func parseRules(_ text: String, style: RuleSetStyle = .plain) -> (rules: [Rule], errors: [String])
static func parseRuleSetMember(_ line: String, policy: String) -> Rule?   // +.x  .x  裸域  CIDR
static func stripWildcard(_ value: String) -> String                       // "*.a.com" -> "a.com"
static func exportLine(_ rule: Rule, matchToken: String) -> String         // 空 policy 显式分支
static func resolveKind(_ token: String) -> RuleKind?                      // +9 种类型
```

- `makeRule`：`.domainSuffix` 与新增 `.domainWildcard` 共用 `stripWildcard`；`subRule` 复用 `parseOperands` 但限制 `depth`。
- `parseRules`：跳过 `payload:`；对 `+.x`/`.x` 走 `parseRuleSetMember`。

### 6.3 Sources/LeapinPolicy/Support/IPAddress.swift

```swift
public static func matchesSuffix(_ host: String, _ domain: String) -> Bool   // 先 stripWildcard(domain)
public static func wildcardMatch(_ host: String, _ pattern: String) -> Bool  // 若支持 DOMAIN-WILDCARD
```

### 6.4 Sources/LeapinPolicy/AdBlock/FilterParser.swift

```swift
public struct FilterRule {
    public var raw: String
    public var domain: String?
    public var pathPrefix: String?        // 新增
    public var isRegex: Bool              // 新增
    public var scope: [String]?           // 新增（$domain=）
    public var options: [String]          // 新增（未识别选项，保真）
}
static func parseHosts(_ line: String) -> [FilterRule]        // 多域
static func parseNetwork(_ line: String) -> FilterRule?       // 解析 $options 全表
static func parseRegexRule(_ line: String) -> FilterRule?     // /.../
static func normalizeDomainList(_ text: String) -> (positive: [String], negative: [String])
```

### 6.5 Sources/LeapinPolicy/Rules/RuleSetLoader.swift

```swift
public static func load(sources: [RuleSetSource], cacheDirectory: URL,
                        defaultPolicy: String = "PROXY",
                        resolveLocal: ((String) -> URL?)? = nil) async -> [String: [Rule]]
private static func parse(_ text: String, format: RuleSetFormat) -> [Rule]   // yaml/list/abp/hosts
private static func fetch(_ source: RuleSetSource, cache: URL) async throws -> String  // ETag/并发/上限
```

### 6.6 Sources/LeapinCore/Models.swift

```swift
public enum OutboundType: String, Codable, Sendable, CaseIterable {
    case direct, http, socks5, shadowsocks, trojan, reject
    case vmess, vless, hysteria, hysteria2, tuic, wireguard, snell, ssh, anytls
}
public struct OutboundConfig {
    public var options: [String: String]      // 扁平化："ws-opts.path"
    public var rawType: String?               // Clash 原始 type，保真
    public var udp: Bool?
    public var allowInsecure: Bool?
}
public struct PolicyGroup {
    public var rawType: String?
    public var use: [String]
    public var filter: String?
    public var includeAll: Bool
    public var excludeFilter: String?
}
public struct RuleProvider: Codable, Sendable { name, type, behavior, url, path, interval, format }
public struct GeoxConfig: Codable, Sendable { mmdb: String?, geosite: String?, geoip: String? }
public struct Profile {
    public var schemaVersion: Int
    public var ruleProviders: [RuleProvider]
    public var proxyProviders: [RuleProvider]
    public var geox: GeoxConfig?
}
public struct DNSConfig {
    public var nameserverPolicy: [String: [String]]
    public var fakeIPFilter: [String]
}
public enum RuleKind { /* + geoSite, dstPort, srcPort, processPath, ipASN, network, subRule, ipSuffix, srcIP */ }
```

### 6.7 Sources/LeapinPolicy/Format/ProfileImportExport.swift（由 Runtime 迁入，见 EN-08）

```swift
public struct ImportIssue: Sendable { public var line: Int?; public var severity: Severity; public var field: String?; public var message: String; public var snippet: String? }
public struct ImportResult: Sendable { public var profile: Profile; public var issues: [ImportIssue]; public var stats: [String: Int] }

public enum ProfileImporter {
    public static func clash(_ text: String, name: String) throws -> ImportResult
    public static func surge(_ text: String, name: String) throws -> ImportResult
    private static func parseOutbound(_ map: [String: YAMLValue], line: Int?, into: inout [ImportIssue]) -> OutboundConfig?
    private static func parseGroup(_ map: [String: YAMLValue], into: inout [ImportIssue]) -> PolicyGroup?
    private static func parseDNS(_ map: [String: YAMLValue]) -> DNSConfig
    private static func parseProviders(_ map: [String: YAMLValue]) -> [RuleProvider]
    private static func flatten(_ value: YAMLValue, prefix: String) -> [String: String]
}

public enum ProfileExporter {
    public static func clash(_ profile: Profile) -> String   // 用 yamlScalar
    public static func surge(_ profile: Profile) -> String   // + [Host]
    public static func yamlScalar(_ s: String) -> String     // 替换 quote()
}
```

### 6.8 Sources/LeapinRuntime/ProfileStore.swift

```swift
public func detectFormat(_ data: Data, pathExtension: String) -> DetectedFormat
public func importFile(at url: URL) throws -> ImportResult     // 返回诊断
public func export(_ profile: Profile, format: ProfileFormat) throws -> String  // + hosts/abp/ruleSet
public enum ProfileFormat: String { case clash, surge, json, hosts, abp, ruleSet; public init?(cliName: String) }
```

### 6.9 Sources/leapin/main.swift

```swift
static func exportProfile(_ args: [String]) async throws   // ProfileFormat(cliName:) + 不匹配即报错
static func importProfile(_ args: [String]) async throws   // 打印 issues 摘要，支持 --json
```

### 6.10 Sources/LeapinNet/Capture/HARExporter.swift

```swift
private static func queryString(from url: String) -> [[String: String]]   // 调用点传脱敏后的 url
private static func contentObject(_ data: Data, mimeType: String, redact: Bool) -> [String: Any]  // 非 UTF-8 走 base64
```

---

## 7. 测试矩阵

> 目标：新增 ≥12 条（PLAN P3 要求），并按「反向断言」覆盖四类缺陷。EN-08 完成前，这些只能写在 LeapinPolicyTests / LeapinCoreTests / LeapinNetTests。

| ID | 测试位置 | 输入 | 期望 |
| --- | --- | --- | --- |
| T-01 | LeapinCoreTests/MiniYAMLTests.swift | `\u{FEFF}proxies:\n  - {name: a}` | `root["proxies"]` 可读，length=1 |
| T-02 | 同上 | `a: 1\nb: &x 2\nc: *x` | 抛 `.unsupportedFeature`（不得静默返回 `{a=1}`） |
| T-03 | 同上 | `k: \|\n  line1\n  # not comment\n  line3\n` | 值为三行原文，含 `# not comment` |
| T-04 | 同上 | `payload:\n  - \|\n      a: 1\n` | 块标量在序列项内正确 |
| T-05 | 同上 | 两文档 `---` | 只取第一个 + 诊断 |
| T-06 | LeapinPolicyTests/RuleParserTests.swift | `DOMAIN-SUFFIX,*.google.com,PROXY` | `HostNormalizer.matchesSuffix("www.google.com", rule.value) == true` |
| T-07 | 同上 | 9 种新类型各一行 | `parse` 成功，`kind` 正确，`exportLine` 可回读 |
| T-08 | 同上 | `DOMAIN-SUFFIX,ads.com`（policy-less） | `policyIsExplicit == false`；套 `defaultPolicy` 后为 PROXY |
| T-09 | 同上 | `payload:\n  - '+.a.com'\n  - '.b.com'\n  - '1.2.3.0/24'` | 3 条规则、0 error |
| T-10 | LeapinPolicyTests/FilterParserTests.swift | `\|\|t.com^$domain=a.com` | `scope == ["a.com"]`；scope 外主机不拦 |
| T-11 | 同上 | `\|https://cdn.x/ads/a.js` | `pathPrefix == "/ads/a.js"`；同域其他路径不拦 |
| T-12 | 同上 | `/ads/\d+/\$image` | `isRegex == true`，不丢 |
| T-13 | 同上 | `0.0.0.0 a.com b.com c.com` | 3 条规则 |
| T-14 | 同上 | `~excl.com##.ad` | domain 非 `*`，excludedDomains 含 excl.com |
| T-15 | LeapinPolicyTests/ProfileFormatTests.swift（EN-08 后） | 真实 Clash 片段（vmess + ws-opts + rule-providers + nameserver-policy + fake-ip-filter + geox-url） | 导入不丢 proxy；结构字段齐全；`issues` 为空 |
| T-16 | 同上 | Clash 往返：import→export→import | 两次 `Profile` 的 `outbounds/groups/rules` 键集合与顺序等价（PLAN 的「语义等价」） |
| T-17 | 同上 | Surge 片段含 `[Host]` + `https` proxy + `url-test, url=..., interval=...` | hosts 落到 dns.hosts；tls=true；组参数保留 |
| T-18 | 同上 | Surge 往返：`http-listen` | 导出再导入后 `mixedPort/httpPort` 不漂移 |
| T-19 | 同上 | 含 `server: "a b"` / `password: p#1` 的 profile | 导出结果可被 MiniYAML 重新解析且值相等 |
| T-20 | 同上 | 无 `rules` 的 Clash | 不注入 baseRules；issues 含 `no rules` |
| T-21 | 同上 | 1MB / 5 万行规则文本 | `import` < 2s（debug 构建实测基线：50k 行 459ms，见附录 A） |
| T-22 | LeapinNetTests/HARExporterTests.swift | 请求 URL 含 `?token=abc`，`redact: true` | `log.entries[0].request.queryString` 中不含 `abc` |
| T-23 | 同上 | 二进制 body | `content.encoding == "base64"` 且可 base64 解码回原字节 |
| T-24 | LeapinPolicyTests/RuleSetLoaderTests.swift | 本地 `rule-set.yaml`（`path:` 指向 App Support 目录） | 能按 `ruleSetsDirectory` 解析 |

现有测试作为**回归门禁**：LeapinPolicyTests/PolicyTests.swift:358-388（Rule 往返）、:237/:250/:279/:329（FilterParser）、:392+（scale）、LeapinCoreTests/SmokeTests.swift（MiniYAML basics）、LeapinNetTests/CaptureTests.swift:79-219（HAR 形状/脱敏）。

---

## 8. 建议实施顺序

**第 0 步（必须最先，串行，1 人，S）**
1. EN-08：把 `ProfileImportExport.swift` 迁到 `Sources/LeapinPolicy/Format/`（含 `ProfileDefaults`；确认无 `Bundle.module`）。**解锁测试**，且后续所有格式改动都在可测范围内。
2. MY-01（BOM）：一处改动同时修好 Clash 整份空导入 + ABP 首行丢失。
3. HR-01（HAR query 泄露）：独立文件，风险最高、改动最小，可先合。

**第 1 步（并行 3 条 lane，写范围互斥）**
- Lane A（Core，1 人）：MD-01/02/03/04 模型扩展 → 再做 MY-02/03（块标量、fail-loud）。**模型必须先落地**，因为 Policy/Runtime 都依赖新字段。
- Lane B（Policy，1 人）：RP-01（星号点，独立、零依赖，可最先）、RP-04/RS-05（rule-set）、RP-02/03（类型 + policy）。RP-02 依赖 `RuleKind`，与 Lane A 的 Models 有写冲突 → 由 A 先提交 `RuleKind` 的 case 声明（只加 case 不改逻辑），B 再改 `RuleParser`/`RuleEngine`。
- Lane C（Net，1 人）：HR-02/03（HAR content encoding）。

**第 2 步（串行于第 1 步之后，Runtime 单文件，1 人）**
- `ProfileImportExport.swift` 一个文件承载 CI-01..09、SI-01..07、EX-01..08 → **只能一个 worker**，按「先导入、后导出」顺序做，每完成一组跑一次往返测试（T-15..T-20）。
- 其中 CI-01/CI-07 依赖 Lane A 的模型；CI-06 依赖 MD-04。

**第 3 步（并行 2 条 lane）**
- Lane D（入口/诊断）：EN-01（嗅探）、EN-03（ImportDiagnostics）→ 然后 EN-05（UI 文案）、EN-07/EN-06（CLI）。EN-06 可独立先做（S）。
- Lane E（订阅）：EN-02（base64/ss:///trojan://），L 级，独立新文件，可与 D 并行。

**第 4 步（收口）**
- EX-09（hosts/ABP/rule-set 导出）+ T-16/T-18 往返门禁 + 全仓 `swift build` / `swift test`。

**不可并行的点**
- `Sources/LeapinCore/Models.swift`：Lane A 独占（B 只读）。
- `Sources/LeapinRuntime/ProfileImportExport.swift`：单 worker（第 2 步）。
- `Sources/LeapinPolicy/Rules/RuleParser.swift` 与 `RuleEngine.swift`：同属 Lane B，避免 exportLine 与 kind 扩展交叉。
- EN-08 的迁移必须最先，否则第 2 步的改动没有测试保护。

---

## 9. 风险与回归点

### 9.1 会被牵连的现有测试
| 测试 | 文件:行 | 触发原因 |
| --- | --- | --- |
| Rule 往返 | Tests/LeapinPolicyTests/PolicyTests.swift:358-388 | RuleKind 扩展、`exportLine` 空 policy 分支、`*.domain` 归一化 → 断言里的 value 会变 |
| FilterParser 行为 | Tests/LeapinPolicyTests/PolicyTests.swift:237、:250、:279、:329 | 路径规则/正则/$domain/多域 hosts 的新语义会改变 block 计数 |
| 规模测试 | Tests/LeapinPolicyTests/PolicyTests.swift:392+ | 新增字段与分支会略增内存/耗时（实测仍有 4x 余量） |
| MiniYAML basics | Tests/LeapinCoreTests/SmokeTests.swift | BOM 剥离、锚点改抛错、多文档只取首个 |
| HAR 形状/脱敏 | Tests/LeapinNetTests/CaptureTests.swift:79-219 | `content` 新增 `encoding` 字段会打破字段集合断言；queryString 脱敏后值变化 |
| DNS 测试 | Tests/LeapinNetTests/DNSTests.swift | DNSConfig 新增 `nameserverPolicy`/`fakeIPFilter` 字段（Codable 默认值需谨慎） |

### 9.2 运行时回归
- `PolicyResolver.validate` 对空组的报错：CI-07 若只改「不丢组」而不展开 provider，导入后 `start()` 会失败。必须同时实现 provider 展开或显式降级。
- `RuleEngine` 在 :86 的 `policy.isEmpty ? "DIRECT"`：RP-03 修完后，同一份配置的路由结果会变（本来直连的现在走 PROXY）。属于**行为修复**，但需要同步更新 README/示例与 golden 断言。
- `LeapinEngine.importProfile`（Sources/LeapinRuntime/LeapinEngine.swift:209-217）导入后立即 `setActive` 并重启代理：一份坏配置会打断用户正在跑的代理。EN-03 落地时应先「解析 + 校验」通过再切换 active（`ProfileValidator.validate` 若存在则复用）。
- `ProfileStore.activeProfile()`（:89-99）首启动会写默认 profile：EN-04 去重时不要误删它。

### 9.3 数据兼容
- `Profile` 加字段：旧 JSON 解码走 `decodeIfPresent`/默认值即可；新 JSON 在旧版本会丢字段（可接受），但 `schemaVersion` 必须先加（EX-10）。
- `OutboundType` 扩枚举：旧 JSON 的 rawValue 仍在集合内 → 兼容；**不要**引入 associated value（Codable 会变成嵌套结构，破坏现有文件）。
- `ProfileFormat` 扩 case：`CaseIterable` 驱动的 UI 菜单会自动多出项（这是想要的效果），但 `leapin` 的 rawValue 匹配问题（EN-06）必须先修。

### 9.4 安全
- HR-01 是**已存在的隐私缺陷**：用户导出的 HAR 里 `queryString` 为明文 token。优先级应高于所有「功能完整性」项。
- 导入不可信配置的风险：`rule-providers.url`、`proxy-providers`、订阅 URL 会触发网络请求 → 需要 `https` 优先、大小上限（RS-03）、`file://` 默认拒绝、SSRF 防空（拒绝 `127.0.0.1`/`169.254.169.254` 等内网字面量）。

### 9.5 性能
- 实测（本机，独立 harness）：`RuleParser.parseRules` 5 万行 = 216ms(-O) / 459ms(-Onone)；`FilterParser.parse` 10 万行 = 78ms / 363ms；MiniYAML 5000 个 proxy + 1 万条 rule = 71ms / 145ms。
- 结论：PLAN P3 的「1MB / 5 万行 < 2s」**当前已满足**，且余量 ≥4x。**不要**为此做过度优化；真正的耗时在订阅下载（RS-03 的串行 15s×N）。

### 9.6 已排除的误判（避免返工）
- 曾怀疑 Sources/LeapinNet/Capture/HARExporter.swift:139 与 :252 的 `bodyText(_:redact:)` 构成非法重载。**实测排除**：把 LeapinCore 全量 + HARExporter 拷到 /tmp，补一个 `HTTPStatusText` stub 后 `xcrun swiftc -typecheck` **exit 0**。Swift 允许仅返回类型不同的重载（:251 是元组版包装器）。不要动这两个函数。

---

## 附录 A：实测复现（/tmp，未触碰仓库 .build）

```bash
# MiniYAML 边界
mkdir -p /tmp/tfmini && cp Sources/LeapinCore/MiniYAML.swift /tmp/tfmini/
# 写 main.swift 逐条打印，然后：
xcrun swiftc -O -o /tmp/tfmini/mini /tmp/tfmini/MiniYAML.swift /tmp/tfmini/main.swift && /tmp/tfmini/mini

# 规则/过滤器（去掉包内 import 后单模块编译）
mkdir -p /tmp/tfp && cp Sources/LeapinCore/{MiniYAML,Models}.swift Sources/LeapinPolicy/Support/IPAddress.swift \
     Sources/LeapinPolicy/Rules/RuleParser.swift Sources/LeapinPolicy/AdBlock/FilterParser.swift /tmp/tfp/
sed -i '' '/^import LeapinCore$/d' /tmp/tfp/*.swift
xcrun swiftc -O -o /tmp/tfp/tfp /tmp/tfp/*.swift && /tmp/tfp/tfp

# HARExporter 类型检查
mkdir -p /tmp/tfhar2 && cp Sources/LeapinCore/*.swift Sources/LeapinNet/Capture/HARExporter.swift /tmp/tfhar2/
# 补 enum HTTPStatusText { static func reason(for: Int) -> String } 后：
xcrun swiftc -typecheck /tmp/tfhar2/*.swift   # EXIT=0
```

关键实测输出（摘要）：
- `DOMAIN-SUFFIX,*.google.com` → `value=[*.google.com] matches=false`
- `GEOSITE / DST-PORT / PROCESS-PATH / IP-SUFFIX / NETWORK / SUB-RULE / IP-ASN / SRC-PORT` → 全部 `ERR unknownType`
- rule-set yaml `payload:` + `+.google.com`/`.blogger.com` → `rules=2 errors=3`
- ABP 样本：`|https://cdn.example.com/ads/banner.js` → `domain=cdn.example.com`（整域拦）；`/ads/banner/*$image` 未入 block；`$domain=` 无作用域；`~excl##.ad` → `domain=*`；`0.0.0.0 a b c` → 仅 `a`
- BOM：`FilterParser` block=2，首条 `domain=nil`（BOM 污染）；MiniYAML 顶层键带 `\u{FEFF}`

## 附录 B：本审计未做的事
- 未执行 `swift build` / `swift test`（约束要求避免与主窗口抢锁）。
- 未修改任何 `.swift`；未创建分支或提交。
- 未覆盖 Sing-box（明确排除）、未覆盖 MITM 证书链与 ProxyServer 的协议实现（超出格式范围）。

---

## 10. P3 落地结果（2026-11-05，审计后实施）

> 本节是「审计 → 实施」的闭环记录，结论可复核：构建与测试均在 `/tmp/tf-format-build` 独立 scratch path 完成，未占用仓库 `.build`。

### 10.1 已修复的审计项

| 差距 ID | 落地位置 | 结果 |
| --- | --- | --- |
| MY-01 BOM | Sources/LeapinCore/MiniYAML.swift:57 | parse 入口剥 U+FEFF；Clash 顶层键不再被污染为「空文档」 |
| MY-02 静默截断 | Sources/LeapinCore/MiniYAML.swift | 残留行不再静默丢弃，抛 `MiniYAMLError.parse("unsupported YAML construct: ...")`，由导入器转成 parseError 诊断 |
| RP-03 `*.x` 永不命中 | Sources/LeapinPolicy/Rules/RuleParser.swift:132、:187 | DOMAIN-WILDCARD / DOMAIN-SUFFIX 归一化循环剥 `*.`、`.`；`DOMAIN-SUFFIX,*.google.com` 现在能命中 www.google.com |
| RP-04 rule-set 成员 | Sources/LeapinPolicy/Rules/RuleParser.swift:76-81、makeRuleSetMember | `payload:`/`rules:` 行被跳过；`+.x`/`.x`/`*.x`/CIDR 成员可解析，policy 为空且不再注入默认策略 |
| RP-05 空规则回填 | Sources/LeapinPolicy/Format/ProfileImportExport.swift（clash 分支） | 不再注入 ProfileDefaults.baseRules；「0 条规则」保持 0 条，语义不被偷换 |
| MD-01..05 模型 | Sources/LeapinCore/Models.swift | OutboundType 增 vmess/vless/hysteria/hysteria2/tuic/wireguard/snell/unsupported；OutboundConfig 增 rawType/uuid/alterId/flow/network/wsPath/wsHost/grpcServiceName/security/skipCertVerify/udp/alpn/publicKey/shortID/obfs/obfsPassword/plugin/pluginOpts；PolicyGroup 增 rawType/use/filter/excludeFilter/includeAll；新 RuleProvider；DNSConfig 增 nameserverPolicy/fakeIPFilter；Profile 增 ruleProviders/proxyProviders。全部 `decodeIfPresent`，旧 profile.json 可直接读 |
| CI-01 未知协议静默丢 | Sources/LeapinPolicy/Format/ProfileImportExport.swift（clashOutbounds / parseSurgeProxy） | 未知类型映射 `.unsupported` 并保留 `rawType` 与原始键（extra），同时产出 unknownProtocol 诊断，不再 `continue` |
| CI-03 未知组类型 | Sources/LeapinPolicy/Format/ProfileImportExport.swift（clashGroups / parseSurgeGroup） | 回落 select 但保留 `rawType`（relay 不复写成 select 导出），并产出 unknownGroupType 诊断；`use/filter/include-all` 被读取，provider 组成立或显式诊断 |
| CI-05 诊断 | Sources/LeapinPolicy/Format/ProfileImportExport.swift（ImportIssue/ImportReport/ProfileImportOutcome） | 每条问题带 kind/line/item/message/display；report.summary 可直接进 toast；`ProfileStore.importFileDetailed(at:)`、`LeapinEngine.importProfileDetailed(from:)` 已暴露 |
| FP-01 `$domain=` | Sources/LeapinPolicy/AdBlock/FilterParser.swift + AdBlockEngine.swift:215-228 | FilterRule 增 scope/excludedScope/pathPrefix；`ruleMatches` 逐条校验，局部规则不再升级为全局拦截 |
| FP-02 路径规则整域拦 | Sources/LeapinPolicy/AdBlock/FilterParser.swift（splitAnchoredURL）、AdBlockEngine.swift | `|https://cdn/ads/x.js` 解析成 host + pathPrefix；无 path 时不拦，`verdict(for:path:thirdParty:)` 才判 |
| FP-03 BOM | Sources/LeapinPolicy/AdBlock/FilterParser.swift:67 | 剥 0xEF/0xBB/0xBF，首条规则不再降级成 keyword |
| SI-01..06 Surge | Sources/LeapinPolicy/Format/ProfileImportExport.swift | [General]/[Proxy]/[Proxy Group]/[Rule]/[Host] 全解析；未知段/未知 kv/不可解析行均进诊断；组支持 select/url-test/fallback/load-balance + url/interval/tolerance/policy-regex-filter |
| SI-07 http-listen 往返 | Sources/LeapinPolicy/Format/ProfileImportExport.swift | 导入写 mixedPort、导出读 mixedPort，往返一致 |
| EX-01 引号 | Sources/LeapinPolicy/Format/ProfileImportExport.swift（yamlScalar） | 覆盖冒号/井号/逗号/方括号/花括号/&*!|>/%@`/前导短横/空串/换行/反斜杠 |
| EX-02 未知类型导出 | Sources/LeapinPolicy/Format/ProfileImportExport.swift（clashOutbound） | 有 rawType 用 rawType，否则 `unsupported` 不被写成 direct |
| EX-03 url-test 缺参数 | Sources/LeapinPolicy/Format/ProfileImportExport.swift（clashGroups/surgeGroups） | 组导出带 url/interval/tolerance；空 proxies 组不再输出 |
| SU-01 订阅 | Sources/LeapinPolicy/Format/ProfileImportExport.swift（SubscriptionImporter） | 整段 base64、逐行 URI、ss://（SIP002 与 legacy）、trojan://、vless://、vmess://、hysteria2:// 均可导入；自动识别（looksLikeSubscription） |
| CLI-01 leapin | Sources/leapin/main.swift | export 用 `ProfileFormat(cliName:)`（clash/surge/json 及别名），未知格式报错不再静默回落；import 打印 report.summary 与前 10 条诊断；两者 `--help` |

### 10.2 构建与测试证据

```
xcrun swift build --build-tests --scratch-path /tmp/tf-format-build   # Build complete! (22.95s)  EXIT=0
xcrun swift test --scratch-path /tmp/tf-format-build                  # EXIT=0
```

| 套件 | 用例数 | 结果 |
| --- | --- | --- |
| LeapinPolicyTests（含新增 FormatTests 20 条） | 36 | 全绿 |
| LeapinNetTests | 69 | 全绿 |
| LeapinIntegrationsTests | 11 | 全绿 |
| LeapinCoreTests | 1 | 全绿 |
| 合计 | 117 | 0 failure |

新增测试（Tests/LeapinPolicyTests/FormatTests.swift，20 条）：Clash 字段保全、未知协议保留、BOM、空规则不回填、Clash 往返语义、YAML 标量引号往返、Surge 导入、Surge 往返、Surge 坏行诊断、`*.` 后缀可命中、rule-set 成员、`$domain=` 作用域、路径规则不整域拦、ABP BOM、整段 base64 订阅、ss SIP002/legacy、vmess+hysteria2、格式嗅探、旧 JSON 兼容、导入→导出→再导入等价。

### 10.3 仍未做的（明确边界，勿当成已完成）

1. **导出 hosts / ABP / rule-set 三种格式未实现**：`ProfileFormatKind` 仍只有 clash/surge/json（Sources/LeapinPolicy/Format/ProfileImportExport.swift:107-110）。PLAN P3 的「导出：规则集 / hosts / ABP」仍未达成。落地建议：在 Format 层加 `ProfileExporter.hosts/abp/ruleSet(profile:)`（纯函数，零 UI 依赖），Runtime 的 `ProfileFormat` 再加 3 个 case —— 该 enum 被 App 层 switch 消费，必须由 lead 协同改 App 侧，故本轮未动。
2. **远程订阅 URL 抓取未做**：目前订阅是「文本/URI 列表」导入；`http(s)://` 订阅链接需要异步下载 + 编码嗅探，属 Runtime 网络层，未在格式层实现。
3. **Sing-box 明确不做**（用户已排除）。
4. 性能未做优化，仅实测：5 万行规则 216ms（-O）/ 459ms（-Onone），已满足 <2s；真实瓶颈在订阅串行下载。

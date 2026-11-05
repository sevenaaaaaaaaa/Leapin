# TouchFlowPolicy 交付说明

> 目标：在不新增任何 SPM 依赖的前提下，实现 rules / policy group / adblock 三块的
> public API（签名见 `docs/ARCHITECTURE.md` 第 3 节），并对超出本轮范围的行为做**诚实降级**——
> 所有简化、近似、未实现点都在本文列出，没有静默偏离。

## 0. 文件布局

```
Sources/TouchFlowPolicy/
  _Target.swift                 模块版本号占位（原有）
  Support/IPAddress.swift       IPParse(ipv4/ipv6) / CIDR / HostNormalizer
  Rules/RuleParser.swift        RuleParser + RuleParseError
  Rules/RuleEngine.swift        RuleEngine + RuleMatch + Prepared/Evaluation
  Rules/PolicyResolver.swift    PolicyResolver
  Rules/GeoIPDatabase.swift     内置最小 GeoIP 表
  Rules/RuleSetLoader.swift     RuleSetLoader（本地 + http(s) + 磁盘缓存）
  AdBlock/FilterParser.swift    FilterRule / CosmeticRule / FilterParser
  AdBlock/AdBlockEngine.swift   AdBlockEngine（反转标签 Trie）
Tests/TouchFlowPolicyTests/
  PolicyTests.swift             14 个用例（见第 8 节）
  PlaceholderTests.swift        模块可加载冒烟用例（原有，保留）
```

依赖：仅 `TouchFlowCore`（`OutboundConfig`/`Profile`/`Rule`/`ConnectionMeta`/`RouteDecision`/
`BlockVerdict`/`TFLog`）。`Foundation` 之外无第三方库。

## 1. RuleParser

支持（全部大小写不敏感，`_` 与 `-` 等价，`RuleKind.parse` 复用 Core 的映射）：

| 写法 | 说明 |
| --- | --- |
| `DOMAIN,example.com,PROXY` | 精确域名 |
| `DOMAIN-SUFFIX,x.com,DIRECT,no-resolve` | 后缀；`no-resolve` 等修饰符原样收进 `Rule.modifiers` |
| `DOMAIN-KEYWORD,ads,REJECT` / `DOMAIN-REGEX,^a.*$` | 关键字 / 正则（正则做合法性校验） |
| `IP-CIDR,1.2.3.0/24,PROXY` / `IP-CIDR6,2001:db8::/32,PROXY` | 真实前缀解析并规范化（`1.2.3.4/24` → `1.2.3.0/24`） |
| `SRC-IP-CIDR,...` | 能解析（见 §2 的降级说明） |
| `PROCESS-NAME,WeChat,DIRECT` | 进程名 |
| `GEOIP,CN,DIRECT` | 国家码（统一大写） |
| `RULE-SET,ads,REJECT` | 规则集引用 |
| `MATCH,PROXY` / `FINAL,PROXY` | 兜底（都映射到 `RuleKind.match`） |
| `AND,((DOMAIN,a.com),(DOMAIN-SUFFIX,b.com)),PROXY` | `AND`/`OR`/`NOT`，递归嵌套（嵌套时 value 被重写成规范形 `((TYPE,value),…)`） |
| `!DOMAIN,neg.test,REJECT` | 前缀 `!` → `Rule.negate` |
| `# 行内注释` | `#`（前面是空白时）截断；引号内的 `#` 保留；整行 `#`/`//` 视为注释 |
| YAML | 行首 `- ` 前缀；整行或单个字段被 `"…"` / `'…'` 包住时去引号 |

导出：`exportSurge` / `exportClash` 复用同一 `exportLine`，区别只有兜底规则写成
`FINAL,<policy>`（Surge）或 `MATCH,<policy>`（Clash）。`parse → export → parse`
在 kind/value/policy/negate/modifiers 上等价（round-trip 用例覆盖 10 种规则形态）。

明确不支持（解析期抛 `unknownType`/`invalidValue`，由 `parseRules` 计入 `errors` 并给出
`line N: …`）：`GEOSITE`、`IP-ASN`、`SCRIPT`、`SUB-RULE`、`SRC-PORT`/`DST-PORT`、
Clash 的 `MATCH` 省略策略写法；`DOMAIN-WILDCARD` 降级成 `DOMAIN-SUFFIX`（不做通配符）。
`exportLine` 不做逗号/引号转义：策略名或域名本身含逗号时 round-trip 会失真（当前 profile
方言里不会出现，故未实现转义）。

## 2. RuleEngine

- `decide(_:)` = `explain(_:)` + `PolicyResolver(profile:)` 解析策略名；`REJECT` 或
  reject 组 → `RouteDecision.isBlocked == true`。
- 顺序语义：按 profile 规则数组顺序求值，**首个命中**即返回（`RULE-SET` 内部同样按顺序）。
- `explain(_:)` 返回 `RuleMatch`，`trace` 第一行是 `host=… port=… ip=… app=…` 摘要，之后逐条
  `✓ #n <raw> → <policy>` / `✗ #n <raw> (<note>)`，命中后追加 `matched rule #n of N`，
  无命中以 `no rule matched → DIRECT` 结束；最多 200 行，超出折叠成 `… K more rules not shown`
  （避免 10k 规则的 UI 卡顿）。
- 求值器递归支持 `AND`(全部) / `OR`(任一) / `NOT`(取反)，深度上限 16 层，`negate` 对最终
  布尔取反；`AND/OR/NOT` 的 value 在 `prepare` 阶段重新解析成子规则。
- IP-CIDR / IP-CIDR6：`CIDR` 做真实按位前缀匹配（IPv4 走 `UInt32` 化的字节掩码，IPv6 走 16 字节），
  只匹配 `meta.destinationIP`；`destinationIP` 为空时不匹配（note `no destination IP`）。
- `no-resolve`：**仅作为语义标注**——引擎本身从不做 DNS（没有 resolver 依赖），
  所以「no-resolve 时不查 DNS」自动成立，note 记 `no-resolve` 便于 UI 展示。
- `PROCESS-NAME`：对 `meta.sourceApp` 与 `meta.sourceBundleID` 做大小写不敏感比较，接受三种形式：
  全串相等、`lastPathComponent` 相等、`WeChat.app` 去掉 `.app` 后相等（`/Applications/WeChat.app`
  可被 `PROCESS-NAME,WeChat` 命中）。
- `GEOIP`：查 `GeoIPDatabase`（可注入），无 IP 或库内未知 → 不匹配，note `geo unknown`；不崩。
- `RULE-SET,name,POLICY`：名字大小写不敏感查 `ruleSets`；未加载 → 不匹配（note `rule set 'x' not
  loaded`）而不是抛错；集合内规则命中后按 Surge 语义用**外层策略**覆盖（外层策略为空时保留成员规则
  自己的策略）；集合递归有 visited 栈保护。
- `ruleCount` = profile 规则数 + 所有已加载规则集条目数。
- **降级**：`SRC-IP-CIDR` 恒不匹配（`ConnectionMeta` 不携带源 IP），note `source IP unavailable`。

## 3. PolicyResolver

选择顺序（严格按 Lead 确认的优先级）：

1. 调用方传入的 `selections[组名小写]`；
2. `group.selected`（仅当它确实在 `group.proxies` 里）；
3. select / fallback：`proxies.first`；load-balance：`proxies` 轮转（每次 resolve 前进一格）；
4. 都没有 → `OutboundConfig.direct`。

- 组内成员可以是另一个组名：递归展开，带路径栈防环；命中环时 `resolve` 回落 DIRECT 并
  `TFLog.warn("policy", "policy group cycle detected: …")`。
- `reject` 类型组直接返回 `OutboundConfig.reject`；成员名 `DIRECT`/`REJECT` 直接映射到对应
  outbound；其余名字按 `profile.outbound(named:)`（大小写不敏感）找具体 outbound。
- 未知策略名（既不是组也不是 outbound）→ 回落 DIRECT，`validate()` 会报告。
- `validate()` 报告：`group.selected` 不在 proxies 内的、组引用了不存在的策略的、组环、以及
  规则里引用了未知策略的；返回人类可读字符串数组（不抛错）。
- `policyNames` = 所有组名 + 所有 outbound 名。
- 额外便利 API（非契约，供 UI 用）：`selections`（当前覆盖表快照）、`setSelection(group:outbound:)`。
- **降级**：`url-test` 不做真实探测/测速，等价于「取第一个成员」；`fallback` 同样取首个。
  真实健康检查属于 Runtime/Net 的职责，本模块只做静态解析。

## 4. 去广告：FilterParser + AdBlockEngine

FilterParser 支持（`!`/`[Adblock Plus 2.0]` 头注释与 `#` 注释跳过）：

- `||domain^` / `||domain` → 后缀规则（含子域）；
- `|http://host/path` / `|https://…` → 精确 host 锚定（只匹配该 host，不含子域）；
- `@@…` 前缀 → 例外（allow）规则；
- `$third-party` / `$3p` → `thirdPartyOnly`；
- hosts 行 `0.0.0.0 domain` / `127.0.0.1 domain` / `::1 domain`（取该行第一个非 `localhost` 域名）；
- `domain##selector` → 元素隐藏；`domain#@#selector` → 元素隐藏例外；`##selector`（无域名）→ 全局 `*`。

AdBlockEngine：

- 数据结构：**反转标签 Trie**（`com` → `example` → `ads`），单次查询 O(labels) 次字典跳转，
  与规则总数无关；另有 `blockKeywords`/`allowKeywords` 线性表处理无域名的关键字规则。
- 匹配顺序（例外优先）：`allowList`（后缀匹配，reason `allow-list: <domain>`）→ allow 规则
  （trie + 关键字）→ block 规则；`verdict(for:thirdParty:)` 的 `reason` 是**命中的原始规则行**，
  供 UI 展示「为什么被拦」；命中 block 时同时带上 `cosmeticSelectors(for:)`。
- `thirdPartyOnly` 规则只在 `thirdParty == true` 时参与匹配。
- 元素隐藏：`cosmeticSelectors(for:)` 按域后缀收集选择器，先扣掉 `#@#` 例外，再按首次出现顺序去重。
- `ruleCount` = block + allow + cosmetic + allowList 条数。
- `load(listPaths:allowList:)`：读不到的文件记 warn 后跳过，不抛错（仅保留 `throws` 签名兼容）。

**降级 / 未实现**：通配符 `*`、正则过滤器 `/re/`、路径与查询串匹配（只按域名）、`$domain=` /
`$~third-party` 等其余选项（不认识时整行退回普通 pattern 解析）、`#?#`/`#$#` 等扩展选择器（跳过）、
元素隐藏里 `a.com,~sub.a.com` 的多域/排除语法（整串当作一个 domain key）。

性能（100 000 条 `||host{i}.zone{i%977}.test^`，本机 macOS 27 / Apple silicon）：

| 阶段 | debug (-Onone) | release |
| --- | --- | --- |
| FilterParser.parse | ~0.30 s | ~0.28 s |
| AdBlockEngine 建 Trie | ~0.31 s | ~0.12 s |
| 合计装载 | ~0.61 s（预算 1 s） | ~0.41 s |
| 单次 verdict | ~7 µs（预算 50 µs） | ~2.5 µs |

计时方法：性能断言一律取 **best-of-3（装载/查询）与 best-of-5（decide）** 的最小样本，
单次采样在整套测试并行运行时会被调度噪声污染（曾经出现过一次 1.0s 阈值的假失败）。
断言阈值仍等于真实预算，没有放宽。

实现要点：解析走字节级行扫描（`Array(text.utf8).split(0x0A)`）并为 `||host^` 提供零字符串分配的
快速路径；Trie 插入只做字典写入，不重复扫描。

## 5. RuleSetLoader

`load(sources:cacheDirectory:)` 是 `async`、不抛错：对每个 source

- 本地路径（`~` 展开；相对路径先按当前目录，失败再按 cacheDirectory）；
- `http(s)://` URL：`URLSession.shared` 拉取，成功写缓存
  `<cacheDirectory>/rule-sets/<FNV-1a64(source)>.<ext>`；
- 网络失败/非 2xx → 退回缓存文件（`TFLog.warn`），缓存也没有 → 空数组（`TFLog.warn`），不崩；
- 内容过 `RuleParser.parseRules`，单行错误只记一条汇总 warn（`skipped N line(s) — <首个错误>`）；
- 返回 `[名字: [Rule]]`，名字 = 文件名去扩展名（小写）。

## 6. GeoIPDatabase

- 内置 **50 条 CN 前缀**（`1.0.1.0/24`、`1.2.0.0/23`、`14/8`、`27/8`、`36/8`、`39/8`、`42/8`、
  `49/8`、`58/7`、`59/8`、`60/7`、`61/8`、`101/8`、`103/8`、`106/8`、`110/7`、`111/8`、`112/5`、
  `113/8`、`114/8`、`115/8`、`116/8`、`120/6`、`124/7`、`125/8`、`171/8`、`175/8`、`180/8`、
  `182/8`、`183/8`、`202.96/12`、`203.208.32/19`、`211/8`、`218~223/8`… 等）；
- 10 条常见 US 段（`1.1.1.0/24`、`8.8.8.0/24`、`8.8.4.0/24`、`13.32/15`、`23/12`、`104.16/13`、
  `142.250/15`、`151.101/16`、`199.232/16`、`1.0.0.0/24`）；
- 13 条保留段 → `"PRIVATE"`（`10/8`、`172.16/12`、`192.168/16`、`127/8`、`169.254/16`、`0/8`、
  `100.64/10`、`198.18/15`、`192.0.2/24`、`198.51.100/24`、`203.0.113/24`、`224/4`、`240/4`）
  以及 IPv6 保留 `::1/128`、`fe80::/10`、`fc00::/7`、`::/128`；
- `country(of:)` 返回 `"CN"`/`"US"`/`"PRIVATE"`，未知（含全部 IPv6 公网地址）返回 `nil`；
  区间按起点排序后二分/线性扫描，不抛错。
- **诚实说明**：这不是 GeoIP 库。CN 用了若干 `/8` 聚合（如 `14/8`、`27/8`），会**误判**部分
  非中国地址为 CN；表内没有 IPv6 归属。需要精确结果时应由 Runtime 换成真实库。

## 7. 额外（非契约）public API

为 UI/调用方便额外提供了少量零成本重载与工具，均不改动契约签名：
`RuleParser.parseRule(_:)`、`PolicyResolver.setSelection(group:outbound:)` / `selections`、
`AdBlockEngine.verdict(for:)` / `isBlocked(_:)`、`GeoIPDatabase.shared` / `contains(_:country:)`、
`CIDR` / `IPParse` / `HostNormalizer`（Support/IPAddress.swift，供 Net/Runtime 复用）。

## 8. 测试

`swift test --filter TouchFlowPolicyTests`：**14 个用例全绿**。

覆盖：Surge 样例、Clash 样例 + 大小写不敏感 + YAML 引号、AND/OR/NOT（含嵌套）、顺序与
`explain` trace、CIDR v4/v6 与 no-resolve、PROCESS-NAME/GEOIP、策略组（select/url-test/fallback/
load-balance 轮转/reject/嵌套/环/未知成员/validate/selections）、FilterParser 全语法、AdBlock
判定与例外优先与元素隐藏、10 万条装载与查询性能、1 万条规则 decide < 5 ms、导出 round-trip、
RuleSetLoader（临时目录 + 缺失路径降级空集）。

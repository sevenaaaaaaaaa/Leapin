# TouchFlow — v1 架构与契约

## 0. 产品定位（v1）
macOS 菜单栏 + 主窗口网络工具，融合 Surge/Clash 式能力：
- 本地混合代理（HTTP CONNECT / SOCKS5 / 普通 HTTP）＋ 规则分流（Surge/Clash 语法）
- 去广告（ABP 语法 + hosts + 跟踪器名单 + 轻量 cosmetic 过滤）
- 抓包（HTTP 明文 + 可选 HTTPS MITM，生成 HAR，脱敏导出）
- SSH 快速连接（系统 ssh + PTY，密码走 SSH_ASKPASS）
- NAS 快速发现/挂载（Bonjour + smb:// / mount_smb）
- 从 App 列表 / 截图 OCR 学习分流规则
- 隐私保护（DoH/DoT、日志与抓包脱敏、Keychain、隐私审计、系统代理一键开关）
- iOS 版走 NetworkExtension，v1 只保留跨平台 Core 边界（不在本阶段实现）

不做（v1 明确排除）：TUN/utun 内核级接管、iOS NE 打包、VMess/VLESS/Hysteria、HTTP/2 MITM、Wireshark 级 pcap。
依赖限制：**本机无法访问 github.com，禁止新增 SPM 依赖**，只用 Foundation / Network / Security / Vision / CryptoKit / AppKit / SwiftUI。

## 1. 目录与归属（禁止越界编辑）
```
Sources/TouchFlowCore/          lead（共享类型/协议/日志/YAML/Keychain）
Sources/TouchFlowPolicy/        worker-policy：Rules/ AdBlock/（可加 Policy 子目录）
Sources/TouchFlowNet/           worker-net：Proxy/ DNS/ Capture/
Sources/TouchFlowIntegrations/  worker-int：SSH/ NAS/ Learn/ Privacy/
Sources/TouchFlowRuntime/       lead：引擎装配、Profile 存储、CaptureStore
Sources/TouchFlowApp/           lead：SwiftUI
Sources/tfctl/                  lead：CLI
Tests/TouchFlowPolicyTests/     worker-policy
Tests/TouchFlowNetTests/        worker-net
Tests/TouchFlowIntegrationsTests/ worker-int
docs/                           lead（各 worker 可写自己模块的 README.md）
```
每个 worker 只 `swift build --target <自己的 target>`（会连带编译 Core），必须保证零 error；测试用 `swift test --filter <自己的测试类>`。
不得修改 Package.swift、Core、其他 worker 目录。

## 2. Core 已提供
- `OutboundType/.direct/.reject`, `OutboundConfig`, `RuleKind`, `Rule`, `PolicyGroup`, `PolicyGroupType`, `DNSConfig/DNSMode`, `AdBlockConfig`, `GeneralConfig`, `Profile`
- `ConnectionMeta`, `RouteDecision`, `FlowEvent/FlowPhase`, `BlockVerdict`, `CapturedRequest`, `LogLevel`
- 协议：`ByteStream`（NWByteStream 实现）、`RouteDeciding`、`DomainBlocking`、`FlowRecording`、`CaptureSink`、`NameResolving`
- `TFLog.shared`（自动脱敏）、`Redactor`、`MiniYAML`、`Keychain`

## 3. 模块契约（public API，必须逐字实现，可增加但不可改名）
### TouchFlowPolicy
```swift
public struct RuleMatch: Sendable {
    public var matchedRule: Rule?
    public var policy: String
    public var trace: [String]          // 人类可读的判定过程，UI 直接展示
}
public final class RuleEngine: RouteDeciding {
    public init(profile: Profile, ruleSets: [String: [Rule]] = [:], geoIP: GeoIPDatabase? = nil)
    public func decide(_ meta: ConnectionMeta) -> RouteDecision
    public func explain(_ meta: ConnectionMeta) -> RuleMatch
    public var ruleCount: Int { get }
}
public enum RuleParser {
    public static func parse(line: String) throws -> Rule
    public static func parseRules(_ text: String) -> (rules: [Rule], errors: [String])
    public static func exportSurge(_ rules: [Rule]) -> String
    public static func exportClash(_ rules: [Rule]) -> String
}
public final class PolicyResolver: @unchecked Sendable {
    public init(profile: Profile, selections: [String: String] = [:])
    public func resolve(_ policy: String) -> OutboundConfig   // 组名递归展开，未知策略回落 DIRECT
    public var policyNames: [String] { get }
    public func validate() -> [String]                         // 悬空策略/空组
}
public struct FilterRule: Sendable, Hashable { public var raw: String; public var domain: String?; public var isException: Bool; public var thirdPartyOnly: Bool }
public struct CosmeticRule: Sendable, Hashable { public var domain: String; public var selector: String; public var isException: Bool }
public enum FilterParser {
    public static func parse(_ text: String) -> (block: [FilterRule], allow: [FilterRule], cosmetic: [CosmeticRule])
}
public final class AdBlockEngine: DomainBlocking, @unchecked Sendable {
    public init(blockRules: [FilterRule] = [], allowRules: [FilterRule] = [], cosmeticRules: [CosmeticRule] = [], allowList: [String] = [])
    public static func load(listPaths: [String], allowList: [String] = []) throws -> AdBlockEngine
    public func verdict(for domain: String, thirdParty: Bool) -> BlockVerdict
    public func cosmeticSelectors(for domain: String) -> [String]
    public var ruleCount: Int { get }
}
public enum RuleSetLoader {  // 本地文件或 http(s)，带磁盘缓存；失败降级为空并记录
    public static func load(sources: [String], cacheDirectory: URL) async -> [String: [Rule]]
}
public final class GeoIPDatabase: @unchecked Sendable {  // 内置最小 CN 段表即可；未知返回 nil
    public init(); public func country(of ip: String) -> String?
}
```
要点：规则匹配顺序＝文件顺序，首个命中即返回；`no-resolve` 表示不做 DNS；`PROCESS-NAME` 大小写不敏感匹配 `meta.sourceApp`；`IP-CIDR` 命中 `destinationIP`（无则返回 false）；`MATCH` 兜底；目标策略先经 `PolicyResolver` 解析成 `OutboundConfig`，`REJECT` → `isBlocked=true`。
AdBlock 匹配：ABP `||domain^`、`|http://`、`@@` 例外优先、`$third-party`、hosts 行；纯域名后缀匹配用反转标签 Trie，10 万条 < 50ms 加载。

### TouchFlowNet
```swift
public final class ProxyServer: @unchecked Sendable {
    public struct Options: Sendable {
        public var port: UInt16; public var allowLAN: Bool
        public var enableSOCKS5: Bool; public var enableHTTP: Bool
        public var mitm: Bool; public var mitmHosts: [String]
        public init(port: UInt16, allowLAN: Bool = false, enableSOCKS5: Bool = true,
                    enableHTTP: Bool = true, mitm: Bool = false, mitmHosts: [String] = ["*"])
    }
    public init(options: Options, router: RouteDeciding, resolver: NameResolving,
                blocker: DomainBlocking?, flows: FlowRecording?, capture: CaptureSink?,
                ca: CertificateAuthority? = nil)
    public func start() throws
    public func stop()
    public var isRunning: Bool { get }
    public var activeConnections: Int { get }
}
public struct OutboundDialer: Sendable {
    public init(resolver: NameResolving)
    public func connect(via outbound: OutboundConfig, host: String, port: UInt16) async throws -> ByteStream
}
public final class DNSResolver: NameResolving, @unchecked Sendable {
    public init(config: DNSConfig, blocker: DomainBlocking? = nil)
    public func resolve(_ host: String) async throws -> [String]
    public func flushCache()
}
public final class FakeIPPool: @unchecked Sendable {
    public init(range: String)
    public func ip(for host: String) -> String
    public func host(for ip: String) -> String?
}
public final class DNSServer: @unchecked Sendable {   // UDP+TCP，127.0.0.1:config.listenPort
    public init(port: UInt16, resolver: DNSResolver, blocker: DomainBlocking?, fakeIP: FakeIPPool?)
    public func start() throws
    public func stop()
}
public final class CertificateAuthority: @unchecked Sendable {  // 调 /usr/bin/openssl 生成/缓存 CA 与叶证书
    public init(directory: URL) throws
    public var caCertificateURL: URL { get }
    public func identity(for host: String) throws -> sec_identity_t
}
public enum HARExporter {
    public static func export(_ requests: [CapturedRequest], redact: Bool = true) throws -> Data
}
```
要点：协议嗅探按首字节（0x05 SOCKS5 / 大写方法 HTTP）；CONNECT 后用 `BytePump` 双向转发并统计字节；HTTPS MITM 仅 HTTP/1.1，证书用 openssl 生成、SecPKCS12Import 载入；所有失败必须写日志并关闭连接，不得 crash；DNS 支持 DoH(URLSession)/DoT(NWConnection TLS)/UDP、缓存 TTL、hosts、blocker 返回 NXDOMAIN。10 万条规则下 decide 已由 Policy 保证，Net 只调用一次。

### TouchFlowIntegrations
```swift
public struct NASDevice: Sendable, Identifiable, Hashable {
    public var id: String; public var name: String; public var host: String
    public var port: UInt16; public var service: String; public var model: String?
}
public final class NASDiscovery: @unchecked Sendable {
    public init()
    public func start(onUpdate: @escaping ([NASDevice]) -> Void)
    public func stop()
}
public enum NASMounter {
    public static func openInFinder(host: String, share: String? = nil) throws
    public static func mountSMB(host: String, share: String, user: String, password: String) throws -> URL
}
public struct LearnedApp: Sendable, Codable, Identifiable, Hashable {
    public var id: String { bundleID ?? name }
    public var name: String; public var bundleID: String?; public var domains: [String]; public var source: String
}
public enum AppListParser { public static func parse(text: String) -> [LearnedApp] }
public struct OCRResult: Sendable { public var text: String; public var lines: [String]; public var confidence: Double }
public enum ScreenshotOCR {
    public static func recognize(imageURL: URL) throws -> OCRResult
    public static func recognize(cgImage: CGImage) throws -> OCRResult
}
public struct RuleSuggestion: Sendable, Identifiable {
    public var id: String; public var appName: String; public var domain: String
    public var rule: Rule; public var confidence: Double; public var rationale: String
}
public enum RuleSuggester {
    public static func suggest(apps: [LearnedApp], flows: [FlowEvent], catalog: [LearnedApp]) -> [RuleSuggestion]
}
public enum AppCatalog { public static let builtin: [LearnedApp] }   // ≥30 个常见 App/服务
public actor SSHSession {
    public init()
    public func connect(host: String, port: UInt16, user: String, password: String?, keyPath: String?, knownHosts: String) async throws
    public func write(_ text: String) async
    public func resize(cols: Int, rows: Int) async
    public func disconnect() async
    public var outputHandler: (@Sendable (String) -> Void)? { get set }
    public var isConnected: Bool { get }
}
public struct SystemProxyStatus: Sendable { public var enabled: Bool; public var host: String; public var port: Int }
public enum SystemProxy {
    public static func status() -> SystemProxyStatus
    public static func enable(host: String, port: Int, socksPort: Int) throws
    public static func disable() throws
}
public struct PrivacyFinding: Sendable, Identifiable { public var id: String; public var app: String; public var domain: String; public var category: String; public var severity: Int }
public struct PrivacyReport: Sendable { public var findings: [PrivacyFinding]; public var trackersBlocked: Int; public var score: Int }
public enum PrivacyAudit {
    public static func audit(flows: [FlowEvent], trackerDomains: Set<String>) -> PrivacyReport
}
```
要点：SSH 用 `/usr/bin/ssh -tt`；密码走 `SSH_ASKPASS` 临时脚本 + `SSH_ASKPASS_REQUIRE=force` + `DISPLAY=:0`，脚本 0600 且会话结束即删；`knownHosts` 支持 `accept-new`。OCR 用 Vision（`VNRecognizeTextRequest`，`.accurate`，中英双语）。所有命令行工具调用必须设超时、捕获 stderr、错误转 `TouchFlowError`。

## 4. 构建与验收
- `swift build --target <target>` 零 error；警告尽量清零
- `swift test --filter <ModuleTests>` 全绿
- 每个 worker 交付 `docs/<module>.md`：已实现 / 简化 / 未实现清单（诚实）
- 不允许 `fatalError`、强制解包崩溃、把密码写进日志/argv（ssh 密码除外需注释说明）

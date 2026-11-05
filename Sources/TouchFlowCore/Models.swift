import Foundation

// MARK: - Outbound configuration

public enum OutboundType: String, Codable, Sendable, CaseIterable {
    case direct
    case http
    case socks5
    case shadowsocks
    case trojan
    case reject
    // Protocols that can be imported/exported verbatim but are not dialable yet.
    // Keeping them distinct means a Clash/Surge profile no longer loses nodes on
    // round-trip (see docs/audit-formats.md, MD-01).
    case vmess
    case vless
    case hysteria
    case hysteria2
    case tuic
    case wireguard
    case snell
    /// Unknown protocol token from an imported profile; see `OutboundConfig.rawType`.
    case unsupported

    /// Protocols TouchFlow can actually open a connection for today.
    public var isDialable: Bool {
        switch self {
        case .direct, .http, .socks5, .shadowsocks, .trojan, .reject: return true
        case .vmess, .vless, .hysteria, .hysteria2, .tuic, .wireguard, .snell, .unsupported: return false
        }
    }
}

public struct OutboundConfig: Codable, Sendable, Identifiable, Hashable {
    public var id: String { name }
    public var name: String
    public var type: OutboundType
    public var host: String
    public var port: UInt16
    public var username: String?
    public var password: String?
    /// shadowsocks cipher, e.g. aes-256-gcm / chacha20-ietf-poly1305
    public var cipher: String?
    /// trojan / https: use TLS
    public var tls: Bool
    /// SNI override for TLS outbounds
    public var sni: String?
    /// Original `type:` token from the source profile ("vmess", "hysteria2", ...).
    public var rawType: String?
    /// vmess / vless client id.
    public var uuid: String?
    /// vmess alterId, snell version, ...
    public var alterId: Int?
    /// vless `flow`, e.g. xtls-rprx-vision.
    public var flow: String?
    /// Transport: tcp / ws / grpc / h2 / http.
    public var network: String?
    public var wsPath: String?
    public var wsHost: String?
    public var grpcServiceName: String?
    /// TLS stack: tls / reality / none.
    public var security: String?
    public var skipCertVerify: Bool?
    public var udp: Bool?
    public var alpn: [String]?
    /// reality public key / short id.
    public var publicKey: String?
    public var shortID: String?
    public var obfs: String?
    public var obfsPassword: String?
    public var plugin: String?
    public var pluginOpts: String?
    /// Keys we parsed but do not model, kept verbatim so export does not lose them.
    public var extra: [String: String]

    public init(name: String, type: OutboundType, host: String = "", port: UInt16 = 0,
                username: String? = nil, password: String? = nil, cipher: String? = nil,
                tls: Bool = false, sni: String? = nil, rawType: String? = nil,
                uuid: String? = nil, alterId: Int? = nil, flow: String? = nil,
                network: String? = nil, wsPath: String? = nil, wsHost: String? = nil,
                grpcServiceName: String? = nil, security: String? = nil,
                skipCertVerify: Bool? = nil, udp: Bool? = nil, alpn: [String]? = nil,
                publicKey: String? = nil, shortID: String? = nil, obfs: String? = nil,
                obfsPassword: String? = nil, plugin: String? = nil, pluginOpts: String? = nil,
                extra: [String: String] = [:]) {
        self.name = name; self.type = type; self.host = host; self.port = port
        self.username = username; self.password = password; self.cipher = cipher
        self.tls = tls; self.sni = sni; self.rawType = rawType
        self.uuid = uuid; self.alterId = alterId; self.flow = flow
        self.network = network; self.wsPath = wsPath; self.wsHost = wsHost
        self.grpcServiceName = grpcServiceName; self.security = security
        self.skipCertVerify = skipCertVerify; self.udp = udp; self.alpn = alpn
        self.publicKey = publicKey; self.shortID = shortID
        self.obfs = obfs; self.obfsPassword = obfsPassword
        self.plugin = plugin; self.pluginOpts = pluginOpts
        self.extra = extra
    }

    public static let direct = OutboundConfig(name: "DIRECT", type: .direct)
    public static let reject = OutboundConfig(name: "REJECT", type: .reject)
}

// MARK: - Rules

public enum RuleKind: String, Codable, Sendable, CaseIterable {
    case domain
    case domainSuffix = "domain-suffix"
    case domainKeyword = "domain-keyword"
    case domainRegex = "domain-regex"
    case ipCIDR = "ip-cidr"
    case ipCIDR6 = "ip-cidr6"
    case srcIPCIDR = "src-ip-cidr"
    case processName = "process-name"
    case geoIP = "geoip"
    case ruleSet = "rule-set"
    case and
    case or
    case not
    case `match`

    /// Parses Surge/Clash style rule type tokens (case-insensitive, `_` == `-`).
    public static func parse(_ token: String) -> RuleKind? {
        var t = token.lowercased().replacingOccurrences(of: "_", with: "-")
        if t == "domain-suffix" || t == "domainsuffix" { return .domainSuffix }
        if t == "domain-keyword" || t == "domainkeyword" { return .domainKeyword }
        if t == "domain-regex" || t == "domainregex" { return .domainRegex }
        if t == "ip-cidr" || t == "ipcidr" { return .ipCIDR }
        if t == "ip-cidr6" || t == "ipcidr6" { return .ipCIDR6 }
        if t == "src-ip" { return .srcIPCIDR }
        if t == "process-name" || t == "processname" { return .processName }
        if t == "geoip" { return .geoIP }
        if t == "rule-set" || t == "ruleset" { return .ruleSet }
        if t == "final" { return .match }
        if t == "match" { return .match }
        if t == "and" { return .and }
        if t == "or" { return .or }
        if t == "not" { return .not }
        return RuleKind(rawValue: t)
    }
}

public struct Rule: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(kind.rawValue)|\(value)|\(policy)|\(raw)" }
    public var kind: RuleKind
    /// Rule payload: domain, cidr, regex, process name, rule-set name, or nested rule expression for and/or/not.
    public var value: String
    public var policy: String
    /// no-resolve / src / etc.
    public var modifiers: [String]
    public var negate: Bool
    /// Original line, kept for round-trip export and UI display.
    public var raw: String

    public init(kind: RuleKind, value: String, policy: String, modifiers: [String] = [], negate: Bool = false, raw: String = "") {
        self.kind = kind; self.value = value; self.policy = policy
        self.modifiers = modifiers; self.negate = negate; self.raw = raw
    }

    public var noResolve: Bool { modifiers.contains("no-resolve") }
}

// MARK: - Policy groups

public enum PolicyGroupType: String, Codable, Sendable, CaseIterable {
    case select
    case urlTest = "url-test"
    case fallback
    case loadBalance = "load-balance"
    case reject
}

/// Clash `rule-providers` / `proxy-providers` entry, kept for round-trip export
/// and for RuleSetLoader to resolve remote rule-sets.
public struct RuleProvider: Codable, Sendable, Identifiable, Hashable {
    public var id: String { name }
    public var name: String
    /// http / file / inline
    public var type: String
    /// domain / ipcidr / classical
    public var behavior: String
    public var url: String?
    public var path: String?
    public var interval: Int?
    public var format: String?
    /// Inline `payload:` rules (type == inline).
    public var payload: [String]
    /// Keys we do not model, kept verbatim for round-trip.
    public var extra: [String: String]

    public init(name: String, type: String, behavior: String = "classical", url: String? = nil,
                path: String? = nil, interval: Int? = nil, format: String? = nil,
                payload: [String] = [], extra: [String: String] = [:]) {
        self.name = name; self.type = type; self.behavior = behavior; self.url = url
        self.path = path; self.interval = interval; self.format = format
        self.payload = payload; self.extra = extra
    }
}

public struct PolicyGroup: Codable, Sendable, Identifiable, Hashable {
    public var id: String { name }
    public var name: String
    public var type: PolicyGroupType
    public var proxies: [String]
    public var url: String?
    public var interval: Int?
    public var tolerance: Int?
    /// Manual pick from the UI (nil = automatic / first proxy).
    public var selected: String?
    /// Source `type:` token when it is not one of `PolicyGroupType` (Clash `relay`,
    /// Surge `smart`/`subnet`). `type` is then only a runtime fallback.
    public var rawType: String?
    /// Clash `use:` — proxy-provider names.
    public var use: [String]
    /// Clash `filter:` / Surge `policy-regex-filter`.
    public var filter: String?
    /// Clash `exclude-filter:`.
    public var excludeFilter: String?
    /// Clash `include-all` / `include-all-proxies` / `include-all-providers`.
    public var includeAll: Bool

    public init(name: String, type: PolicyGroupType, proxies: [String], url: String? = nil,
                interval: Int? = nil, tolerance: Int? = nil, selected: String? = nil,
                rawType: String? = nil, use: [String] = [], filter: String? = nil,
                excludeFilter: String? = nil, includeAll: Bool = false) {
        self.name = name; self.type = type; self.proxies = proxies
        self.url = url; self.interval = interval; self.tolerance = tolerance; self.selected = selected
        self.rawType = rawType; self.use = use; self.filter = filter
        self.excludeFilter = excludeFilter; self.includeAll = includeAll
    }

    private enum CodingKeys: String, CodingKey {
        case name, type, proxies, url, interval, tolerance, selected
        case rawType, use, filter, excludeFilter, includeAll
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(PolicyGroupType.self, forKey: .type)
        proxies = try c.decodeIfPresent([String].self, forKey: .proxies) ?? []
        url = try c.decodeIfPresent(String.self, forKey: .url)
        interval = try c.decodeIfPresent(Int.self, forKey: .interval)
        tolerance = try c.decodeIfPresent(Int.self, forKey: .tolerance)
        selected = try c.decodeIfPresent(String.self, forKey: .selected)
        rawType = try c.decodeIfPresent(String.self, forKey: .rawType)
        use = try c.decodeIfPresent([String].self, forKey: .use) ?? []
        filter = try c.decodeIfPresent(String.self, forKey: .filter)
        excludeFilter = try c.decodeIfPresent(String.self, forKey: .excludeFilter)
        includeAll = try c.decodeIfPresent(Bool.self, forKey: .includeAll) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encode(proxies, forKey: .proxies)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(interval, forKey: .interval)
        try c.encodeIfPresent(tolerance, forKey: .tolerance)
        try c.encodeIfPresent(selected, forKey: .selected)
        try c.encodeIfPresent(rawType, forKey: .rawType)
        if !use.isEmpty { try c.encode(use, forKey: .use) }
        try c.encodeIfPresent(filter, forKey: .filter)
        try c.encodeIfPresent(excludeFilter, forKey: .excludeFilter)
        if includeAll { try c.encode(includeAll, forKey: .includeAll) }
    }
}

// MARK: - DNS

public enum DNSMode: String, Codable, Sendable {
    case system          // forward to system resolver
    case doh             // DNS-over-HTTPS upstream
    case dot             // DNS-over-TLS upstream
    case fakeIP          // synthesize fake IPs, resolve on connect
}

public struct DNSConfig: Codable, Sendable, Hashable {
    public var mode: DNSMode
    public var listenPort: UInt16
    public var upstreams: [String]        // 223.5.5.5, https://dns.example/dns-query, tls://1.1.1.1
    public var fallback: [String]
    public var hosts: [String: String]
    public var fakeIPRange: String
    public var blockResponse: String      // "nxdomain" or "0.0.0.0"
    public var cacheTTL: Int
    /// Clash `nameserver-policy`: domain pattern -> upstream list (e.g. "geosite:cn", "+.corp.example").
    public var nameserverPolicy: [String: [String]]
    /// Clash `fake-ip-filter`: domain patterns that must bypass fake-IP.
    public var fakeIPFilter: [String]

    public init(mode: DNSMode = .doh, listenPort: UInt16 = 5354,
                upstreams: [String] = ["https://1.1.1.1/dns-query", "tls://1.0.0.1"],
                fallback: [String] = ["223.5.5.5"], hosts: [String: String] = [:],
                fakeIPRange: String = "198.18.0.0/15", blockResponse: String = "nxdomain",
                cacheTTL: Int = 300, nameserverPolicy: [String: [String]] = [:],
                fakeIPFilter: [String] = []) {
        self.mode = mode; self.listenPort = listenPort; self.upstreams = upstreams
        self.fallback = fallback; self.hosts = hosts; self.fakeIPRange = fakeIPRange
        self.blockResponse = blockResponse; self.cacheTTL = cacheTTL
        self.nameserverPolicy = nameserverPolicy; self.fakeIPFilter = fakeIPFilter
    }

    private enum CodingKeys: String, CodingKey {
        case mode, listenPort, upstreams, fallback, hosts, fakeIPRange
        case blockResponse, cacheTTL, nameserverPolicy, fakeIPFilter
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(DNSMode.self, forKey: .mode) ?? .doh
        listenPort = try c.decodeIfPresent(UInt16.self, forKey: .listenPort) ?? 5354
        upstreams = try c.decodeIfPresent([String].self, forKey: .upstreams) ?? []
        fallback = try c.decodeIfPresent([String].self, forKey: .fallback) ?? []
        hosts = try c.decodeIfPresent([String: String].self, forKey: .hosts) ?? [:]
        fakeIPRange = try c.decodeIfPresent(String.self, forKey: .fakeIPRange) ?? "198.18.0.0/15"
        blockResponse = try c.decodeIfPresent(String.self, forKey: .blockResponse) ?? "nxdomain"
        cacheTTL = try c.decodeIfPresent(Int.self, forKey: .cacheTTL) ?? 300
        nameserverPolicy = try c.decodeIfPresent([String: [String]].self, forKey: .nameserverPolicy) ?? [:]
        fakeIPFilter = try c.decodeIfPresent([String].self, forKey: .fakeIPFilter) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(listenPort, forKey: .listenPort)
        try c.encode(upstreams, forKey: .upstreams)
        try c.encode(fallback, forKey: .fallback)
        try c.encode(hosts, forKey: .hosts)
        try c.encode(fakeIPRange, forKey: .fakeIPRange)
        try c.encode(blockResponse, forKey: .blockResponse)
        try c.encode(cacheTTL, forKey: .cacheTTL)
        if !nameserverPolicy.isEmpty { try c.encode(nameserverPolicy, forKey: .nameserverPolicy) }
        if !fakeIPFilter.isEmpty { try c.encode(fakeIPFilter, forKey: .fakeIPFilter) }
    }
}

// MARK: - Adblock

public struct AdBlockConfig: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var blockLists: [String]          // file names or http(s) urls of ABP/hosts lists
    public var allowList: [String]
    public var blockTrackers: Bool
    public var cosmeticFiltering: Bool
    public var hostsBlocking: Bool

    public init(enabled: Bool = true, blockLists: [String] = [], allowList: [String] = [],
                blockTrackers: Bool = true, cosmeticFiltering: Bool = true, hostsBlocking: Bool = true) {
        self.enabled = enabled; self.blockLists = blockLists; self.allowList = allowList
        self.blockTrackers = blockTrackers; self.cosmeticFiltering = cosmeticFiltering
        self.hostsBlocking = hostsBlocking
    }
}

// MARK: - General

public struct GeneralConfig: Codable, Sendable, Hashable {
    public var mixedPort: UInt16
    public var httpPort: UInt16
    public var socksPort: UInt16
    public var allowLAN: Bool
    public var logLevel: LogLevel
    public var captureEnabled: Bool
    public var mitmEnabled: Bool
    public var mitmHosts: [String]
    public var bypass: [String]
    public var dnsHijack: Bool

    public init(mixedPort: UInt16 = 7890, httpPort: UInt16 = 7891, socksPort: UInt16 = 7892,
                allowLAN: Bool = false, logLevel: LogLevel = .info, captureEnabled: Bool = true,
                mitmEnabled: Bool = false, mitmHosts: [String] = ["*"], bypass: [String] = ["127.0.0.1", "localhost", "*.local"],
                dnsHijack: Bool = true) {
        self.mixedPort = mixedPort; self.httpPort = httpPort; self.socksPort = socksPort
        self.allowLAN = allowLAN; self.logLevel = logLevel; self.captureEnabled = captureEnabled
        self.mitmEnabled = mitmEnabled; self.mitmHosts = mitmHosts; self.bypass = bypass
        self.dnsHijack = dnsHijack
    }
}

// MARK: - Profile

public struct Profile: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var general: GeneralConfig
    public var dns: DNSConfig
    public var adblock: AdBlockConfig
    public var outbounds: [OutboundConfig]
    public var groups: [PolicyGroup]
    public var rules: [Rule]
    public var sourcePath: String?
    /// Clash `rule-providers` preserved for round-trip and RULE-SET resolution.
    public var ruleProviders: [RuleProvider]
    /// Clash `proxy-providers` preserved for round-trip (not used at runtime).
    public var proxyProviders: [RuleProvider]

    public init(id: UUID = UUID(), name: String, general: GeneralConfig = .init(),
                dns: DNSConfig = .init(), adblock: AdBlockConfig = .init(),
                outbounds: [OutboundConfig] = [.direct, .reject], groups: [PolicyGroup] = [],
                rules: [Rule] = [], sourcePath: String? = nil,
                ruleProviders: [RuleProvider] = [], proxyProviders: [RuleProvider] = []) {
        self.id = id; self.name = name; self.general = general; self.dns = dns
        self.adblock = adblock; self.outbounds = outbounds; self.groups = groups
        self.rules = rules; self.sourcePath = sourcePath
        self.ruleProviders = ruleProviders; self.proxyProviders = proxyProviders
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, general, dns, adblock, outbounds, groups, rules, sourcePath
        case ruleProviders, proxyProviders
    }

    /// Hand-written so profiles saved by older builds (no `ruleProviders`) still decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名配置"
        general = try c.decodeIfPresent(GeneralConfig.self, forKey: .general) ?? GeneralConfig()
        dns = try c.decodeIfPresent(DNSConfig.self, forKey: .dns) ?? DNSConfig()
        adblock = try c.decodeIfPresent(AdBlockConfig.self, forKey: .adblock) ?? AdBlockConfig()
        outbounds = try c.decodeIfPresent([OutboundConfig].self, forKey: .outbounds) ?? [.direct, .reject]
        groups = try c.decodeIfPresent([PolicyGroup].self, forKey: .groups) ?? []
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath)
        ruleProviders = try c.decodeIfPresent([RuleProvider].self, forKey: .ruleProviders) ?? []
        proxyProviders = try c.decodeIfPresent([RuleProvider].self, forKey: .proxyProviders) ?? []
    }

    public func outbound(named name: String) -> OutboundConfig? {
        outbounds.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

// MARK: - Connections & flow events

public struct ConnectionMeta: Sendable, Hashable {
    public var host: String
    public var port: UInt16
    public var network: String            // tcp / udp
    public var sourceApp: String?
    public var sourcePID: Int32?
    public var sourceBundleID: String?
    public var destinationIP: String?
    public var ruleHint: String?

    public init(host: String, port: UInt16, network: String = "tcp", sourceApp: String? = nil,
                sourcePID: Int32? = nil, sourceBundleID: String? = nil,
                destinationIP: String? = nil, ruleHint: String? = nil) {
        self.host = host; self.port = port; self.network = network
        self.sourceApp = sourceApp; self.sourcePID = sourcePID
        self.sourceBundleID = sourceBundleID; self.destinationIP = destinationIP
        self.ruleHint = ruleHint
    }
}

public struct RouteDecision: Sendable, Hashable {
    public var policy: String
    public var outbound: OutboundConfig
    public var matchedRule: String?
    public var isBlocked: Bool

    public init(policy: String, outbound: OutboundConfig, matchedRule: String? = nil, isBlocked: Bool = false) {
        self.policy = policy; self.outbound = outbound
        self.matchedRule = matchedRule; self.isBlocked = isBlocked
    }
}

public enum FlowPhase: String, Sendable, Codable {
    case opened, closed, rejected, failed
}

public struct FlowEvent: Sendable, Identifiable, Codable {
    public var id: UUID
    public var timestamp: Date
    public var phase: FlowPhase
    public var host: String
    public var port: UInt16
    public var network: String
    public var policy: String
    public var matchedRule: String?
    public var outbound: String
    public var sourceApp: String?
    public var sourcePID: Int32?
    public var bytesIn: Int
    public var bytesOut: Int
    public var durationMs: Int
    public var blockedBy: String?     // "adblock" / "rule" / nil

    public init(id: UUID = UUID(), timestamp: Date = Date(), phase: FlowPhase, host: String, port: UInt16,
                network: String = "tcp", policy: String = "", matchedRule: String? = nil,
                outbound: String = "", sourceApp: String? = nil, sourcePID: Int32? = nil,
                bytesIn: Int = 0, bytesOut: Int = 0, durationMs: Int = 0, blockedBy: String? = nil) {
        self.id = id; self.timestamp = timestamp; self.phase = phase; self.host = host
        self.port = port; self.network = network; self.policy = policy
        self.matchedRule = matchedRule; self.outbound = outbound; self.sourceApp = sourceApp
        self.sourcePID = sourcePID; self.bytesIn = bytesIn; self.bytesOut = bytesOut
        self.durationMs = durationMs; self.blockedBy = blockedBy
    }
}

public struct BlockVerdict: Sendable, Hashable {
    public var blocked: Bool
    public var reason: String?
    public var cosmeticSelectors: [String]

    public init(blocked: Bool, reason: String? = nil, cosmeticSelectors: [String] = []) {
        self.blocked = blocked; self.reason = reason; self.cosmeticSelectors = cosmeticSelectors
    }
    public static let allow = BlockVerdict(blocked: false)
}

// MARK: - Captured traffic

public struct CapturedRequest: Sendable, Codable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var method: String
    public var url: String
    public var host: String
    public var requestHeaders: [String: String]
    public var requestBody: Data?
    public var statusCode: Int?
    public var responseHeaders: [String: String]
    public var responseBody: Data?
    public var mimeType: String?
    public var durationMs: Int
    public var sourceApp: String?
    public var blocked: Bool

    public init(id: UUID = UUID(), timestamp: Date = Date(), method: String, url: String, host: String,
                requestHeaders: [String: String] = [:], requestBody: Data? = nil,
                statusCode: Int? = nil, responseHeaders: [String: String] = [:],
                responseBody: Data? = nil, mimeType: String? = nil, durationMs: Int = 0,
                sourceApp: String? = nil, blocked: Bool = false) {
        self.id = id; self.timestamp = timestamp; self.method = method; self.url = url
        self.host = host; self.requestHeaders = requestHeaders; self.requestBody = requestBody
        self.statusCode = statusCode; self.responseHeaders = responseHeaders
        self.responseBody = responseBody; self.mimeType = mimeType; self.durationMs = durationMs
        self.sourceApp = sourceApp; self.blocked = blocked
    }
}

// MARK: - Logging level

public enum LogLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case debug, info, warning, error

    public var rank: Int {
        switch self { case .debug: 0; case .info: 1; case .warning: 2; case .error: 3 }
    }
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rank < b.rank }
}

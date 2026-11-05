import Foundation

// MARK: - Outbound configuration

public enum OutboundType: String, Codable, Sendable, CaseIterable {
    case direct
    case http
    case socks5
    case shadowsocks
    case trojan
    case reject
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
    /// AES-256-GCM PSK for trojan (hex) or shadowsocks password
    public var extra: [String: String]

    public init(name: String, type: OutboundType, host: String = "", port: UInt16 = 0,
                username: String? = nil, password: String? = nil, cipher: String? = nil,
                tls: Bool = false, sni: String? = nil, extra: [String: String] = [:]) {
        self.name = name; self.type = type; self.host = host; self.port = port
        self.username = username; self.password = password; self.cipher = cipher
        self.tls = tls; self.sni = sni; self.extra = extra
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

    public init(name: String, type: PolicyGroupType, proxies: [String], url: String? = nil,
                interval: Int? = nil, tolerance: Int? = nil, selected: String? = nil) {
        self.name = name; self.type = type; self.proxies = proxies
        self.url = url; self.interval = interval; self.tolerance = tolerance; self.selected = selected
    }

    private enum CodingKeys: String, CodingKey {
        case name, type, proxies, url, interval, tolerance, selected
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

    public init(mode: DNSMode = .doh, listenPort: UInt16 = 5354,
                upstreams: [String] = ["https://1.1.1.1/dns-query", "tls://1.0.0.1"],
                fallback: [String] = ["223.5.5.5"], hosts: [String: String] = [:],
                fakeIPRange: String = "198.18.0.0/15", blockResponse: String = "nxdomain",
                cacheTTL: Int = 300) {
        self.mode = mode; self.listenPort = listenPort; self.upstreams = upstreams
        self.fallback = fallback; self.hosts = hosts; self.fakeIPRange = fakeIPRange
        self.blockResponse = blockResponse; self.cacheTTL = cacheTTL
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

    public init(id: UUID = UUID(), name: String, general: GeneralConfig = .init(),
                dns: DNSConfig = .init(), adblock: AdBlockConfig = .init(),
                outbounds: [OutboundConfig] = [.direct, .reject], groups: [PolicyGroup] = [],
                rules: [Rule] = [], sourcePath: String? = nil) {
        self.id = id; self.name = name; self.general = general; self.dns = dns
        self.adblock = adblock; self.outbounds = outbounds; self.groups = groups
        self.rules = rules; self.sourcePath = sourcePath
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

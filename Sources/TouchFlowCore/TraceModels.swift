import Foundation

// MARK: - DNS trace (P1)

/// One step of a DNS resolution, kept so every answer can explain itself:
/// which stage answered (hosts / blocker / cache / upstream) and how long it took.
public struct DNSTraceStep: Codable, Sendable, Hashable {
    public var stage: String
    public var detail: String
    public var elapsedMs: Double

    public init(stage: String, detail: String, elapsedMs: Double = 0) {
        self.stage = stage
        self.detail = detail
        self.elapsedMs = elapsedMs
    }
}

public struct DNSTrace: Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable {
        case literal
        case hosts
        case blocker
        case cache
        case negativeCache = "negative-cache"
        case upstream
        case failed
    }

    public var host: String
    public var source: Source
    public var resolved: [String]
    public var upstream: String?
    public var elapsedMs: Double
    public var cacheTTL: Int?
    public var steps: [DNSTraceStep]
    public var error: String?

    public init(host: String, source: Source, resolved: [String] = [], upstream: String? = nil,
                elapsedMs: Double = 0, cacheTTL: Int? = nil, steps: [DNSTraceStep] = [],
                error: String? = nil) {
        self.host = host
        self.source = source
        self.resolved = resolved
        self.upstream = upstream
        self.elapsedMs = elapsedMs
        self.cacheTTL = cacheTTL
        self.steps = steps
        self.error = error
    }
}

// MARK: - HTTP probe (P1)

/// Result of a direct (proxy-bypassing) HTTP probe: status, timing, TLS and byte counts.
public struct HTTPProbeResult: Codable, Sendable, Hashable {
    public var url: String
    public var statusCode: Int?
    public var elapsedMs: Double
    public var remoteAddress: String?
    public var tls: Bool
    public var httpVersion: String?
    public var headerBytes: Int
    public var bodyBytes: Int
    public var headers: [String: String]
    public var redirects: Int
    public var error: String?

    public init(url: String, statusCode: Int? = nil, elapsedMs: Double = 0,
                remoteAddress: String? = nil, tls: Bool = false, httpVersion: String? = nil,
                headerBytes: Int = 0, bodyBytes: Int = 0, headers: [String: String] = [:],
                redirects: Int = 0, error: String? = nil) {
        self.url = url
        self.statusCode = statusCode
        self.elapsedMs = elapsedMs
        self.remoteAddress = remoteAddress
        self.tls = tls
        self.httpVersion = httpVersion
        self.headerBytes = headerBytes
        self.bodyBytes = bodyBytes
        self.headers = headers
        self.redirects = redirects
        self.error = error
    }
}

// MARK: - Rule diagnostics (P3)

/// Why a rule can never win. Produced by the rule index so the editor can say
/// "这条规则永不命中" instead of leaving dead rules silently in the list.
public struct RuleDiagnostic: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// An earlier rule with the same or broader domain/IP matcher wins first.
        case shadowed
        /// Byte-for-byte duplicate of an earlier rule with the same policy.
        case duplicate
        /// Sits after a FINAL/MATCH rule, so it can never be reached.
        case unreachable
        /// RULE-SET member whose provider is not loaded.
        case ruleSetMissing = "rule-set-missing"
        /// Matcher itself can never produce a match (empty value, invalid regex, ...).
        case neverMatch = "never-match"
    }

    public var ruleID: String
    public var raw: String
    public var index: Int
    public var kind: Kind
    public var reason: String
    public var shadowedByIndex: Int?

    public init(ruleID: String, raw: String, index: Int, kind: Kind, reason: String,
                shadowedByIndex: Int? = nil) {
        self.ruleID = ruleID
        self.raw = raw
        self.index = index
        self.kind = kind
        self.reason = reason
        self.shadowedByIndex = shadowedByIndex
    }
}

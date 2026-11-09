import Foundation
import LeapinCore

// MARK: - Wire models
//
// Everything the local action API returns is a value type so the same payload can be
// rendered by the CLI, a remote panel, or a test. Times are milliseconds since epoch.

public struct ControlStatus: Codable, Sendable, Hashable {
    public var engineState: String
    public var mixedPort: Int
    public var httpPort: Int
    public var socksPort: Int
    public var controlPort: Int
    public var ruleCount: Int
    public var adblockRuleCount: Int
    public var activeConnections: Int
    public var systemProxyActive: Bool
    public var uptimeSeconds: Double
    public var version: String

    public init(engineState: String, mixedPort: Int, httpPort: Int, socksPort: Int, controlPort: Int,
                ruleCount: Int, adblockRuleCount: Int, activeConnections: Int,
                systemProxyActive: Bool, uptimeSeconds: Double, version: String = "3.0") {
        self.engineState = engineState
        self.mixedPort = mixedPort
        self.httpPort = httpPort
        self.socksPort = socksPort
        self.controlPort = controlPort
        self.ruleCount = ruleCount
        self.adblockRuleCount = adblockRuleCount
        self.activeConnections = activeConnections
        self.systemProxyActive = systemProxyActive
        self.uptimeSeconds = uptimeSeconds
        self.version = version
    }
}

public struct ControlConnection: Codable, Sendable, Hashable {
    public var id: String
    public var timestampMs: Double
    public var phase: String
    public var host: String
    public var port: Int
    public var network: String
    public var policy: String
    public var matchedRule: String
    public var outbound: String
    public var sourceApp: String
    public var sourcePID: Int32
    public var bytesIn: Int64
    public var bytesOut: Int64
    public var durationMs: Double
    public var chainSummary: String

    public init(id: String, timestampMs: Double, phase: String, host: String, port: Int,
                network: String, policy: String, matchedRule: String, outbound: String,
                sourceApp: String, sourcePID: Int32, bytesIn: Int64, bytesOut: Int64,
                durationMs: Double, chainSummary: String = "") {
        self.id = id
        self.timestampMs = timestampMs
        self.phase = phase
        self.host = host
        self.port = port
        self.network = network
        self.policy = policy
        self.matchedRule = matchedRule
        self.outbound = outbound
        self.sourceApp = sourceApp
        self.sourcePID = sourcePID
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.durationMs = durationMs
        self.chainSummary = chainSummary
    }
}

public struct ControlEvent: Codable, Sendable, Hashable {
    public var seq: Int
    public var timestampMs: Double
    public var phase: String
    public var host: String
    public var port: Int
    public var policy: String
    public var matchedRule: String
    public var outbound: String
    public var sourceApp: String
    public var bytesIn: Int64
    public var bytesOut: Int64
    public var durationMs: Double
    public var blockedBy: String

    public init(seq: Int = 0, timestampMs: Double, phase: String, host: String, port: Int,
                policy: String, matchedRule: String, outbound: String, sourceApp: String,
                bytesIn: Int64 = 0, bytesOut: Int64 = 0, durationMs: Double = 0, blockedBy: String = "") {
        self.seq = seq
        self.timestampMs = timestampMs
        self.phase = phase
        self.host = host
        self.port = port
        self.policy = policy
        self.matchedRule = matchedRule
        self.outbound = outbound
        self.sourceApp = sourceApp
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.durationMs = durationMs
        self.blockedBy = blockedBy
    }
}

public struct ControlPolicyGroup: Codable, Sendable, Hashable {
    public var name: String
    public var type: String
    public var selected: String
    public var effective: String
    public var members: [String]

    public init(name: String, type: String, selected: String, effective: String, members: [String]) {
        self.name = name
        self.type = type
        self.selected = selected
        self.effective = effective
        self.members = members
    }
}

public struct ControlExplainResult: Codable, Sendable, Hashable {
    public var host: String
    public var port: Int
    public var policy: String
    public var matchedRule: String
    public var trace: [String]
    public var chainSummary: String
    public var chainSteps: [String]
    public var outbound: String
    public var isBlocked: Bool
    public var diagnostics: [RuleDiagnostic]

    public init(host: String, port: Int, policy: String, matchedRule: String, trace: [String],
                chainSummary: String = "", chainSteps: [String] = [], outbound: String = "",
                isBlocked: Bool = false, diagnostics: [RuleDiagnostic] = []) {
        self.host = host
        self.port = port
        self.policy = policy
        self.matchedRule = matchedRule
        self.trace = trace
        self.chainSummary = chainSummary
        self.chainSteps = chainSteps
        self.outbound = outbound
        self.isBlocked = isBlocked
        self.diagnostics = diagnostics
    }
}

public struct ControlReloadResult: Codable, Sendable, Hashable {
    public var restarted: Bool
    public var applied: [String]
    public var skipped: [String]
    public var ruleCount: Int
    public var elapsedMs: Double

    public init(restarted: Bool, applied: [String], skipped: [String] = [], ruleCount: Int = 0, elapsedMs: Double = 0) {
        self.restarted = restarted
        self.applied = applied
        self.skipped = skipped
        self.ruleCount = ruleCount
        self.elapsedMs = elapsedMs
    }
}

public struct ControlSelectionResult: Codable, Sendable, Hashable {
    public var group: String
    public var outbound: String
    public var effective: String
    public var persisted: Bool

    public init(group: String, outbound: String, effective: String, persisted: Bool) {
        self.group = group
        self.outbound = outbound
        self.effective = effective
        self.persisted = persisted
    }
}

public struct ControlAuditRecord: Codable, Sendable, Hashable {
    public var timestampMs: Double
    public var method: String
    public var path: String
    public var action: String
    public var status: Int
    public var remote: String
    public var allowed: Bool
    public var tokenPrefix: String
    public var detail: String

    public init(timestampMs: Double, method: String, path: String, action: String, status: Int,
                remote: String, allowed: Bool, tokenPrefix: String = "", detail: String = "") {
        self.timestampMs = timestampMs
        self.method = method
        self.path = path
        self.action = action
        self.status = status
        self.remote = remote
        self.allowed = allowed
        self.tokenPrefix = tokenPrefix
        self.detail = detail
    }
}

public enum ControlError: Error, LocalizedError, Sendable {
    case unauthorized
    case notFound(String)
    case badRequest(String)
    case unavailable(String)
    case backend(String)

    public var statusCode: Int {
        switch self {
        case .unauthorized: return 401
        case .notFound: return 404
        case .badRequest: return 400
        case .unavailable: return 503
        case .backend: return 500
        }
    }

    public var code: String {
        switch self {
        case .unauthorized: return "unauthorized"
        case .notFound: return "not_found"
        case .badRequest: return "bad_request"
        case .unavailable: return "unavailable"
        case .backend: return "backend_error"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "missing or invalid control token"
        case .notFound(let what): return "\(what) not found"
        case .badRequest(let why): return why
        case .unavailable(let why): return why
        case .backend(let why): return why
        }
    }
}

// MARK: - Backend contract
//
// The engine owns all mutable state; the control server owns transport, auth and audit.
// Every action goes through this protocol so the surface never mutates the engine directly.

@MainActor
public protocol ControlBackend: AnyObject {
    func controlStatus() async -> ControlStatus
    func controlConnections(limit: Int) async -> [ControlConnection]
    func controlPolicies() async -> [ControlPolicyGroup]
    func controlSelect(group: String, outbound: String) async throws -> ControlSelectionResult
    func controlReload() async throws -> ControlReloadResult
    func controlExplain(host: String, port: Int) async throws -> ControlExplainResult
    func controlDNSTrace(host: String) async throws -> DNSTrace
    func controlHTTPProbe(url: String, timeoutMs: Int) async throws -> HTTPProbeResult
}

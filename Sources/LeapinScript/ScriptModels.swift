import Foundation
import LeapinCore

/// Where a script is allowed to run.
///
/// The phases are the ABI: a script declares one, and the host only calls it at that
/// point in the lifetime of a connection.
public enum ScriptPhase: String, Sendable, CaseIterable {
    case request = "http.request"
    case response = "http.response"
    case dns = "dns"
    case cron = "cron"
    case network = "network.changed"

    public var title: String {
        switch self {
        case .request: return "请求"
        case .response: return "响应"
        case .dns: return "DNS"
        case .cron: return "定时"
        case .network: return "网络变化"
        }
    }

    /// Phases this build actually invokes. The rest are declared so stored scripts and
    /// the editor agree on the vocabulary before the host grows the hooks.
    public var isActive: Bool {
        switch self {
        case .request, .response: return true
        case .dns, .cron, .network: return false
        }
    }
}

public struct ScriptSource: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var phase: ScriptPhase
    public var code: String
    public var enabled: Bool

    public init(name: String, phase: ScriptPhase, code: String, enabled: Bool = true) {
        self.name = name
        self.phase = phase
        self.code = code
        self.enabled = enabled
    }
}

/// What a script is handed, and what it may hand back.
public struct ScriptRequest: Sendable {
    public var method: String
    public var url: String
    public var headers: [(name: String, value: String)]
    public var body: Data

    public init(method: String, url: String, headers: [(name: String, value: String)], body: Data) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public enum ScriptOutcome: Sendable {
    /// Continue, possibly with edited headers/body/url.
    case proceed(headers: RewriteHeaders, body: Data, url: String?)
    /// Answer locally (a scripted Mock).
    case respond(status: Int, contentType: String, body: Data)
    case redirect(url: String, status: Int)
}

public struct ScriptRunError: Error, Sendable {
    public var script: String
    public var reason: String
}

/// Result of applying a phase: what to do next, plus anything worth logging.
public struct ScriptRunResult: Sendable {
    public var outcome: ScriptOutcome
    public var logs: [String]
    public var errors: [ScriptRunError]
}

/// Host services the sandbox is allowed to reach. Everything else is absent by design:
/// no filesystem, no process, no dynamic import.
public protocol ScriptHost: AnyObject, Sendable {
    /// Must return quickly; the caller is holding a proxied connection.
    func httpGet(url: String, timeoutMs: Int) -> (status: Int, body: String)?
    func notify(title: String, body: String)
    var environment: [String: String] { get }
}

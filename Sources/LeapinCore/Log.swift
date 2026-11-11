import Foundation
import os

public struct LogEntry: Sendable, Identifiable, Codable {
    public var id = UUID()
    public var date: Date
    public var level: LogLevel
    public var category: String
    public var message: String
    public init(date: Date = Date(), level: LogLevel, category: String, message: String) {
        self.date = date; self.level = level; self.category = category; self.message = message
    }
}

/// In-memory, redacting logger with a bounded ring buffer that feeds the UI.
public final class LPLog: @unchecked Sendable {
    public static let shared = LPLog()

    private let lock = NSLock()
    /// Ring buffer: overwriting the oldest slot is O(1), while `removeFirst` used to
    /// memmove the whole buffer on every line once it was full.
    private var ring: [LogEntry?]
    private var ringHead = 0
    private var ringCount = 0
    private let capacity: Int
    private var observers: [(LogEntry) -> Void] = []
    public var minimumLevel: LogLevel = .info
    private let osLog = Logger(subsystem: "com.leapin.app", category: "core")

    public init(capacity: Int = 2000) {
        self.capacity = max(1, capacity)
        self.ring = Array(repeating: nil, count: max(1, capacity))
    }

    public func log(_ level: LogLevel, _ category: String, _ message: String) {
        guard level >= minimumLevel else { return }
        let safe = Redactor.redact(message)
        let entry = LogEntry(level: level, category: category, message: safe)
        lock.lock()
        if ringCount < capacity {
            ring[(ringHead + ringCount) % capacity] = entry
            ringCount += 1
        } else {
            ring[ringHead] = entry
            ringHead = (ringHead + 1) % capacity
        }
        let obs = observers
        lock.unlock()
        osLog.log(level: level == .error ? .error : .default, "\(category, privacy: .public): \(safe, privacy: .public)")
        for o in obs { o(entry) }
    }

    public func debug(_ c: String, _ m: String) { log(.debug, c, m) }
    public func info(_ c: String, _ m: String) { log(.info, c, m) }
    public func warn(_ c: String, _ m: String) { log(.warning, c, m) }
    public func error(_ c: String, _ m: String) { log(.error, c, m) }

    public func snapshot() -> [LogEntry] {
        lock.withLock { (0..<ringCount).compactMap { ring[(ringHead + $0) % capacity] } }
    }

    public func clear() {
        lock.withLock {
            ring = Array(repeating: nil, count: capacity)
            ringHead = 0
            ringCount = 0
        }
    }
    public func addObserver(_ o: @escaping (LogEntry) -> Void) { lock.withLock { observers.append(o) } }
}

public enum Redactor {
    private static let patterns: [(String, String)] = [
        (#"(?i)(authorization|proxy-authorization)\s*:\s*[^\r\n]+"#, "$1: <redacted>"),
        (#"(?i)(cookie|set-cookie)\s*:\s*[^\r\n]+"#, "$1: <redacted>"),
        (#"(?i)(password|passwd|pwd|token|secret|apikey|api_key|uuid|private-key|private_key|auth-key)=([^&\s]+)"#, "$1=<redacted>"),
        (#"(?i)("(password|token|secret|apikey|uuid|private-key|private_key|auth-key)"\s*:\s*")[^"]*(")"#, "$1<redacted>$3"),
        (#"(?i)([a-z]+://[^:/\s]+):([^@/\s]+)@"#, "$1:<redacted>@"),
        (#"(?i)\b(password|passwd|pwd|token|secret|apikey|api_key|uuid|private-key|private_key|auth-key)(\s*:\s*)("[^"]*"|'[^']*'|[^\s,}\]]+)"#, "$1$2<redacted>"),
        (#"(?i)\b(ss|ssr|vmess|vless|trojan|hysteria2|hy2|tuic)://[^\s]+"#, "$1://<redacted>"),
    ]

    private struct CompiledRule: @unchecked Sendable {
        let regex: NSRegularExpression
        let template: String
    }

    /// Compiled once. The old code compiled five regular expressions on *every* log
    /// line, which dominated the logger's cost on connect-heavy workloads.
    private static let compiled: [CompiledRule] = patterns.compactMap { pattern, template in
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return CompiledRule(regex: regex, template: template)
    }

    /// A rule can only match when one of these substrings is present, so the regex
    /// pass is skipped for ordinary log lines ("listening on 127.0.0.1:7890", ...).
    private static let triggers = [
        "authorization", "cookie", "password", "passwd", "pwd",
        "token", "secret", "apikey", "api_key", "uuid", "private-key", "private_key", "auth-key", "://",
    ]

    public static func redact(_ text: String) -> String {
        guard mightContainSecret(text) else { return text }
        var out = text
        for rule in compiled {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = rule.regex.stringByReplacingMatches(in: out, options: [], range: range,
                                                      withTemplate: rule.template)
        }
        return out
    }

    private static func mightContainSecret(_ text: String) -> Bool {
        guard text.utf8.count >= 4 else { return false }
        let lowered = text.lowercased()
        return triggers.contains { lowered.contains($0) }
    }

    /// Drops credential-bearing headers from capture/export paths.
    public static func redactHeaders(_ headers: [String: String]) -> [String: String] {
        let sensitive: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key"]
        return headers.filter { !sensitive.contains($0.key.lowercased()) }
    }
}

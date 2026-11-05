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
public final class TFLog: @unchecked Sendable {
    public static let shared = TFLog()

    private let lock = NSLock()
    private var buffer: [LogEntry] = []
    private let capacity: Int
    private var observers: [(LogEntry) -> Void] = []
    public var minimumLevel: LogLevel = .info
    private let osLog = Logger(subsystem: "com.touchflow.app", category: "core")

    public init(capacity: Int = 2000) { self.capacity = capacity }

    public func log(_ level: LogLevel, _ category: String, _ message: String) {
        guard level >= minimumLevel else { return }
        let safe = Redactor.redact(message)
        let entry = LogEntry(level: level, category: category, message: safe)
        lock.lock()
        buffer.append(entry)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        let obs = observers
        lock.unlock()
        osLog.log(level: level == .error ? .error : .default, "\(category, privacy: .public): \(safe, privacy: .public)")
        for o in obs { o(entry) }
    }

    public func debug(_ c: String, _ m: String) { log(.debug, c, m) }
    public func info(_ c: String, _ m: String) { log(.info, c, m) }
    public func warn(_ c: String, _ m: String) { log(.warning, c, m) }
    public func error(_ c: String, _ m: String) { log(.error, c, m) }

    public func snapshot() -> [LogEntry] { lock.withLock { buffer } }
    public func clear() { lock.withLock { buffer.removeAll() } }
    public func addObserver(_ o: @escaping (LogEntry) -> Void) { lock.withLock { observers.append(o) } }
}

public enum Redactor {
    private static let patterns: [(String, String)] = [
        (#"(?i)(authorization|proxy-authorization)\s*:\s*[^\r\n]+"#, "$1: <redacted>"),
        (#"(?i)(cookie|set-cookie)\s*:\s*[^\r\n]+"#, "$1: <redacted>"),
        (#"(?i)(password|passwd|pwd|token|secret|apikey|api_key)=([^&\s]+)"#, "$1=<redacted>"),
        (#"(?i)("(password|token|secret|apikey)"\s*:\s*")[^"]*(")"#, "$1<redacted>$3"),
        (#"(?i)([a-z]+://[^:/\s]+):([^@/\s]+)@"#, "$1:<redacted>@"),
    ]

    public static func redact(_ text: String) -> String {
        var out = text
        for (pattern, replacement) in patterns {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return out
    }

    /// Drops credential-bearing headers from capture/export paths.
    public static func redactHeaders(_ headers: [String: String]) -> [String: String] {
        let sensitive: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key"]
        return headers.filter { !sensitive.contains($0.key.lowercased()) }
    }
}

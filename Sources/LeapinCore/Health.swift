import Foundation

/// One latency observation for an outbound or policy-group member.
public struct OutboundHealth: Sendable, Equatable {
    /// nil means the last probe failed.
    public var latencyMs: Int?
    public var checkedAt: Date?
    public var lastError: String?
    public var consecutiveFailures: Int

    public init(latencyMs: Int? = nil, checkedAt: Date? = nil,
                lastError: String? = nil, consecutiveFailures: Int = 0) {
        self.latencyMs = latencyMs; self.checkedAt = checkedAt
        self.lastError = lastError; self.consecutiveFailures = consecutiveFailures
    }

    public var isAlive: Bool { latencyMs != nil }

    public func isFresh(now: Date = Date(), maxAge: TimeInterval = 300) -> Bool {
        guard let checkedAt else { return false }
        return now.timeIntervalSince(checkedAt) <= maxAge
    }
}

/// Shared latency table: written by HealthProber (runtime), read by PolicyResolver
/// (policy) so url-test / fallback pick a real winner instead of the first member.
public final class LPHealth: @unchecked Sendable {
    public static let shared = LPHealth()

    private let lock = NSLock()
    private var entries: [String: OutboundHealth] = [:]

    public init() {}

    public func record(name: String, latencyMs: Int?, error: String? = nil, at: Date = Date()) {
        let key = name.lowercased()
        var entry = OutboundHealth(latencyMs: latencyMs, checkedAt: at, lastError: error)
        lock.withLock {
            let previous = entries[key]?.consecutiveFailures ?? 0
            entry.consecutiveFailures = latencyMs == nil ? previous + 1 : 0
            entries[key] = entry
        }
    }

    public func health(for name: String) -> OutboundHealth? {
        lock.withLock { entries[name.lowercased()] }
    }

    /// Only fresh observations count for automatic selection; a probe that stopped
    /// running must not pin a group to a stale winner forever.
    public func freshHealth(for name: String, maxAge: TimeInterval = 300) -> OutboundHealth? {
        let entry = health(for: name)
        guard let entry, entry.isFresh(maxAge: maxAge) else { return nil }
        return entry
    }

    public func snapshot() -> [String: OutboundHealth] {
        lock.withLock { entries }
    }

    public func reset() {
        lock.withLock { entries.removeAll() }
    }
}

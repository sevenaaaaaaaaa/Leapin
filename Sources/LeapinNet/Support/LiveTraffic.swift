import Foundation

/// Live byte counters for the UI.
///
/// `EngineStats` only grows when a flow *finishes*, so it cannot answer "how fast
/// right now". The pump already counts every chunk it relays; this just mirrors
/// those numbers into a lock-protected total that a 1 Hz UI timer can diff.
///
/// Naming follows `BytePump.Stats`: `bytesIn` is client -> remote (upload),
/// `bytesOut` is remote -> client (download).
public final class LiveTraffic: @unchecked Sendable {
    public static let shared = LiveTraffic()

    private let lock = NSLock()
    private var totalIn = 0
    private var totalOut = 0

    private init() {}

    public func record(bytes: Int, inbound: Bool) {
        lock.lock()
        if inbound { totalIn &+= bytes } else { totalOut &+= bytes }
        lock.unlock()
    }

    public func snapshot() -> (bytesIn: Int, bytesOut: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (totalIn, totalOut)
    }
}

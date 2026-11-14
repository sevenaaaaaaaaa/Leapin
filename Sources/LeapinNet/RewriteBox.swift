import Foundation
import LeapinCore

/// Hot-swappable rewrite rules.
///
/// `ProxyServer` and `MITMHandler` are created once per start and live for the whole
/// session, so they cannot hold a `RewriteEngine` directly if the user is allowed to
/// edit rules while the proxy keeps running. They hold this box instead and read
/// `current` per request, mirroring how `RouterBox` / `BlockerBox` work.
public final class RewriteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: RewriteEngine?

    public init(_ engine: RewriteEngine? = nil) {
        self.engine = engine
    }

    public func swap(_ engine: RewriteEngine?) {
        lock.withLock { self.engine = engine }
    }

    public var current: RewriteEngine? {
        lock.withLock { engine }
    }
}

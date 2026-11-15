import Foundation
import LeapinCore
import LeapinScript

/// Hot-swappable script runtime.
///
/// Same shape as `RewriteBox`: the proxy is created once per start, so it reads the
/// current runtime per request and an edited script applies to the next connection.
public final class ScriptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var runtime: ScriptRuntime?

    public init(_ runtime: ScriptRuntime? = nil) {
        self.runtime = runtime
    }

    public func swap(_ runtime: ScriptRuntime?) {
        lock.withLock { self.runtime = runtime }
    }

    public var current: ScriptRuntime? {
        lock.withLock { runtime }
    }
}

import Foundation
import TouchFlowCore

/// Bidirectional byte relay with idle timeout and half-close propagation.
public enum BytePump {
    public struct Stats: Sendable, Hashable {
        /// Bytes travelling client -> remote (upload).
        public var bytesIn: Int
        /// Bytes travelling remote -> client (download).
        public var bytesOut: Int
        /// True when the relay stopped because of the idle timeout.
        public var idleTimedOut: Bool
        public var durationMs: Int

        public init(bytesIn: Int = 0, bytesOut: Int = 0, idleTimedOut: Bool = false, durationMs: Int = 0) {
            self.bytesIn = bytesIn; self.bytesOut = bytesOut
            self.idleTimedOut = idleTimedOut; self.durationMs = durationMs
        }
    }

    /// Relays bytes both ways until both directions reach EOF, an error occurs, or the
    /// connection sits idle for `idleTimeout` seconds. Half-close is propagated: EOF on one
    /// direction shuts down only the write side of the peer so the other direction can flush.
    @discardableResult
    public static func run(_ left: ByteStream, _ right: ByteStream,
                           idleTimeout: TimeInterval = 300) async -> Stats {
        let started = Date()
        let state = PumpState(idleTimeout: idleTimeout, left: left, right: right)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pipe(from: left, to: right, state: state, inbound: true) }
            group.addTask { await pipe(from: right, to: left, state: state, inbound: false) }
            group.addTask {
                while await state.isRunning {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }
                    if await state.checkIdle() { return }
                }
            }
            await group.waitForAll()
        }

        TFLog.shared.debug("pump", "done \(left.remoteDescription) <-> \(right.remoteDescription)")
        let (bytesIn, bytesOut, timedOut) = await state.snapshot()
        left.close()
        right.close()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if timedOut {
            TFLog.shared.warn("pump", "idle timeout after \(Int(idleTimeout))s: \(left.remoteDescription) <-> \(right.remoteDescription)")
        }
        return Stats(bytesIn: bytesIn, bytesOut: bytesOut, idleTimedOut: timedOut, durationMs: ms)
    }

    private static func pipe(from: ByteStream, to: ByteStream,
                            state: PumpState, inbound: Bool) async {
        while true {
            let data: Data?
            do {
                data = try await from.read(maxLength: 65536)
            } catch {
                TFLog.shared.debug("pump", "read error \(from.remoteDescription): \(error.localizedDescription)")
                break
            }
            guard let data, !data.isEmpty else {
                TFLog.shared.debug("pump", "eof from \(from.remoteDescription)")
                break
            }
            do {
                try await to.write(data)
            } catch {
                TFLog.shared.debug("pump", "write error \(to.remoteDescription): \(error.localizedDescription)")
                break
            }
            await state.record(bytes: data.count, inbound: inbound)
        }
        // EOF / error: half-close the peer's write direction so pending data still flushes.
        if let half = to as? WriteHalfClosable {
            half.closeWrite()
        }
        await state.finishDirection()
    }
}

private actor PumpState {
    private let idleTimeout: TimeInterval
    private let left: ByteStream
    private let right: ByteStream

    private var bytesIn = 0
    private var bytesOut = 0
    private var lastActivity = Date()
    private var finished = 0
    private var timedOut = false

    init(idleTimeout: TimeInterval, left: ByteStream, right: ByteStream) {
        self.idleTimeout = idleTimeout
        self.left = left
        self.right = right
    }

    var isRunning: Bool { finished < 2 }

    func record(bytes: Int, inbound: Bool) {
        if inbound { bytesIn += bytes } else { bytesOut += bytes }
        lastActivity = Date()
    }

    func finishDirection() { finished += 1 }

    /// Returns true when the idle timeout fired and the streams were closed.
    func checkIdle() -> Bool {
        guard finished < 2 else { return false }
        guard idleTimeout > 0 else { return false }
        if Date().timeIntervalSince(lastActivity) >= idleTimeout {
            timedOut = true
            left.close()
            right.close()
            return true
        }
        return false
    }

    func snapshot() -> (Int, Int, Bool) { (bytesIn, bytesOut, timedOut) }
}

import Foundation
import Darwin
import LeapinCore

/// Waits for a child process without polling it.
///
/// A while-loop over process.isRunning with usleep(10_000) wakes a thread a hundred
/// times a second for the whole life of the child. On a teardown path that runs from
/// the main actor it also stalls the window for the full grace period. Every wait
/// here is released by the process itself, so an idle child costs nothing.
enum ProcessExit {
    /// Blocks until the child exits or the deadline passes.
    /// Returns true when it exited, so the caller may read terminationStatus.
    @discardableResult
    static func wait(_ process: Process, timeout: TimeInterval) -> Bool {
        if !process.isRunning { return true }
        let signal = DispatchSemaphore(value: 0)
        let previous = process.terminationHandler
        process.terminationHandler = { _ in signal.signal() }
        // The child may have exited between the check above and the assignment;
        // in that window the handler is never called, so check once more.
        if !process.isRunning {
            process.terminationHandler = previous
            return true
        }
        let exited = signal.wait(timeout: .now() + max(0, timeout)) == .success
        if exited { process.terminationHandler = previous }
        return exited
    }

    /// Asks the child to stop, waits for the grace period, then kills it.
    /// Returns true when the child really exited.
    @discardableResult
    static func terminate(_ process: Process, grace: TimeInterval) -> Bool {
        guard process.isRunning else { return true }
        process.terminate()
        if wait(process, timeout: grace) { return true }
        kill(process.processIdentifier, SIGKILL)
        return wait(process, timeout: 0.5)
    }

    /// terminationStatus once the child is gone, or -1 if it outlived the deadline.
    /// Reading the status of a running child raises an Objective-C exception, so the
    /// check happens here and nowhere else.
    static func status(of process: Process, timeout: TimeInterval) async -> Int32 {
        let exited = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            if !process.isRunning {
                continuation.resume(returning: true)
                return
            }
            let once = OnceFlag()
            let previous = process.terminationHandler
            process.terminationHandler = { _ in
                if once.claim() { continuation.resume(returning: true) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, timeout)) {
                if once.claim() {
                    process.terminationHandler = previous
                    continuation.resume(returning: !process.isRunning)
                }
            }
        }
        return exited ? process.terminationStatus : -1
    }
}

/// Makes sure only one of several racing callbacks resumes the continuation.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

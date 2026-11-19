import XCTest
import LeapinCore
@testable import LeapinIntegrations

/// INT-01: an external command must never cost the caller its thread, and its
/// deadline must hold. The old runner polled `process.isRunning` every 10 ms on
/// the calling thread, so a UI caller froze for the whole run of the tool.
final class CommandRunnerTests: XCTestCase {

    func testAsyncCommandDoesNotBlockTheCaller() async throws {
        let started = Date()
        // The task starts on the command queue; the calling thread returns at once.
        let running = Task { try await CommandRunner.runAsync(executable: "/bin/sleep",
                                                              arguments: ["0.8"],
                                                              timeout: 5) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.6,
                          "runAsync must hand the wait to its own queue")
        let output = try await running.value
        XCTAssertEqual(output.status, 0)
        XCTAssertFalse(output.timedOut)
    }

    func testAsyncCommandsRunConcurrently() async throws {
        let started = Date()
        async let first = CommandRunner.runAsync(executable: "/bin/sleep", arguments: ["0.5"], timeout: 5)
        async let second = CommandRunner.runAsync(executable: "/bin/sleep", arguments: ["0.5"], timeout: 5)
        _ = try await (first, second)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.9,
                          "two independent commands must overlap, not serialize")
    }

    func testAsyncCommandHonoursItsDeadline() async throws {
        let started = Date()
        let output = try await CommandRunner.runAsync(executable: "/bin/sleep",
                                                      arguments: ["30"],
                                                      timeout: 0.3)
        XCTAssertTrue(output.timedOut, "a child past its deadline is reported as a timeout")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3,
                          "the deadline must kill the child, not wait for it")
    }

    func testAsyncCheckedCommandSurfacesStderr() async throws {
        do {
            _ = try await CommandRunner.runCheckedAsync(executable: "/bin/sh",
                                                        arguments: ["-c", "echo boom >&2; exit 3"],
                                                        timeout: 5)
            XCTFail("a non-zero exit must throw")
        } catch {
            let text = "\(error)"
            XCTAssertTrue(text.contains("3"), "exit status belongs in the message: \(text)")
            XCTAssertTrue(text.contains("boom"), "stderr belongs in the message: \(text)")
        }
    }
}

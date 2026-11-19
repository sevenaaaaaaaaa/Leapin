import XCTest
@testable import LeapinIntegrations

/// INT-04: waiting for a child must be driven by the child, not by a 10 ms poll.
final class ProcessExitTests: XCTestCase {

    private func makeProcess(_ script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        return process
    }

    func testWaitReturnsWhenChildExits() throws {
        let process = makeProcess("sleep 0.1; exit 3")
        try process.run()
        XCTAssertTrue(ProcessExit.wait(process, timeout: 3))
        XCTAssertEqual(process.terminationStatus, 3)
    }

    func testWaitTimeoutLeavesTheChildAlive() throws {
        let process = makeProcess("sleep 5")
        try process.run()
        defer { ProcessExit.terminate(process, grace: 1) }

        let started = Date()
        XCTAssertFalse(ProcessExit.wait(process, timeout: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "the deadline must not overshoot")
        XCTAssertTrue(process.isRunning, "a plain wait never kills the child")
    }

    func testTerminateKillsAChildThatIgnoresSIGTERM() throws {
        // The child must have installed the trap before SIGTERM arrives, or the
        // default action kills it and this test proves nothing. A marker file is
        // the handshake; the trap comes first so the marker implies the trap.
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("leapin-trap-\(UUID().uuidString)")
        let process = makeProcess("trap '' TERM; : > '\(marker.path)'; sleep 5")
        try process.run()
        defer { try? FileManager.default.removeItem(at: marker) }

        let ready = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < ready {
            usleep(20_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the child never installed its trap")

        let started = Date()
        XCTAssertTrue(ProcessExit.terminate(process, grace: 0.3))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertFalse(process.isRunning)
        XCTAssertGreaterThan(elapsed, 0.25, "an ignored SIGTERM must use the whole grace period")
        XCTAssertLessThan(elapsed, 2.5, "SIGKILL must follow the grace period")
    }

    func testAsyncStatusReportsExitCodeOrTimeout() async throws {
        let quick = makeProcess("exit 7")
        try quick.run()
        let code = await ProcessExit.status(of: quick, timeout: 2)
        XCTAssertEqual(code, 7)

        let slow = makeProcess("sleep 5")
        try slow.run()
        defer { ProcessExit.terminate(slow, grace: 1) }
        let missing = await ProcessExit.status(of: slow, timeout: 0.2)
        XCTAssertEqual(missing, -1, "a child still running has no status yet")
    }
}

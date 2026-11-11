import XCTest
import LeapinCore
@testable import LeapinIntegrations

final class NetworkToolProcessTests: XCTestCase {
    private func fixture(_ body: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("tool")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
    @MainActor
    func testReadinessAndStopDoNotLeaveOwnedChild() async throws {
        let file = try fixture("echo $$ > \"$0.pid\"\nprintf '%s\\n' READY\nexec /bin/sleep 30")
        let model = NetworkToolProcess()
        defer { model.stop(force: true) }
        try await model.start(executable: file, arguments: [], timeout: 2) { $0.contains("READY") }
        XCTAssertTrue(model.running)
        let pid = Int32(try String(contentsOf: file.appendingPathExtension("pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        model.stop(force: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(model.running)
        XCTAssertEqual(kill(pid, 0), -1)
    }
    @MainActor
    func testStartupTimeoutAndFailureStayStopped() async throws {
        let file = try fixture("exec /bin/sleep 30")
        let model = NetworkToolProcess()
        do { try await model.start(executable: file, arguments: [], timeout: 0.15) { _ in false }; XCTFail("must time out") } catch {}
        XCTAssertFalse(model.running); XCTAssertFalse(model.starting); XCTAssertNotNil(model.failure)
        model.stop(force: true)
        let fail = try fixture("echo 'password: secret-value' >&2\nexit 7")
        do { try await model.start(executable: fail, arguments: []) { _ in false }; XCTFail("must fail") } catch {}
        XCTAssertFalse(model.running)
        XCTAssertFalse(model.failure?.contains("secret-value") ?? true)
    }
    @MainActor
    func testInheritedToolTokensAndTLSKeyLogCanBeRemoved() async throws {
        let file = try fixture("printf '%s\\n' \"${TUNNEL_TOKEN-unset} ${SSLKEYLOGFILE-unset} READY\"\nexec /bin/sleep 30")
        let model = NetworkToolProcess()
        defer { model.stop(force: true) }
        try await model.start(executable: file, arguments: [], environment: ["TUNNEL_TOKEN": "fixture-token", "SSLKEYLOGFILE": "fixture-key-file"],
            removeEnvironmentPrefixes: ["TUNNEL_"], removeEnvironmentKeys: ["SSLKEYLOGFILE"]) { $0.contains("READY") }
        XCTAssertTrue(model.logs.contains("unset unset READY"))
        XCTAssertFalse(model.logs.contains("fixture-token"))
    }
    @MainActor
    func testSynchronousKernelStopReapsChildAndRemovesConfiguration() async throws {
        let file = try fixture("if [ \"$1\" = -t ]; then exit 0; fi\necho $$ > \"$0.pid\"\ntrap '' TERM\nexec /bin/sleep 30")
        let directory = file.deletingLastPathComponent().appendingPathComponent("runtime")
        let kernel = ManagedMihomo(executable: file)
        defer { kernel.stop(waitForExit: true) }
        let task = Task { try await kernel.start(source: "proxies: []\nrules: ['MATCH,DIRECT']", directory: directory) }
        for _ in 0..<30 {
            if FileManager.default.fileExists(atPath: file.appendingPathExtension("pid").path) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let pid = Int32(try String(contentsOf: file.appendingPathExtension("pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        kernel.stop(waitForExit: true)
        do { _ = try await task.value; XCTFail("cancelled start must not succeed") } catch {}
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    @MainActor
    func testCancellationWhileReadinessAwaitsCannotResurrectProcess() async throws {
        let file = try fixture("exec /bin/sleep 30")
        let model = NetworkToolProcess()
        let task = Task { try await model.start(executable: file, arguments: []) { _ in try? await Task.sleep(nanoseconds: 200_000_000); return true } }
        try await Task.sleep(nanoseconds: 50_000_000)
        model.stop(force: true)
        do { try await task.value; XCTFail("must cancel") } catch {}
        XCTAssertFalse(model.running); XCTAssertFalse(model.starting)
    }
}

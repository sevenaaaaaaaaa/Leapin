import XCTest
import LeapinCore
import LeapinControl
import LeapinIntegrations
@testable import LeapinRuntime

/// The menu bar's speed test in Mihomo mode has to go through the kernel: the
/// app's own dialer cannot speak clash protocols. These cases run a real kernel
/// and prove the whole path — proxies, mode, delay, LPHealth, the menu snapshot.
@MainActor
final class MihomoLatencyTests: XCTestCase {
    private func makeEngine() throws -> (LeapinEngine, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leapin-latency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ProfileStore(root: root)
        let port = try LoopbackPort.available()
        let profile = Profile(name: "Latency fixture",
                              general: GeneralConfig(mixedPort: port, httpPort: 0, socksPort: 0,
                                                     captureEnabled: false, dnsHijack: false,
                                                     controlEnabled: false),
                              rules: [Rule(kind: .match, value: "", policy: "DIRECT")])
        _ = try store.save(profile)
        store.activeProfileID = profile.id
        return (LeapinEngine(store: store), root)
    }

    private let source = """
    proxies:
      - name: Test node
        type: socks5
        server: 127.0.0.1
        port: 9
    proxy-groups:
      - name: PROXY
        type: select
        proxies: [DIRECT, REJECT]
    rules:
      - MATCH,PROXY
    """

    func testKernelDelayAndSnapshotDriveTheMenuBar() async throws {
        guard KernelExecutable.mihomo() != nil else { throw XCTSkip("Mihomo not installed") }
        let (engine, root) = try makeEngine()
        defer {
            engine.stop()
            try? FileManager.default.removeItem(at: root)
        }

        try await engine.commitImport(ImportPreparation(text: source, name: "Latency fixture"), kernel: .mihomo)
        await engine.start()
        XCTAssertEqual(engine.state, .running, engine.lastError ?? "")
        XCTAssertEqual(engine.executionKernel, .mihomo)

        // The kernel is the source of truth for groups and nodes.
        let proxies = try await engine.managedKernel.proxies()
        XCTAssertTrue(proxies.contains { $0.name == "DIRECT" })
        let group = try XCTUnwrap(proxies.first { $0.name == "PROXY" })
        XCTAssertTrue(group.isSelectable)
        XCTAssertEqual(group.members, ["DIRECT", "REJECT"])
        let mode = await engine.managedKernel.mode()
        XCTAssertNotNil(mode)

        // A builtin cannot be measured, and the kernel's own refusal is carried
        // through as readable text instead of a generic failure.
        let rejected = await engine.managedKernel.delay("REJECT", url: MenuBarKit.testURL, timeoutMs: 1_500)
        XCTAssertNil(rejected.latencyMs)
        XCTAssertEqual(rejected.status, 503)
        XCTAssertNotNil(rejected.error)

        // Test the whole node set: only DIRECT is dialable, and the result lands
        // in LPHealth so every surface reads the same number.
        let results = try await engine.controlTestNodes(names: [])
        XCTAssertTrue(results.contains { $0.name == "Test node" }, "\(results)")
        XCTAssertTrue(results.contains { $0.name == "DIRECT" }, "DIRECT 保留为可测基线：\(results)")
        XCTAssertNotNil(LPHealth.shared.health(for: "DIRECT")?.checkedAt)

        // Builtins and groups are refused by name, not by a mode-wide "not supported".
        do {
            _ = try await engine.controlTestNodes(names: ["REJECT"])
            XCTFail("REJECT 不应参与测速")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("内置策略"), error.localizedDescription)
        }

        // The menu bar snapshot reads the same kernel state.
        let snapshot = await engine.menuBarSnapshot()
        XCTAssertEqual(snapshot.kernel, .mihomo)
        XCTAssertTrue(snapshot.running)
        XCTAssertTrue(snapshot.switchableGroups.contains { $0.name == "PROXY" })
        XCTAssertEqual(snapshot.mode, "rule")
        XCTAssertNotNil(snapshot.current)
        XCTAssertEqual(snapshot.currentGroup, "PROXY")

        // Switching a node goes through PUT /proxies/{group} and sticks.
        try await engine.menuBarSelect(group: "PROXY", member: "DIRECT")
        let after = await engine.menuBarSnapshot()
        XCTAssertEqual(after.current, "DIRECT")
    }
}

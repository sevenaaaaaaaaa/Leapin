import XCTest
@testable import LeapinRuntime
import LeapinCore
import LeapinControl

/// Engine-side coverage for /v1/nodes: the transport is exercised in
/// LeapinControlTests, here the mapping from profile + health table to wire
/// nodes is what can regress.
@MainActor
final class NodeListTests: XCTestCase {
    private var tempDir: URL!
    private var store: ProfileStore!
    private var engine: LeapinEngine!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leapin-nodes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = ProfileStore(root: tempDir)
        LPHealth.shared.reset()
    }

    override func tearDown() async throws {
        LPHealth.shared.reset()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    private func makeEngine() throws -> LeapinEngine {
        let profile = Profile(name: "test",
                              outbounds: [
                                  OutboundConfig(name: "HK-01", type: .trojan,
                                                 host: "hk.example.com", port: 443,
                                                 password: "secret", tls: true, rawType: "trojan"),
                                  .direct, .reject
                              ],
                              groups: [PolicyGroup(name: "Proxy", type: .select,
                                                   proxies: ["HK-01", "DIRECT"])])
        _ = try store.save(profile)
        return LeapinEngine(store: store)
    }

    func testControlNodesMapsOutboundsMembershipAndHealth() async throws {
        engine = try makeEngine()
        LPHealth.shared.record(name: "HK-01", latencyMs: 87)

        let nodes = await engine.controlNodes()
        XCTAssertEqual(nodes.count, 3)

        let hk = try XCTUnwrap(nodes.first { $0.name == "HK-01" })
        XCTAssertEqual(hk.type, "trojan")
        XCTAssertEqual(hk.server, "hk.example.com")
        XCTAssertEqual(hk.port, 443)
        XCTAssertTrue(hk.dialable)
        XCTAssertEqual(hk.groups, ["Proxy"])
        XCTAssertEqual(hk.latencyMs, 87)
        XCTAssertNotNil(hk.checkedAtMs)
        XCTAssertNil(hk.lastError)

        // DIRECT stays testable as the direct-connection baseline; REJECT does not.
        let direct = try XCTUnwrap(nodes.first { $0.name == "DIRECT" })
        XCTAssertTrue(direct.dialable)
        XCTAssertEqual(direct.groups, ["Proxy"])
        XCTAssertNil(direct.latencyMs)
        XCTAssertNil(direct.checkedAtMs)

        let reject = try XCTUnwrap(nodes.first { $0.name == "REJECT" })
        XCTAssertFalse(reject.dialable)

        // Health lookup is case-insensitive, matching LPHealth's keying.
        let lowercased = await engine.controlNodes().first { $0.name == "HK-01" }
        XCTAssertEqual(lowercased?.latencyMs, 87)
    }

    func testControlNodesFailureRecordSurfacesErrorAndStreak() async throws {
        engine = try makeEngine()
        LPHealth.shared.record(name: "HK-01", latencyMs: nil, error: "timeout")
        LPHealth.shared.record(name: "HK-01", latencyMs: nil, error: "timeout")

        let nodes = await engine.controlNodes()
        let hk = try XCTUnwrap(nodes.first { $0.name == "HK-01" })
        XCTAssertNil(hk.latencyMs)
        XCTAssertNotNil(hk.checkedAtMs)
        XCTAssertEqual(hk.lastError, "timeout")
        XCTAssertEqual(hk.consecutiveFailures, 2)
    }

    func testControlTestNodesRejectsUnknownAndPseudoOutbounds() async throws {
        engine = try makeEngine()
        do {
            _ = try await engine.controlTestNodes(names: ["NOPE"])
            XCTFail("unknown node must throw notFound")
        } catch let error as ControlError {
            guard case .notFound = error else { return XCTFail("expected notFound, got \(error)") }
        }
        do {
            _ = try await engine.controlTestNodes(names: ["REJECT"])
            XCTFail("REJECT must throw badRequest")
        } catch let error as ControlError {
            guard case .badRequest = error else { return XCTFail("expected badRequest, got \(error)") }
        }
    }
}

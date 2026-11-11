import XCTest
import LeapinCore
import LeapinIntegrations
@testable import LeapinRuntime

private actor FakeTailnet: TailnetControlling {
    var snapshots: [TailnetSnapshot]
    var reconnects = 0
    var pings: [String] = []
    var pingFails = false
    init(_ snapshots: [TailnetSnapshot]) { self.snapshots = snapshots }
    func status() async throws -> TailnetSnapshot { snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0] }
    func reconnect() async throws { reconnects += 1 }
    func ping(address: String) async throws -> String {
        pings.append(address)
        if pingFails { throw LeapinError.timeout }
        return "fixture pong"
    }
    func setPingFailure() { pingFails = true }
}

final class HomeConnectionsTests: XCTestCase {
    private let peer = TailnetPeer(id: "home", hostname: "NAS", dnsName: "nas.fixture.ts.net.", addresses: ["100.64.1.2", "fd7a:115c:a1e0::2"], online: true)
    private func snapshot(state: String = "Running", selfID: String = "self", peers: [TailnetPeer]? = nil, tun: Bool = true) -> TailnetSnapshot {
        TailnetSnapshot(state: state, selfID: selfID, usesSystemTunnel: tun, peers: peers ?? [peer])
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testOnlySelectedDeviceResourcesAllowedAndLiteralAddressMatchesService() throws {
        let value = try HomeConnection(snapshot: snapshot(), peer: peer, resource: "https://NAS.fixture.ts.net:5001/files")
        XCTAssertEqual(value.port, 5001)
        XCTAssertEqual(value.host, "nas.fixture.ts.net")
        let v6 = try HomeConnection(snapshot: snapshot(), peer: peer, resource: "smb://[fd7a:115c:a1e0::2]/share")
        XCTAssertEqual(v6.address, "fd7a:115c:a1e0::2")
        XCTAssertEqual(v6.port, 445)
        for url in ["https://example.com", "https://nas.fixture.ts.net.attacker.test", "http://192.168.1.2", "https://name:secret@nas.fixture.ts.net", "ssh://nas.fixture.ts.net", "http://nas.fixture.ts.net:0", "http://nas.fixture.ts.net:65536"] {
            XCTAssertThrowsError(try HomeConnection(snapshot: snapshot(), peer: peer, resource: url), url)
        }
        XCTAssertThrowsError(try HomeConnection(snapshot: snapshot(tun: false), peer: peer, resource: "https://nas.fixture.ts.net"))
    }
    func testOverlayOnlyChangesExactRuleAndHostDNS() throws {
        let home = try HomeConnection(snapshot: snapshot(), peer: peer, resource: "https://nas.fixture.ts.net")
        let original = Profile(name: "Original", rules: [Rule(kind: .match, value: "", policy: "REJECT")])
        var expected = original
        expected.rules.insert(Rule(kind: .domain, value: home.host, policy: "DIRECT", raw: "DOMAIN,\(home.host),DIRECT"), at: 0)
        XCTAssertEqual(home.routing(original), expected)
        var dns = original.dns; dns.hosts[home.host] = home.address
        XCTAssertEqual(home.dns(original.dns), dns)
    }
    @MainActor
    func testConfigureSavesOnlyAfterPathAndServiceChecksThenPersistsPrivately() async throws {
        let root = try root()
        let cli = FakeTailnet([snapshot()])
        let home = HomeConnections(root: root, connector: cli, probe: { address, port in
            XCTAssertEqual(address, "100.64.1.2"); XCTAssertEqual(port, 5001)
        })
        let ok = await home.configure(peerID: "home", resource: "https://nas.fixture.ts.net:5001/")
        XCTAssertTrue(ok); XCTAssertNotNil(home.verifiedAt)
        XCTAssertEqual(try HomeConnection.load(root: root), home.saved)
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("home-connection.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        try home.forget()
        XCTAssertNil(home.saved)
        XCTAssertNil(try HomeConnection.load(root: root))
        let reconnects = await cli.reconnects
        XCTAssertEqual(reconnects, 0)
    }
    @MainActor
    func testPingSuccessDoesNotHideServiceFailureOrCommitResource() async throws {
        let root = try root()
        let home = HomeConnections(root: root, connector: FakeTailnet([snapshot()]), probe: { _, _ in throw LeapinError.timeout })
        let ok = await home.configure(peerID: "home", resource: "https://nas.fixture.ts.net")
        XCTAssertFalse(ok); XCTAssertTrue(home.failed); XCTAssertNil(home.verifiedAt)
        XCTAssertNil(try HomeConnection.load(root: root))
    }
    @MainActor
    func testStoppedReconnectRechecksIdentityBeforeOpening() async throws {
        let root = try root()
        let saved = try HomeConnection(snapshot: snapshot(), peer: peer, resource: "https://nas.fixture.ts.net")
        try HomeConnection.save(saved, root: root)
        let cli = FakeTailnet([snapshot(state: "Stopped"), snapshot()])
        let home = HomeConnections(root: root, connector: cli, probe: { _, _ in })
        let url = await home.verifySaved()
        XCTAssertEqual(url, saved.resource)
        let reconnects = await cli.reconnects
        XCTAssertEqual(reconnects, 1)
        let changed = HomeConnections(root: root, connector: FakeTailnet([snapshot(state: "Stopped"), snapshot(selfID: "other-account")]), probe: { _, _ in XCTFail("must not dial") })
        let rejected = await changed.verifySaved()
        XCTAssertNil(rejected); XCTAssertTrue(changed.failed)
    }
    @MainActor
    func testOfflineAndFailedOverlayPingNeverOpenSavedResource() async throws {
        let root = try root()
        let saved = try HomeConnection(snapshot: snapshot(), peer: peer, resource: "https://nas.fixture.ts.net")
        try HomeConnection.save(saved, root: root)
        let offline = TailnetPeer(id: peer.id, hostname: peer.hostname, dnsName: peer.dnsName, addresses: peer.addresses, online: false)
        let model = HomeConnections(root: root, connector: FakeTailnet([snapshot(peers: [offline])]), probe: { _, _ in XCTFail("must not probe offline device") })
        let offlineURL = await model.verifySaved()
        XCTAssertNil(offlineURL)
        let cli = FakeTailnet([snapshot()]); await cli.setPingFailure()
        let pingFailed = HomeConnections(root: root, connector: cli, probe: { _, _ in XCTFail("must not probe after failed ping") })
        let failedURL = await pingFailed.verifySaved()
        XCTAssertNil(failedURL); XCTAssertNil(pingFailed.verifiedAt)
        XCTAssertEqual(try HomeConnection.load(root: root), saved)
    }
    @MainActor
    func testDNSResourceFollowsFreshAddressOfSameStablePeer() async throws {
        let root = try root()
        let saved = try HomeConnection(snapshot: snapshot(), peer: peer, resource: "https://nas.fixture.ts.net")
        try HomeConnection.save(saved, root: root)
        let moved = TailnetPeer(id: peer.id, hostname: peer.hostname, dnsName: peer.dnsName, addresses: ["100.64.1.9"], online: true)
        let home = HomeConnections(root: root, connector: FakeTailnet([snapshot(peers: [moved])]), probe: { address, _ in XCTAssertEqual(address, "100.64.1.9") })
        let url = await home.verifySaved()
        XCTAssertEqual(url, saved.resource)
        XCTAssertEqual(home.saved?.address, "100.64.1.9")
    }
    @MainActor
    func testOfflineOrRemovedPeerAndRoutingFailurePreservePreviousBinding() async throws {
        let root = try root()
        let original = try HomeConnection(snapshot: snapshot(), peer: peer, resource: "https://nas.fixture.ts.net")
        try HomeConnection.save(original, root: root)
        let missing = HomeConnections(root: root, connector: FakeTailnet([snapshot(peers: [])]), probe: { _, _ in XCTFail("must not dial") })
        let noURL = await missing.verifySaved()
        XCTAssertNil(noURL)
        let home = HomeConnections(root: root, connector: FakeTailnet([snapshot()]), probe: { _, _ in })
        let ok = await home.configure(peerID: "home", resource: "https://nas.fixture.ts.net:5001", applyRouting: { throw LeapinError.timeout })
        XCTAssertFalse(ok); XCTAssertEqual(home.saved, original)
        XCTAssertEqual(try HomeConnection.load(root: root), original)
        XCTAssertNil(home.verifiedAt)
        XCTAssertThrowsError(try home.forget(applyRouting: { throw LeapinError.timeout }))
        XCTAssertEqual(try HomeConnection.load(root: root), original)
    }
}

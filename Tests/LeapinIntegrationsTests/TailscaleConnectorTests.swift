import XCTest
@testable import LeapinIntegrations

final class TailscaleConnectorTests: XCTestCase {
    func testStatusDecodesStableIDsAndFailsClosedWithoutTunnelEvidence() throws {
        let data = Data(#"{"BackendState":"Running","Version":"1.104","Self":{"ID":"self","HostName":"mac"},"Peer":{"key":{"ID":"home","HostName":"nas","DNSName":"nas.test.ts.net.","TailscaleIPs":["100.64.1.2"],"Online":true}}}"#.utf8)
        let status = try TailnetSnapshot.decode(data)
        XCTAssertFalse(status.usesSystemTunnel)
        XCTAssertEqual(status.selfID, "self")
        XCTAssertEqual(status.peers.first?.id, "home")
        XCTAssertEqual(status.peers.first?.normalizedDNSName, "nas.test.ts.net")
        XCTAssertEqual(try TailnetSnapshot.decode(Data(#"{"BackendState":"NeedsLogin"}"#.utf8)).state, "NeedsLogin")
        XCTAssertThrowsError(try TailnetSnapshot.decode(Data(#"{"unexpected":true}"#.utf8)))
    }
    func testOnlyTailnetNodeLiteralsAreAccepted() {
        for address in ["100.64.0.1", "100.127.255.254", "fd7a:115c:a1e0::1"] { XCTAssertTrue(TailnetAddress.isNodeAddress(address), address) }
        for address in ["100.63.255.255", "100.128.0.1", "127.0.0.1", "192.168.1.1", "fd7a:115c:ffff::1", "nas.test.ts.net", "--reset"] { XCTAssertFalse(TailnetAddress.isNodeAddress(address), address) }
    }
    func testCLIArgumentsUseNoFlagsForReconnectAndNeverPassHostAsShell() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("tailscale-fixture")
        // The fixture owns the path and writes one argument per line. No actual Tailscale process is called.
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.args\"\nif [ \"$1\" = status ]; then printf '%s' '{\"BackendState\":\"Stopped\",\"TUN\":true}'; fi\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let cli = TailscaleConnector(executable: script)
        let status = try await cli.status()
        XCTAssertEqual(status.state, "Stopped")
        let args = script.appendingPathExtension("args")
        XCTAssertEqual(try String(contentsOf: args, encoding: .utf8), "status\n--json\n")
        try await cli.reconnect()
        XCTAssertEqual(try String(contentsOf: args, encoding: .utf8), "up\n")
        _ = try await cli.ping(address: "100.64.1.2")
        XCTAssertEqual(try String(contentsOf: args, encoding: .utf8), "ping\n--c\n1\n--timeout\n3s\n--until-direct=false\n100.64.1.2\n")
        do { _ = try await cli.ping(address: "--reset"); XCTFail("must reject") } catch {}
        XCTAssertFalse(try String(contentsOf: args, encoding: .utf8).contains("--reset"))
    }
}

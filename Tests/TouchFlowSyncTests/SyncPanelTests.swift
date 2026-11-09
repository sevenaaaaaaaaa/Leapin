import XCTest
import Foundation
@testable import TouchFlowSync
import TouchFlowCore
import TouchFlowNet

/// Panel tests use raw HTTP instead of SyncClient because the panel is
/// deliberately reachable without a device identity: a browser only needs the
/// bearer/query token.
final class SyncPanelTests: XCTestCase {

    private func tempRoot(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tf-panel-\(tag)-\(UUID().uuidString)", isDirectory: true)
    }

    private struct Rig {
        let root: URL
        let identity: DeviceIdentity
        let store: ProfileVersionStore
        let peers: PeerRegistry
        let server: SyncServer
        var port: UInt16 { server.listeningPort ?? 0 }
    }

    private func makeRig(token: String?, deviceName: String = "Mac-A") throws -> Rig {
        let root = tempRoot("rig")
        let identity = try DeviceIdentity.loadOrCreate(store: MemorySecretStore())
        let store = ProfileVersionStore(root: root.appendingPathComponent("sync", isDirectory: true))
        let peers = PeerRegistry(root: root.appendingPathComponent("sync/peers", isDirectory: true))
        let server = SyncServer(identity: identity, store: store, peers: peers,
                                port: 0, bindLAN: false, deviceName: deviceName,
                                panelToken: token)
        _ = try server.start()
        return Rig(root: root, identity: identity, store: store, peers: peers, server: server)
    }

    private func teardown(_ rig: Rig) {
        rig.server.stop()
        try? FileManager.default.removeItem(at: rig.root)
    }

    private struct Reply {
        var status: Int
        var contentType: String
        var body: Data
        var text: String { String(decoding: body, as: UTF8.self) }
    }

    private func request(_ method: String, _ path: String, port: UInt16,
                         body: Data = Data()) async throws -> Reply {
        let socket = try await NetSocket.connect(host: "127.0.0.1", port: port, timeout: 5)
        defer { socket.close() }
        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: 127.0.0.1:\(port)\r\n"
        head += "Accept: */*\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var wire = Data(head.utf8)
        wire.append(body)
        try await socket.write(wire)

        var buffer = Data()
        while let chunk = try await socket.read(maxLength: 16 * 1024) {
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if buffer.count > 2 << 20 { break }
        }
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator),
              let headText = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            throw NSError(domain: "SyncPanelTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "malformed reply: \(buffer.count) bytes"])
        }
        let lines = headText.components(separatedBy: "\r\n")
        let statusParts = lines[0].split(separator: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw NSError(domain: "SyncPanelTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "bad status line \(lines[0])"])
        }
        var contentType = ""
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).lowercased()
            if name == "content-type" {
                contentType = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return Reply(status: status, contentType: contentType,
                     body: Data(buffer[headerEnd.upperBound...]))
    }

    private func sampleProfile(name: String = "示例", ruleValue: String = "rules.example.com") -> Profile {
        var profile = Profile(name: name)
        profile.rules = [Rule(kind: .domain, value: ruleValue, policy: "DIRECT")]
        return profile
    }

    // MARK: - 1. Auth + read-only

    func testPanelRequiresTokenAndRefusesEveryMutation() async throws {
        let token = String(repeating: "a", count: 64)
        let rig = try makeRig(token: token)
        defer { teardown(rig) }

        let anonymous = try await request("GET", "/panel", port: rig.port)
        XCTAssertEqual(anonymous.status, 401, "a browser without the token must not read the panel")

        let wrong = try await request("GET", "/panel?token=" + String(repeating: "b", count: 64),
                                      port: rig.port)
        XCTAssertEqual(wrong.status, 401)

        let read = try await request("GET", "/panel?token=" + token, port: rig.port)
        XCTAssertEqual(read.status, 200)
        XCTAssertTrue(read.contentType.hasPrefix("text/html"), read.contentType)

        let json = try await request("GET", "/panel.json?token=" + token, port: rig.port)
        XCTAssertEqual(json.status, 200)
        XCTAssertTrue(json.contentType.hasPrefix("application/json"), json.contentType)
        XCTAssertTrue(json.text.contains("\"readOnly\":true"), json.text)

        // A valid token must not turn the panel into a write surface.
        for method in ["POST", "PUT", "PATCH", "DELETE"] {
            let mutation = try await request(method, "/panel?token=" + token, port: rig.port)
            XCTAssertEqual(mutation.status, 405, "\(method) /panel must be refused")
        }
    }

    func testPanelIsAbsentWhenNoTokenIsConfigured() async throws {
        let rig = try makeRig(token: nil)
        defer { teardown(rig) }
        let reply = try await request("GET", "/panel", port: rig.port)
        XCTAssertEqual(reply.status, 404, "panel must be off unless a token exists")
    }

    // MARK: - 2. Metadata + escaping + no config content

    func testPanelShowsVersionsPointersAndPeersWithoutConfigContent() async throws {
        let token = String(repeating: "c", count: 64)
        let rig = try makeRig(token: token, deviceName: "A<B>&\"测试")
        defer { teardown(rig) }

        let profile = sampleProfile(ruleValue: "secret.example.net")
        let version = try rig.store.put(profile, originDevice: rig.identity.deviceID)
        try rig.store.setPointer(version: version.id, device: rig.identity.deviceID, atMs: 1_700_000_000_000)

        let peerIdentity = try DeviceIdentity.loadOrCreate(store: MemorySecretStore())
        let peerDevice = SyncDevice(identity: peerIdentity, name: "iPhone")
        rig.peers.upsert(peerDevice, at: Date(timeIntervalSince1970: 1_700_000_100))

        let json = try await request("GET", "/panel.json?token=" + token, port: rig.port)
        XCTAssertEqual(json.status, 200)
        let snapshot = try JSONDecoder.sync.decode(SyncPanelSnapshot.self, from: json.body)
        XCTAssertEqual(snapshot.device.deviceID, rig.identity.deviceID)
        XCTAssertEqual(snapshot.versions.map(\.id), [version.id])
        XCTAssertEqual(snapshot.effective, version.id)
        XCTAssertEqual(snapshot.pointers[rig.identity.deviceID]?.version, version.id)
        XCTAssertEqual(snapshot.peers.count, 1)
        XCTAssertEqual(snapshot.peers.first?.device.name, "iPhone")
        XCTAssertTrue(snapshot.readOnly)
        XCTAssertFalse(json.text.contains("secret.example.net"),
                       "the panel must never expose rule values")

        let html = try await request("GET", "/panel?token=" + token, port: rig.port)
        XCTAssertEqual(html.status, 200)
        XCTAssertTrue(html.text.contains("A&lt;B&gt;&amp;&quot;测试"),
                      "device name must be HTML-escaped")
        XCTAssertTrue(html.text.contains(String(version.id.prefix(12))))
        XCTAssertTrue(html.text.contains("iPhone"))
        XCTAssertFalse(html.text.contains("<script"), "panel must not ship scripts")
        XCTAssertFalse(html.text.contains("secret.example.net"))
    }

    // MARK: - 3. Token file

    func testPanelTokenFileIsPrivateAndRotatable() throws {
        let root = tempRoot("token")
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try PanelTokenStore.token(root: root)
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit })

        let file = PanelTokenStore.url(root: root)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(permissions & 0o777, 0o600, "panel token must be 0600")
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let directoryPermissions = (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(directoryPermissions & 0o777, 0o700, "token directory must be 0700")

        XCTAssertEqual(try PanelTokenStore.token(root: root), first, "token must be stable until rotated")
        let rotated = try PanelTokenStore.rotate(root: root)
        XCTAssertNotEqual(rotated, first)
        XCTAssertEqual(try PanelTokenStore.token(root: root), rotated)
    }

    // MARK: - 4. Regression: PeerRegistry must not re-enter its own NSLock

    func testPeerUpsertAndTouchDoNotDeadlock() {
        let root = tempRoot("peers")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = PeerRegistry(root: root)
        let device = SyncDevice(deviceID: "d1", name: "A", publicKey: "k", fingerprint: "f")
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = registry.upsert(device, at: Date(timeIntervalSince1970: 1))
            _ = registry.upsert(device, at: Date(timeIntervalSince1970: 2))
            registry.touch(deviceID: "d1", at: Date(timeIntervalSince1970: 3))
            done.signal()
        }
        XCTAssertTrue(done.wait(timeout: .now() + 3) == .success,
                       "PeerRegistry upsert/touch must not deadlock on a recursive NSLock")
        XCTAssertEqual(registry.peer(deviceID: "d1")?.pairedAtMs, 1_000,
                       "pairedAtMs must keep the first pairing time")
    }
}

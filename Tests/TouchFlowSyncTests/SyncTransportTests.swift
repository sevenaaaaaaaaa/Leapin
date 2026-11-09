import XCTest
import Foundation
import Network
@testable import TouchFlowSync
import TouchFlowCore
import TouchFlowPolicy

/// End-to-end tests for the LAN sync transport. Everything runs on 127.0.0.1
/// with an ephemeral port and a throwaway temp directory; no keychain, no user
/// profile, no fixed port.
final class SyncTransportTests: XCTestCase {

    // MARK: - Fixtures

    private struct Rig {
        let rootA: URL
        let rootB: URL
        let storeA: ProfileVersionStore
        let storeB: ProfileVersionStore
        let peersA: PeerRegistry
        let peersB: PeerRegistry
        let idA: DeviceIdentity
        let idB: DeviceIdentity
        let server: SyncServer

        var port: UInt16 { server.listeningPort ?? 0 }

        func clientA(port: UInt16? = nil) -> SyncClient {
            SyncClient(identity: idA, store: storeA, peers: peersA, host: "127.0.0.1",
                       port: port ?? self.port, deviceName: "A")
        }

        func clientB(port: UInt16? = nil) -> SyncClient {
            SyncClient(identity: idB, store: storeB, peers: peersB, host: "127.0.0.1",
                       port: port ?? self.port, deviceName: "B")
        }
    }

    private func tempRoot(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tf-sync-\(tag)-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeRig(bindLAN: Bool = false) throws -> Rig {
        let rootA = tempRoot("a"), rootB = tempRoot("b")
        let idA = try DeviceIdentity.loadOrCreate(store: MemorySecretStore())
        let idB = try DeviceIdentity.loadOrCreate(store: MemorySecretStore())
        let peersA = PeerRegistry(root: rootA.appendingPathComponent("peers", isDirectory: true))
        let peersB = PeerRegistry(root: rootB.appendingPathComponent("peers", isDirectory: true))
        let storeA = ProfileVersionStore(root: rootA)
        let storeB = ProfileVersionStore(root: rootB)
        let server = SyncServer(identity: idA, store: storeA, peers: peersA,
                                port: 0, bindLAN: bindLAN, deviceName: "Mac-A")
        _ = try server.start()
        return Rig(rootA: rootA, rootB: rootB, storeA: storeA, storeB: storeB,
                   peersA: peersA, peersB: peersB, idA: idA, idB: idB, server: server)
    }

    private func teardown(_ rig: Rig) {
        rig.server.stop()
        try? FileManager.default.removeItem(at: rig.rootA)
        try? FileManager.default.removeItem(at: rig.rootB)
    }

    private func sampleProfile(name: String = "示例", rules: Int = 3) -> Profile {
        var profile = Profile(name: name)
        profile.rules = (0..<rules).map { index in
            Rule(kind: .domain, value: "host\(index).example.com", policy: "DIRECT")
        }
        profile.sourcePath = "/tmp/import-\(UUID().uuidString).surge"
        return profile
    }

    /// Publishes a version as this device's active pointer.
    @discardableResult
    private func adopt(_ version: ProfileVersion, in store: ProfileVersionStore,
                       device: String, atMs: Int64? = nil) throws -> ActivePointer {
        let stamp = atMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        try store.setPointer(version: version.id, device: device, atMs: stamp)
        return store.pointer(device: device)
            ?? ActivePointer(version: version.id, updatedAtMs: stamp, updatedBy: device)
    }

    private func codeOtherThan(_ current: String) -> String {
        let value = (Int(current) ?? 0)
        return String(format: "%06d", (value + 1) % 1_000_000)
    }

    // MARK: - 1. Pairing

    func testPairingRejectsWrongCodeAndIsSingleUse() async throws {
        let rig = try makeRig()
        defer { teardown(rig) }

        let client = rig.clientB()
        let info = try await client.info()
        XCTAssertEqual(info.deviceID, rig.idA.deviceID, "unauthenticated /v1/info must identify the host")
        XCTAssertEqual(info.publicKey, DeviceIdentity.encodePublicKey(rig.idA.publicKeyData))

        let code = rig.server.pairingCode
        XCTAssertEqual(code.count, 6)

        do {
            _ = try await client.pair(code: codeOtherThan(code))
            XCTFail("a wrong pairing code must be rejected")
        } catch {
            guard case SyncError.badPairingCode = error else {
                return XCTFail("expected badPairingCode, got \(error)")
            }
        }
        XCTAssertNil(rig.peersB.peer(deviceID: rig.idA.deviceID),
                     "a failed attempt must not pin the peer")

        let serverDevice = try await client.pair(code: code)
        XCTAssertEqual(serverDevice.deviceID, rig.idA.deviceID)
        let peer = rig.peersB.peer(deviceID: rig.idA.deviceID)
        XCTAssertNotNil(peer, "pairing must record the peer")
        XCTAssertEqual(peer?.device.publicKey, DeviceIdentity.encodePublicKey(rig.idA.publicKeyData))
        XCTAssertEqual(peer?.device.fingerprint, rig.idA.fingerprint)

        do {
            _ = try await client.pair(code: code)
            XCTFail("the pairing code is single use")
        } catch {
            guard case SyncError.badPairingCode = error else {
                return XCTFail("expected badPairingCode on reuse, got \(error)")
            }
        }

        // A refreshed code works again, and re-pairing the same device is allowed.
        let refreshed = rig.server.refreshPairingCode()
        XCTAssertNotEqual(refreshed, code)
        let again = try await client.pair(code: refreshed)
        XCTAssertEqual(again.deviceID, rig.idA.deviceID)
    }

    // MARK: - 2. Convergence

    func testTwoStoresConvergeInOneRoundUnderFiveSeconds() async throws {
        let rig = try makeRig()
        defer { teardown(rig) }

        let version = try rig.storeA.put(sampleProfile(name: "A 的版本"), originDevice: rig.idA.deviceID)
        try adopt(version, in: rig.storeA, device: rig.idA.deviceID)

        let client = rig.clientB()
        _ = try await client.pair(code: rig.server.pairingCode)

        let started = Date()
        let report = try await client.syncOnce()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 5.0, "one sync round took \(elapsed)s")
        XCTAssertNotNil(rig.storeB.meta(id: version.id), "B must receive the version metadata")
        XCTAssertNoThrow(try rig.storeB.data(id: version.id))
        XCTAssertEqual(rig.storeB.effectiveActiveVersion(), version.id)
        XCTAssertEqual(rig.storeA.effectiveActiveVersion(), version.id)
        XCTAssertTrue(report.pulled.contains(version.id))
        XCTAssertEqual(report.active, version.id)
    }

    // MARK: - 3. Offline edit survives a restart

    func testOfflineEditSurvivesServerRestart() async throws {
        let rig = try makeRig()
        defer { teardown(rig) }

        let v1 = try rig.storeA.put(sampleProfile(name: "A 的版本", rules: 2), originDevice: rig.idA.deviceID)
        try adopt(v1, in: rig.storeA, device: rig.idA.deviceID, atMs: SyncServer.nowMs() - 60_000)

        var client = rig.clientB()
        _ = try await client.pair(code: rig.server.pairingCode)
        _ = try await client.syncOnce()
        XCTAssertEqual(rig.storeB.effectiveActiveVersion(), v1.id)

        // A goes away and B edits locally while offline.
        rig.server.stop()
        XCTAssertFalse(rig.server.isRunning)
        let v2 = try rig.storeB.put(sampleProfile(name: "B 离线编辑", rules: 5), originDevice: rig.idB.deviceID)
        try adopt(v2, in: rig.storeB, device: rig.idB.deviceID, atMs: SyncServer.nowMs())
        XCTAssertEqual(rig.storeB.effectiveActiveVersion(), v2.id)
        XCTAssertNotNil(rig.storeB.meta(id: v2.id), "the offline edit must survive locally")

        // Same store and peer registry, fresh ephemeral port.
        let port = try rig.server.start()
        XCTAssertNotEqual(port, 0)
        client = rig.clientB(port: port)
        _ = try await client.syncOnce()

        XCTAssertNotNil(rig.storeA.meta(id: v2.id), "A must receive B's offline version")
        XCTAssertNoThrow(try rig.storeA.data(id: v2.id))
        XCTAssertEqual(rig.storeA.pointer(device: rig.idB.deviceID)?.version, v2.id)
        XCTAssertEqual(rig.storeA.effectiveActiveVersion(), v2.id)
        XCTAssertEqual(rig.storeB.effectiveActiveVersion(), v2.id)
        XCTAssertEqual(rig.storeA.effectiveActiveVersion(), rig.storeB.effectiveActiveVersion())
    }

    // MARK: - 4. Signature, tampering, replay

    func testSignedRequestsRejectForgeryAndReplay() async throws {
        let rig = try makeRig()
        defer { teardown(rig) }

        let client = rig.clientB()
        _ = try await client.pair(code: rig.server.pairingCode)
        let port = rig.port

        // Sanity: a correctly signed GET is accepted.
        let good = SyncAuth.headers(identity: rig.idB, method: "GET", path: "/v1/manifest", body: Data())
        let accepted = try await rawExchange(port: port, request: rawGET(port: port, path: "/v1/manifest", headers: good))
        XCTAssertEqual(accepted.0, 200)

        // Signed by someone else but claiming B's device id: 401.
        var forged = SyncAuth.headers(identity: try DeviceIdentity.loadOrCreate(store: MemorySecretStore()),
                                      method: "GET", path: "/v1/manifest", body: Data())
        forged[SyncAuth.headerDevice] = rig.idB.deviceID
        let forgedStatus = try await rawExchange(port: port, request: rawGET(port: port, path: "/v1/manifest", headers: forged))
        XCTAssertEqual(forgedStatus.0, 401)

        // Valid envelope for a different path (tampered path): 401.
        let version = try rig.storeA.put(sampleProfile(name: "签名目标"), originDevice: rig.idA.deviceID)
        let tamperedHeaders = SyncAuth.headers(identity: rig.idB, method: "GET", path: "/v1/manifest", body: Data())
        let tampered = try await rawExchange(
            port: port, request: rawGET(port: port, path: "/v1/versions/\(version.id)", headers: tamperedHeaders))
        XCTAssertEqual(tampered.0, 401)

        // Same envelope twice: the nonce cache answers 409.
        let replayHeaders = SyncAuth.headers(identity: rig.idB, method: "GET", path: "/v1/manifest", body: Data())
        let first = try await rawExchange(port: port, request: rawGET(port: port, path: "/v1/manifest", headers: replayHeaders))
        XCTAssertEqual(first.0, 200)
        let second = try await rawExchange(port: port, request: rawGET(port: port, path: "/v1/manifest", headers: replayHeaders))
        XCTAssertEqual(second.0, 409, "a replayed nonce must be rejected")
    }

    func testUnpairedDeviceIsRejected() async throws {
        let rig = try makeRig()
        defer { teardown(rig) }
        let stranger = SyncClient(identity: rig.idB, store: rig.storeB, peers: rig.peersB,
                                  host: "127.0.0.1", port: rig.port, deviceName: "B")
        do {
            _ = try await stranger.fetchManifest()
            XCTFail("an unpaired device must not read the manifest")
        } catch {
            guard case SyncError.http(401) = error else {
                return XCTFail("expected http(401), got \(error)")
            }
        }
    }

    // MARK: - 5. Unknown version

    func testUnknownVersionReturns404() async throws {
        let rig = try makeRig()
        defer { teardown(rig) }

        let client = rig.clientB()
        _ = try await client.pair(code: rig.server.pairingCode)

        let absent = String(repeating: "ab", count: 32)
        do {
            _ = try await client.fetchVersion(id: absent)
            XCTFail("unknown version must not be served")
        } catch {
            guard case SyncError.http(404) = error else {
                return XCTFail("expected http(404), got \(error)")
            }
        }
    }

    // MARK: - 6. Versions are immutable

    func testRepeatedSyncDoesNotGrowVersionCount() async throws {
        let rig = try makeRig()
        defer { teardown(rig) }

        let v1 = try rig.storeA.put(sampleProfile(name: "版本一", rules: 2), originDevice: rig.idA.deviceID)
        try adopt(v1, in: rig.storeA, device: rig.idA.deviceID)
        let v2 = try rig.storeA.put(sampleProfile(name: "版本二", rules: 4), originDevice: rig.idA.deviceID)
        try adopt(v2, in: rig.storeA, device: rig.idA.deviceID, atMs: SyncServer.nowMs())

        let client = rig.clientB()
        _ = try await client.pair(code: rig.server.pairingCode)
        _ = try await client.syncOnce()

        XCTAssertEqual(rig.storeA.list().count, 2)
        XCTAssertEqual(rig.storeB.list().count, 2)

        _ = try await client.syncOnce()
        _ = try await client.syncOnce()

        XCTAssertEqual(rig.storeA.list().count, 2, "re-sync must not add versions on A")
        XCTAssertEqual(rig.storeB.list().count, 2, "re-sync must not add versions on B")
        XCTAssertEqual(Set(rig.storeB.list().map(\.id)), Set([v1.id, v2.id]))
        XCTAssertEqual(rig.storeB.effectiveActiveVersion(), v2.id)
    }

    // MARK: - 7. Bidirectional pointers in one round

    func testAnnounceResponsePointersAdvanceTheInitiator() async throws {
        let rig = try makeRig()
        defer { teardown(rig) }

        // Both sides publish before anyone syncs: A at t, B at t+1.
        let base = SyncServer.nowMs()
        let va = try rig.storeA.put(sampleProfile(name: "A 版本", rules: 1), originDevice: rig.idA.deviceID)
        try adopt(va, in: rig.storeA, device: rig.idA.deviceID, atMs: base)
        let vb = try rig.storeB.put(sampleProfile(name: "B 版本", rules: 6), originDevice: rig.idB.deviceID)
        try adopt(vb, in: rig.storeB, device: rig.idB.deviceID, atMs: base + 1_000)

        let client = rig.clientB()
        _ = try await client.pair(code: rig.server.pairingCode)
        let report = try await client.syncOnce()

        XCTAssertTrue(report.pointersChanged.contains(rig.idA.deviceID),
                      "manifest pointers must be merged")
        XCTAssertNotNil(rig.storeA.meta(id: vb.id))
        XCTAssertEqual(rig.storeA.pointer(device: rig.idB.deviceID)?.version, vb.id)
        XCTAssertEqual(rig.storeA.effectiveActiveVersion(), vb.id)
        XCTAssertEqual(rig.storeB.effectiveActiveVersion(), vb.id)
        XCTAssertEqual(report.active, vb.id)
    }
}

// MARK: - Raw HTTP helper (unsigned / forged / replayed requests)

private final class RawClaim: @unchecked Sendable {
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

private func rawGET(port: UInt16, path: String, headers: [String: String], body: Data = Data()) -> Data {
    var head = "GET \(path) HTTP/1.1\r\n"
    head += "Host: 127.0.0.1:\(port)\r\n"
    head += "User-Agent: tfctl-sync-tests/1\r\n"
    head += "Accept: application/json\r\n"
    for key in headers.keys.sorted() { head += "\(key): \(headers[key] ?? "")\r\n" }
    head += "Content-Length: \(body.count)\r\n"
    head += "Connection: close\r\n\r\n"
    var data = Data(head.utf8)
    data.append(body)
    return data
}

private func rawParse(_ buffer: Data) -> (Int, Data)? {
    let separator = Data("\r\n\r\n".utf8)
    guard let range = buffer.range(of: separator),
          let head = String(data: buffer[..<range.lowerBound], encoding: .utf8),
          let statusLine = head.components(separatedBy: "\r\n").first else { return nil }
    let parts = statusLine.split(separator: " ")
    guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
    return (status, Data(buffer[range.upperBound...]))
}

private func rawReceive(conn: NWConnection, buffer: Data, claim: RawClaim,
                        cont: CheckedContinuation<(Int, Data), Error>) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
        var accumulated = buffer
        if let data, !data.isEmpty { accumulated.append(data) }
        if isComplete || error != nil {
            guard claim.claim() else { return }
            conn.cancel()
            if let parsed = rawParse(accumulated) {
                cont.resume(returning: parsed)
            } else {
                cont.resume(throwing: SyncError.malformedResponse(
                    "raw response \(accumulated.count) bytes: \(error.map { "\($0)" } ?? "eof")"))
            }
            return
        }
        rawReceive(conn: conn, buffer: accumulated, claim: claim, cont: cont)
    }
}

private func rawExchange(port: UInt16, request: Data,
                         timeout: TimeInterval = 5) async throws -> (Int, Data) {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Int, Data), Error>) in
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            cont.resume(throwing: SyncError.transport("bad port \(port)"))
            return
        }
        let queue = DispatchQueue(label: "tf.sync.raw")
        let conn = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        let claim = RawClaim()
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                conn.send(content: request, completion: .contentProcessed { error in
                    if let error {
                        if claim.claim() { cont.resume(throwing: error) }
                        conn.cancel()
                        return
                    }
                    rawReceive(conn: conn, buffer: Data(), claim: claim, cont: cont)
                })
            case .failed(let error):
                if claim.claim() { cont.resume(throwing: error) }
                conn.cancel()
            default:
                break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            if claim.claim() {
                conn.cancel()
                cont.resume(throwing: SyncError.transport("raw exchange timed out"))
            }
        }
    }
}

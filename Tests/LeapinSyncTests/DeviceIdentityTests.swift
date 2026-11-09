import XCTest
@testable import LeapinSync
import LeapinCore
import LeapinPolicy

final class DeviceIdentityTests: XCTestCase {
    func testCreatePersistsAndReloads() throws {
        let store = MemorySecretStore()
        let a = try DeviceIdentity.loadOrCreate(store: store)
        let b = try DeviceIdentity.loadOrCreate(store: store)
        XCTAssertEqual(a.deviceID, b.deviceID)
        XCTAssertEqual(a.publicKeyData, b.publicKeyData)
        XCTAssertEqual(a.fingerprint.count, 19) // 4 groups of 4 + 3 dashes
        XCTAssertEqual(a.deviceID.count, 32)
    }

    func testSignAndVerify() throws {
        let identity = try DeviceIdentity.loadOrCreate(store: MemorySecretStore())
        let payload = Data("hello sync".utf8)
        let signature = try identity.sign(payload)
        XCTAssertTrue(DeviceIdentity.verify(signature: signature, payload: payload,
                                            publicKey: identity.publicKeyData))
        var tampered = Data(payload)
        tampered.append(0x21)
        XCTAssertFalse(DeviceIdentity.verify(signature: signature, payload: tampered,
                                             publicKey: identity.publicKeyData))
        let other = try DeviceIdentity.loadOrCreate(store: MemorySecretStore())
        XCTAssertFalse(DeviceIdentity.verify(signature: signature, payload: payload,
                                             publicKey: other.publicKeyData))
    }

    func testFileStoreIs0600() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tf-key-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSecretStore(directory: dir)
        _ = try DeviceIdentity.loadOrCreate(store: store)
        let perms = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
        let loaded = try DeviceIdentity.load(store: store)
        XCTAssertNotNil(loaded)
        try store.deleteSecret()
        XCTAssertNil(try DeviceIdentity.load(store: store))
    }

    func testAuthEnvelopeVerifiesAndRejectsTamper() throws {
        let id = try DeviceIdentity.loadOrCreate(store: MemorySecretStore())
        let body = Data("{\"a\":1}".utf8)
        let headers = SyncAuth.headers(identity: id, method: "POST", path: "/v1/announce", body: body)
        XCTAssertNoThrow(try SyncAuth.verify(headers: headers, method: "POST", path: "/v1/announce",
                                             body: body, peerPublicKey: id.publicKeyData))
        XCTAssertThrowsError(try SyncAuth.verify(headers: headers, method: "POST", path: "/v1/reload",
                                                 body: body, peerPublicKey: id.publicKeyData))
        var tamperedBody = body
        tamperedBody.append(0x20)
        XCTAssertThrowsError(try SyncAuth.verify(headers: headers, method: "POST", path: "/v1/announce",
                                                 body: tamperedBody, peerPublicKey: id.publicKeyData))
    }

    func testAuthRejectsStaleTimestamp() throws {
        let id = try DeviceIdentity.loadOrCreate(store: MemorySecretStore())
        let body = Data()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let headers = SyncAuth.headers(identity: id, method: "GET", path: "/v1/manifest", body: body, now: old)
        XCTAssertThrowsError(try SyncAuth.verify(headers: headers, method: "GET", path: "/v1/manifest",
                                                 body: body, peerPublicKey: id.publicKeyData)) { error in
            guard case SyncError.staleTimestamp = error else {
                return XCTFail("expected staleTimestamp, got \(error)")
            }
        }
    }
}

final class ProfileVersionStoreTests: XCTestCase {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tf-versions-\(UUID().uuidString)", isDirectory: true)
    }

    private func sampleProfile(name: String = "示例", rules: Int = 3) -> Profile {
        var profile = Profile(name: name)
        profile.rules = (0..<rules).map { i in
            Rule(kind: .domain, value: "host\(i).example.com", policy: "DIRECT")
        }
        profile.sourcePath = "/tmp/import-\(UUID().uuidString).surge"
        return profile
    }

    func testCanonicalHashIgnoresLocalIdentity() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileVersionStore(root: root)
        var a = sampleProfile()
        var b = a
        b.id = UUID()
        b.sourcePath = "/somewhere/else.conf"
        let va = try store.put(a, originDevice: "dev-a")
        let vb = try store.put(b, originDevice: "dev-b")
        XCTAssertEqual(va.id, vb.id, "same semantic content must share a version id")
        XCTAssertEqual(store.list().count, 1)
        a.name = "改名"
        let renamed = try store.put(a, originDevice: "dev-a")
        XCTAssertNotEqual(renamed.id, va.id)
        XCTAssertEqual(store.list().count, 2)
    }

    func testIngestRejectsCorruptContent() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileVersionStore(root: root)
        let meta = ProfileVersion(id: "deadbeef", name: "x", ruleCount: 0, bytes: 0,
                                  createdAtMs: 1, originDevice: "a")
        XCTAssertThrowsError(try store.ingest(content: Data("{}".utf8), meta: meta))
    }

    func testPointerIsMonotonicAndTieBreaksOnDevice() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileVersionStore(root: root)
        let v1 = try store.put(sampleProfile(rules: 1), originDevice: "dev-a")
        let v2 = try store.put(sampleProfile(rules: 2), originDevice: "dev-a")
        XCTAssertTrue(try store.setPointer(version: v2.id, device: "dev-a", atMs: 200))
        XCTAssertFalse(try store.setPointer(version: v1.id, device: "dev-a", atMs: 100))
        XCTAssertEqual(store.pointer(device: "dev-a")?.version, v2.id)
        XCTAssertTrue(try store.setPointer(version: v1.id, device: "dev-b", atMs: 200))
        XCTAssertEqual(store.pointer(device: "dev-b")?.version, v1.id)
        // Same timestamp: the lexicographically larger device id wins, so dev-b
        // (v1) beats dev-a (v2) deterministically on both peers.
        XCTAssertEqual(store.effectiveActiveVersion(), v1.id)
    }

    func testOverrideWinsThenClears() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileVersionStore(root: root)
        let v1 = try store.put(sampleProfile(rules: 1), originDevice: "dev-a")
        let v2 = try store.put(sampleProfile(rules: 2), originDevice: "dev-a")
        try store.setPointer(version: v2.id, device: "dev-a", atMs: 300)
        XCTAssertEqual(store.effectiveActiveVersion(), v2.id)
        try store.setOverride(v1.id)
        XCTAssertEqual(store.effectiveActiveVersion(), v1.id)
        try store.setOverride(nil)
        XCTAssertEqual(store.effectiveActiveVersion(), v2.id)
    }

    func testTwoStoresConvergeOnNewestPointer() throws {
        let rootA = tempRoot(), rootB = tempRoot()
        defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }
        let a = ProfileVersionStore(root: rootA)
        let b = ProfileVersionStore(root: rootB)
        let v1 = try a.put(sampleProfile(rules: 1), originDevice: "dev-a")
        let v2 = try a.put(sampleProfile(rules: 2), originDevice: "dev-a")
        XCTAssertTrue(try a.setPointer(version: v2.id, device: "dev-a", atMs: 500))
        // B receives the content and A's newer pointer.
        _ = try b.ingest(content: try a.data(id: v2.id), meta: a.meta(id: v2.id)!)
        b.merge(pointers: ["dev-a": ActivePointer(version: v2.id, updatedAtMs: 500, updatedBy: "dev-a")])
        XCTAssertEqual(b.effectiveActiveVersion(), v2.id)
        XCTAssertEqual(a.effectiveActiveVersion(), v2.id)
        XCTAssertNotEqual(v1.id, v2.id)
    }

    func testMissingReportsOnlyAbsentVersions() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileVersionStore(root: root)
        let v1 = try store.put(sampleProfile(rules: 1), originDevice: "dev-a")
        let v2 = try store.put(sampleProfile(rules: 2), originDevice: "dev-a")
        let remote = [v1, v2, ProfileVersion(id: String(repeating: "f", count: 64), name: "x",
                                            ruleCount: 0, bytes: 0, createdAtMs: 9, originDevice: "b")]
        XCTAssertEqual(store.missing(from: remote).map(\.id),
                       [String(repeating: "f", count: 64)])
    }
}

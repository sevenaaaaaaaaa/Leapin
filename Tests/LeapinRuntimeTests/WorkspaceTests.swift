import XCTest
import LeapinCore
@testable import LeapinRuntime

final class WorkspaceTests: XCTestCase {
    @MainActor
    func testPreparingMixedProtocolsDoesNotWriteOrActivateProfiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root)
        let previous = store.activeProfile()
        let count = store.list().count
        let source = """
        proxies:
          - name: Remote
            type: vless
            server: 192.0.2.1
            port: 443
            uuid: 11111111-1111-4111-8111-111111111111
        rules:
          - MATCH,Remote
        """
        let preview = try ImportPreparation(text: source, name: "Mixed")
        XCTAssertEqual(preview.clashSource, source)
        XCTAssertTrue(preview.preservesClashSource)
        XCTAssertEqual(preview.nativeBlockers.count, 1)
        XCTAssertEqual(store.list().count, count)
        XCTAssertEqual(store.activeProfileID, previous.id)
    }

    @MainActor
    func testNativeRejectsUnsupportedTransportBeforeChangingState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root)
        let engine = LeapinEngine(store: store)
        let before = engine.profile
        let preview = try ImportPreparation(text: """
        proxies:
          - name: Node
            type: trojan
            server: 192.0.2.1
            port: 443
            password: example
            network: ws
        rules:
          - MATCH,Node
        """, name: "Unsupported transport")
        do { try await engine.commitImport(preview, kernel: .native); XCTFail("must reject") }
        catch { XCTAssertEqual(engine.profile, before) }
        XCTAssertEqual(store.activeProfileID, before.id)
        XCTAssertEqual(engine.state, .stopped)
    }

    @MainActor
    func testLossySurgeConversionCannotBeSilentlyActivatedByExternalKernel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LeapinEngine(store: ProfileStore(root: root))
        let before = engine.profile
        let preview = try ImportPreparation(text: """
        [General]
        loglevel = notify
        [Script]
        test = type=http-response, pattern=example, script-path=example.js
        [Rule]
        FINAL,DIRECT
        """, name: "Unsupported script")
        XCTAssertFalse(preview.externalConversionBlockers.isEmpty)
        do { try await engine.commitImport(preview, kernel: .mihomo); XCTFail("must reject lossy conversion") }
        catch { XCTAssertEqual(engine.profile, before) }
        XCTAssertEqual(engine.state, .stopped)
    }

    @MainActor
    func testSceneBindingsAndBookmarksSurviveRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let scenes = NetworkScenes(root: root)
        try scenes.bind(.agent, to: id)
        try scenes.markActive(.agent)
        XCTAssertEqual(NetworkScenes(root: root).profileID(for: .agent), id)
        XCTAssertEqual(NetworkScenes(root: root).active, .agent)
        let bookmarks = NetworkBookmarks(root: root)
        try bookmarks.add(title: "Website", address: "https://example.com/path?item=1")
        try bookmarks.add(title: "Duplicate", address: "https://example.com/path?item=1")
        XCTAssertEqual(NetworkBookmarks(root: root).items.count, 1)
        XCTAssertEqual(bookmarks.items.first?.url.query, "item=1")
        XCTAssertThrowsError(try bookmarks.add(title: "Invalid", address: "https://name:secret@example.com"))
        try bookmarks.remove(bookmarks.items[0].id)
        XCTAssertTrue(NetworkBookmarks(root: root).items.isEmpty)
    }

    func testKernelSourcePersistsRawSourceWithPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root)
        let profile = Profile(name: "Private profile")
        _ = try store.save(profile)
        let profileMode = try FileManager.default.attributesOfItem(atPath: store.profileURL(profile.id).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(profileMode?.intValue, 0o600)
        let id = UUID()
        try store.saveKernelSource(KernelSource(kernel: .mihomo, clash: "proxies: []\nrules: [MATCH,DIRECT]"), for: id)
        XCTAssertEqual(try store.kernelSource(for: id)?.kernel, .mihomo)
        let file = root.appendingPathComponent("kernel-sources/\(id.uuidString).json")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        try store.saveKernelSource(nil, for: id)
        XCTAssertNil(try store.kernelSource(for: id))
    }
}

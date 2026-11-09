import XCTest
import Foundation
@testable import LeapinRuntime
import LeapinCore
import LeapinSync

/// The v1.8 rename must never lose an existing install: the old
/// `Application Support/TouchFlow` tree is copied once into `Leapin`, and a
/// previously seeded ad list wins over the bundled starter list.
final class ProfileMigrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("leapin-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testMigrationCopiesLegacyTreeOnceAndIsIdempotent() throws {
        let legacy = root.appendingPathComponent("TouchFlow", isDirectory: true)
        try write("active", to: legacy.appendingPathComponent("active.json"))
        try write("profile", to: legacy.appendingPathComponent("profiles/p.json"))
        try write("{}", to: legacy.appendingPathComponent("sync/pointers/d1.json"))

        let newRoot = root.appendingPathComponent("Leapin", isDirectory: true)
        ProfileStore.migrateLegacyDataIfNeeded(to: newRoot)

        XCTAssertEqual(try String(contentsOf: newRoot.appendingPathComponent("active.json"), encoding: .utf8),
                       "active")
        XCTAssertEqual(try String(contentsOf: newRoot.appendingPathComponent("profiles/p.json"), encoding: .utf8),
                       "profile")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: newRoot.appendingPathComponent("sync/pointers/d1.json").path))

        // A later change in the legacy tree must not overwrite the migrated one.
        try write("changed", to: legacy.appendingPathComponent("active.json"))
        ProfileStore.migrateLegacyDataIfNeeded(to: newRoot)
        XCTAssertEqual(try String(contentsOf: newRoot.appendingPathComponent("active.json"), encoding: .utf8),
                       "active")
    }

    func testExistingLeapinTreeIsNeverOverwritten() throws {
        let newRoot = root.appendingPathComponent("Leapin", isDirectory: true)
        try write("keep", to: newRoot.appendingPathComponent("active.json"))
        let legacy = root.appendingPathComponent("TouchFlow", isDirectory: true)
        try write("legacy", to: legacy.appendingPathComponent("active.json"))

        ProfileStore.migrateLegacyDataIfNeeded(to: newRoot)
        XCTAssertEqual(try String(contentsOf: newRoot.appendingPathComponent("active.json"), encoding: .utf8),
                       "keep")
    }

    func testDeviceIdentityMigratesFromLegacyStore() throws {
        let legacy = MemorySecretStore()
        let previous = try DeviceIdentity.loadOrCreate(store: legacy)
        let current = MemorySecretStore()

        let migrated = try ProfileSyncService.loadOrMigrateIdentity(current: current, legacy: legacy)
        XCTAssertEqual(migrated.deviceID, previous.deviceID,
                       "a rename must not turn this Mac into a new device")
        XCTAssertEqual(try current.readSecret(), try legacy.readSecret(),
                       "the seed must be copied into the new store")

        let again = try ProfileSyncService.loadOrMigrateIdentity(current: current, legacy: legacy)
        XCTAssertEqual(again.deviceID, previous.deviceID, "migration must be idempotent")
    }

    func testBundledAdsListMigratesInsteadOfBeingReplaced() throws {
        try write("legacy-ads\n", to: root.appendingPathComponent("TouchFlow/lists/touchflow-ads.txt"))
        let store = ProfileStore(root: root.appendingPathComponent("Leapin", isDirectory: true))
        _ = store.ensureBundledLists()
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("Leapin/lists/leapin-ads.txt"), encoding: .utf8),
            "legacy-ads\n")
    }
}
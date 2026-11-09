import Foundation
import LeapinCore
import LeapinSync

/// Glue between the mutable ProfileStore the app reads and the immutable,
/// content-addressed version history used for device sync.
public final class ProfileSyncService: @unchecked Sendable {
    public static let shared = ProfileSyncService()

    public let root: URL
    public let versions: ProfileVersionStore
    public let peers: PeerRegistry
    public let profileStore: ProfileStore
    private let lock = NSLock()
    private let explicitSecretStore: SecretStore?
    private var cachedIdentity: DeviceIdentity?

    public init(root: URL? = nil, profileStore: ProfileStore? = nil,
                secretStore: SecretStore? = nil) {
        let base = root ?? profileStore?.root ?? ProfileStore.shared.root
        self.root = base
        self.versions = ProfileVersionStore(root: base.appendingPathComponent("sync", isDirectory: true))
        self.peers = PeerRegistry(root: base.appendingPathComponent("sync/peers", isDirectory: true))
        self.profileStore = profileStore ?? ProfileStore.shared
        self.explicitSecretStore = secretStore
    }

    // MARK: Identity

    /// The app stores the seed in the login Keychain. Unsigned CLI runs and CI
    /// may not be able to create a keychain item, so the fallback is a 0600
    /// file under the profile root (same directory the control token uses).
    public func identity() throws -> DeviceIdentity {
        if let cachedIdentity { return cachedIdentity }
        return try lock.withLock {
            if let cachedIdentity { return cachedIdentity }
            let identity: DeviceIdentity
            if let explicitSecretStore {
                identity = try DeviceIdentity.loadOrCreate(store: explicitSecretStore)
            } else {
                let keychain = KeychainSecretStore()
                do {
                    identity = try Self.loadOrMigrateIdentity(
                        current: keychain,
                        legacy: KeychainSecretStore(service: "com.touchflow.device"))
                } catch {
                    LPLog.shared.info("sync", "keychain unavailable, using 0600 file key: " + String(describing: error))
                    let fileStore = FileSecretStore(
                        directory: root.appendingPathComponent("device", isDirectory: true))
                    identity = try DeviceIdentity.loadOrCreate(store: fileStore)
                }
            }
            cachedIdentity = identity
            return identity
        }
    }

    /// Loads the device key, migrating the pre-rename TouchFlow keychain item
    /// once. Kept separate from Keychain types so it is testable with the
    /// in-memory stores.
    static func loadOrMigrateIdentity(current: SecretStore,
                                      legacy: SecretStore) throws -> DeviceIdentity {
        if let existing = try DeviceIdentity.load(store: current) { return existing }
        if let seed = try legacy.readSecret(), !seed.isEmpty {
            try current.writeSecret(seed)
            LPLog.shared.info("sync", "migrated device identity from TouchFlow keychain")
            return try DeviceIdentity(rawPrivateKey: seed)
        }
        return try DeviceIdentity.loadOrCreate(store: current)
    }

    public var deviceName: String {
        get {
            if let text = try? String(contentsOf: root.appendingPathComponent("device-name"),
                                      encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        }
        set {
            try? newValue.write(to: root.appendingPathComponent("device-name"),
                                atomically: true, encoding: .utf8)
        }
    }

    public func syncDevice() throws -> SyncDevice {
        SyncDevice(identity: try identity(), name: deviceName)
    }

    // MARK: Versions

    /// Seeds the history from the currently active profile on first use and
    /// records a new version whenever the engine saves a change.
    @discardableResult
    public func recordActiveProfile(now: Date = Date()) throws -> ProfileVersion {
        let identity = try identity()
        let profile = profileStore.activeProfile()
        let parent = versions.pointers().values.max(by: { !$0.isNewer(than: $1) })?.version
        let version = try versions.put(profile, originDevice: identity.deviceID,
                                       parent: parent, now: now)
        try versions.setPointer(version: version.id, device: identity.deviceID,
                                atMs: Int64(now.timeIntervalSince1970 * 1000))
        return version
    }

    /// Creates the first version from the pre-P2 profiles/ directory if the
    /// history is still empty. Idempotent.
    @discardableResult
    public func migrateIfNeeded() throws -> ProfileVersion? {
        guard versions.list().isEmpty else { return nil }
        return try recordActiveProfile()
    }

    /// Loads the effective active version into ProfileStore under a stable,
    /// content-derived UUID and makes it the active profile.
    @discardableResult
    public func applyActiveVersion() throws -> Profile? {
        guard let id = versions.effectiveActiveVersion() else { return nil }
        return try apply(versionID: id)
    }

    @discardableResult
    public func apply(versionID: String) throws -> Profile {
        var profile = try versions.profile(id: versionID)
        let uuid = Self.stableUUID(from: versionID)
        profile.id = uuid
        _ = try profileStore.save(profile)
        profileStore.activeProfileID = uuid
        try? versionID.write(to: root.appendingPathComponent("sync/applied-version"),
                             atomically: true, encoding: .utf8)
        return profile
    }

    public var appliedVersion: String? {
        guard let text = try? String(contentsOf: root.appendingPathComponent("sync/applied-version"),
                                     encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Deterministic UUID so projection is idempotent; version ids are 64 hex
    /// characters, which is exactly enough for a UUID's 32 hex digits.
    public static func stableUUID(from versionID: String) -> UUID {
        let hex = versionID.count >= 32
            ? String(versionID.prefix(32))
            : versionID.padding(toLength: 32, withPad: "0", startingAt: 0)
        let parts = [
            String(hex.prefix(8)),
            String(hex.dropFirst(8).prefix(4)),
            String(hex.dropFirst(12).prefix(4)),
            String(hex.dropFirst(16).prefix(4)),
            String(hex.dropFirst(20).prefix(12)),
        ]
        return UUID(uuidString: parts.joined(separator: "-")) ?? UUID()
    }
}
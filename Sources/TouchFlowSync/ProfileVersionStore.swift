import Foundation
import CryptoKit
import TouchFlowCore

// MARK: - Canonical profile content

/// The part of a profile that defines a *version*. The profile's local UUID,
/// its source path and its on-disk name are deliberately excluded so that the
/// same subscription imported on two devices hashes to the same version id.
public struct ProfileContent: Codable, Hashable, Sendable {
    public var name: String
    public var general: GeneralConfig
    public var dns: DNSConfig
    public var adblock: AdBlockConfig
    public var outbounds: [OutboundConfig]
    public var groups: [PolicyGroup]
    public var rules: [Rule]
    public var ruleProviders: [RuleProvider]
    public var proxyProviders: [RuleProvider]

    public init(_ profile: Profile) {
        self.name = profile.name
        self.general = profile.general
        self.dns = profile.dns
        self.adblock = profile.adblock
        self.outbounds = profile.outbounds
        self.groups = profile.groups
        self.rules = profile.rules
        self.ruleProviders = profile.ruleProviders
        self.proxyProviders = profile.proxyProviders
    }

    public func makeProfile(id: UUID = UUID(), sourcePath: String? = nil) -> Profile {
        Profile(id: id, name: name, general: general, dns: dns, adblock: adblock,
                outbounds: outbounds, groups: groups, rules: rules,
                sourcePath: sourcePath, ruleProviders: ruleProviders,
                proxyProviders: proxyProviders)
    }
}

public enum ProfileCanonical {
    /// Deterministic JSON: sorted keys, no whitespace, ISO-8601 dates.
    public static func encode(_ content: ProfileContent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(content)
    }

    public static func versionID(for data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    public static func decode(_ data: Data) throws -> ProfileContent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProfileContent.self, from: data)
    }
}

// MARK: - Version records

public struct ProfileVersion: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var ruleCount: Int
    public var bytes: Int
    public var createdAtMs: Int64
    public var originDevice: String
    public var parent: String?

    public init(id: String, name: String, ruleCount: Int, bytes: Int,
                createdAtMs: Int64, originDevice: String, parent: String? = nil) {
        self.id = id
        self.name = name
        self.ruleCount = ruleCount
        self.bytes = bytes
        self.createdAtMs = createdAtMs
        self.originDevice = originDevice
        self.parent = parent
    }
}

/// Last-writer-wins pointer to a version. The timestamp is compared first,
/// the device id only breaks exact ties so two devices converge deterministically.
public struct ActivePointer: Codable, Sendable, Hashable {
    public var version: String
    public var updatedAtMs: Int64
    public var updatedBy: String

    public init(version: String, updatedAtMs: Int64, updatedBy: String) {
        self.version = version
        self.updatedAtMs = updatedAtMs
        self.updatedBy = updatedBy
    }

    public func isNewer(than other: ActivePointer) -> Bool {
        if updatedAtMs != other.updatedAtMs { return updatedAtMs > other.updatedAtMs }
        return updatedBy > other.updatedBy
    }
}

public enum VersionStoreError: Error, LocalizedError {
    case badVersionID(String)
    case corruptVersion(String)
    case unknownVersion(String)

    public var errorDescription: String? {
        switch self {
        case .badVersionID(let id): return "版本 id 非法：\(id)"
        case .corruptVersion(let id): return "版本内容与 id 不符：\(id)"
        case .unknownVersion(let id): return "本地没有版本：\(id)"
        }
    }
}

// MARK: - Store

/// Append-only, content-addressed profile history.
///
/// Layout under root:
///   versions/content/<sha256>.json   immutable canonical content
///   versions/meta/<sha256>.json      immutable metadata record
///   pointers/<deviceID>.json         last-writer-wins active pointer per device
///   override.json                    local explicit choice (never synced)
public final class ProfileVersionStore: @unchecked Sendable {
    public let root: URL
    private let contentDirectory: URL
    private let metaDirectory: URL
    private let pointersDirectory: URL
    private let lock = NSLock()
    private let fm = FileManager.default

    public init(root: URL) {
        self.root = root
        self.contentDirectory = root.appendingPathComponent("versions/content", isDirectory: true)
        self.metaDirectory = root.appendingPathComponent("versions/meta", isDirectory: true)
        self.pointersDirectory = root.appendingPathComponent("pointers", isDirectory: true)
        for dir in [root, contentDirectory, metaDirectory, pointersDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
    }

    private var overrideURL: URL { root.appendingPathComponent("override.json") }

    // MARK: Write

    /// Stores a profile as a new immutable version. Returns the existing record
    /// when the content hash is already present (idempotent, never overwrites).
    @discardableResult
    public func put(_ profile: Profile, originDevice: String,
                    parent: String? = nil, now: Date = Date()) throws -> ProfileVersion {
        let content = ProfileContent(profile)
        let data = try ProfileCanonical.encode(content)
        let id = ProfileCanonical.versionID(for: data)
        let meta = ProfileVersion(
            id: id, name: profile.name, ruleCount: profile.rules.count,
            bytes: data.count, createdAtMs: Int64(now.timeIntervalSince1970 * 1000),
            originDevice: originDevice, parent: parent)
        return try ingest(content: data, meta: meta)
    }

    /// Imports a version received from a peer. The content hash must match the
    /// advertised id, otherwise the payload is rejected (no partial writes).
    @discardableResult
    public func ingest(content: Data, meta: ProfileVersion) throws -> ProfileVersion {
        let actual = ProfileCanonical.versionID(for: content)
        guard actual == meta.id else { throw VersionStoreError.corruptVersion(meta.id) }
        _ = try ProfileCanonical.decode(content)
        return try lock.withLock {
            try writeIfAbsent(content, to: contentURL(meta.id))
            if let existing = readMeta(meta.id) { return existing }
            try writeIfAbsent(JSONEncoder.sync.encode(meta), to: metaURL(meta.id))
            return meta
        }
    }

    // MARK: Read

    public func data(id: String) throws -> Data {
        guard let data = try? Data(contentsOf: contentURL(id)) else {
            throw VersionStoreError.unknownVersion(id)
        }
        return data
    }

    public func profile(id: String) throws -> Profile {
        let content = try ProfileCanonical.decode(try data(id: id))
        return content.makeProfile()
    }

    public func meta(id: String) -> ProfileVersion? {
        lock.withLock { readMeta(id) }
    }

    public func list() -> [ProfileVersion] {
        lock.withLock {
            guard let files = try? fm.contentsOfDirectory(at: metaDirectory,
                                                          includingPropertiesForKeys: nil) else { return [] }
            return files.filter { $0.pathExtension == "json" }
                .compactMap { url in try? JSONDecoder.sync.decode(ProfileVersion.self, from: Data(contentsOf: url)) }
                .sorted { $0.createdAtMs > $1.createdAtMs }
        }
    }

    /// Version ids a peer has that this store lacks.
    public func missing(from remote: [ProfileVersion]) -> [ProfileVersion] {
        lock.withLock {
            remote.filter { readMeta($0.id) == nil }
        }
    }

    // MARK: Active pointer

    public func pointer(device: String) -> ActivePointer? {
        lock.withLock { readPointer(device) }
    }

    public func pointers() -> [String: ActivePointer] {
        lock.withLock {
            guard let files = try? fm.contentsOfDirectory(at: pointersDirectory,
                                                          includingPropertiesForKeys: nil) else { return [:] }
            var result: [String: ActivePointer] = [:]
            for url in files where url.pathExtension == "json" {
                if let p = try? JSONDecoder.sync.decode(ActivePointer.self, from: Data(contentsOf: url)) {
                    result[url.deletingPathExtension().lastPathComponent] = p
                }
            }
            return result
        }
    }

    /// Moves one device's pointer forward. Older timestamps are ignored so an
    /// out-of-order sync cannot rewind history. Returns whether it changed.
    @discardableResult
    public func setPointer(version: String, device: String, atMs: Int64) throws -> Bool {
        guard meta(id: version) != nil else { throw VersionStoreError.unknownVersion(version) }
        let candidate = ActivePointer(version: version, updatedAtMs: atMs, updatedBy: device)
        return try lock.withLock {
            if let existing = readPointer(device), !candidate.isNewer(than: existing) { return false }
            try writeIfAbsent(JSONEncoder.sync.encode(candidate), to: pointerURL(device), overwrite: true)
            return true
        }
    }

    /// Merges pointers received in a manifest; returns the ids that advanced.
    @discardableResult
    public func merge(pointers remote: [String: ActivePointer]) -> [String] {
        var changed: [String] = []
        for (device, pointer) in remote.sorted(by: { $0.key < $1.key }) {
            if meta(id: pointer.version) == nil { continue }
            if (try? setPointer(version: pointer.version, device: device, atMs: pointer.updatedAtMs)) == true {
                changed.append(device)
            }
        }
        return changed
    }

    // MARK: Local override

    public var overrideVersion: String? {
        lock.withLock {
            guard let data = try? Data(contentsOf: overrideURL),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = obj["version"] as? String else { return nil }
            return version
        }
    }

    /// Pins this device to a version. nil clears the pin (follow the newest
    /// pointer again). An override is local-only and never leaves the device.
    public func setOverride(_ version: String?) throws {
        guard let version else {
            lock.withLock { try? fm.removeItem(at: overrideURL) }
            return
        }
        // meta() takes the lock itself; check it before entering the critical
        // section or this becomes a self-deadlock with NSLock.
        guard meta(id: version) != nil else { throw VersionStoreError.unknownVersion(version) }
        let data = try JSONSerialization.data(withJSONObject: ["version": version], options: [.sortedKeys])
        try lock.withLock { try writeIfAbsent(data, to: overrideURL, overwrite: true) }
    }

    /// The version this device should run: explicit override, else the newest
    /// pointer across every known device. Returns nil before the first version.
    public func effectiveActiveVersion() -> String? {
        if let pinned = overrideVersion, meta(id: pinned) != nil { return pinned }
        let all = pointers().values
        guard var best = all.first else { return nil }
        for pointer in all where pointer.isNewer(than: best) { best = pointer }
        return meta(id: best.version) != nil ? best.version : nil
    }

    // MARK: Files

    private func contentURL(_ id: String) -> URL { contentDirectory.appendingPathComponent("\(id).json") }
    private func metaURL(_ id: String) -> URL { metaDirectory.appendingPathComponent("\(id).json") }
    private func pointerURL(_ device: String) -> URL { pointersDirectory.appendingPathComponent("\(device).json") }

    private func readMeta(_ id: String) -> ProfileVersion? {
        guard let data = try? Data(contentsOf: metaURL(id)) else { return nil }
        return try? JSONDecoder.sync.decode(ProfileVersion.self, from: data)
    }

    private func readPointer(_ device: String) -> ActivePointer? {
        guard let data = try? Data(contentsOf: pointerURL(device)) else { return nil }
        return try? JSONDecoder.sync.decode(ActivePointer.self, from: data)
    }

    private func writeIfAbsent(_ data: Data, to url: URL, overwrite: Bool = false) throws {
        if !overwrite && fm.fileExists(atPath: url.path) { return }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try data.write(to: tmp, options: .atomic)
        try? fm.removeItem(at: url)
        try fm.moveItem(at: tmp, to: url)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

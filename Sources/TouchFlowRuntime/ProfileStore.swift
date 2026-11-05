import Foundation
import TouchFlowCore
import TouchFlowPolicy

public struct ProfileMeta: Sendable, Identifiable, Hashable, Codable {
    public var id: UUID
    public var name: String
    public var updatedAt: Date
    public var ruleCount: Int
}

/// On-disk profile storage. JSON in Application Support; credentials never stored here.
public final class ProfileStore: @unchecked Sendable {
    public static let shared = ProfileStore()

    public let root: URL
    public let profilesDirectory: URL
    public let ruleSetsDirectory: URL
    public let cacheDirectory: URL
    private let lock = NSLock()
    private let fm = FileManager.default

    public init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TouchFlow", isDirectory: true)
        self.root = base
        self.profilesDirectory = base.appendingPathComponent("profiles", isDirectory: true)
        self.ruleSetsDirectory = base.appendingPathComponent("rule-sets", isDirectory: true)
        self.cacheDirectory = base.appendingPathComponent("cache", isDirectory: true)
        for dir in [base, profilesDirectory, ruleSetsDirectory, cacheDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public func profileURL(_ id: UUID) -> URL {
        profilesDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private var activeURL: URL { root.appendingPathComponent("active.json") }

    public func list() -> [ProfileMeta] {
        lock.withLock {
            guard let files = try? fm.contentsOfDirectory(at: profilesDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
            return files.filter { $0.pathExtension == "json" }.compactMap { url -> ProfileMeta? in
                guard let data = try? Data(contentsOf: url),
                      let profile = try? JSONDecoder.touchflow.decode(Profile.self, from: data) else { return nil }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                return ProfileMeta(id: profile.id, name: profile.name, updatedAt: date, ruleCount: profile.rules.count)
            }.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    @discardableResult
    public func save(_ profile: Profile) throws -> Profile {
        var p = profile
        let data = try JSONEncoder.touchflow.encode(p)
        try data.write(to: profileURL(p.id), options: .atomic)
        TFLog.shared.info("profile", "saved \(p.name) (\(p.rules.count) rules)")
        return p
    }

    public func load(id: UUID) throws -> Profile {
        let data = try Data(contentsOf: profileURL(id))
        var profile = try JSONDecoder.touchflow.decode(Profile.self, from: data)
        // 5353 is held by mDNSResponder on macOS; migrate profiles saved by older builds.
        if profile.dns.listenPort == 5353 { profile.dns.listenPort = 5354 }
        return profile
    }

    public func delete(id: UUID) {
        try? fm.removeItem(at: profileURL(id))
        if activeProfileID == id { try? fm.removeItem(at: activeURL) }
    }

    public var activeProfileID: UUID? {
        get {
            guard let data = try? Data(contentsOf: activeURL),
                  let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let id = UUID(uuidString: raw) else { return nil }
            return id
        }
        set {
            if let newValue { try? newValue.uuidString.write(to: activeURL, atomically: true, encoding: .utf8) }
            else { try? fm.removeItem(at: activeURL) }
        }
    }

    /// Loads the active profile, seeding a sane default on first launch.
    public func activeProfile() -> Profile {
        if let id = activeProfileID, let p = try? load(id: id) { return p }
        if let first = list().first, let p = try? load(id: first.id) {
            activeProfileID = first.id
            return p
        }
        let p = ProfileDefaults.make()
        _ = try? save(p)
        activeProfileID = p.id
        return p
    }

    public func export(_ profile: Profile, format: ProfileFormat) throws -> String {
        switch format {
        case .clash: return ProfileExporter.clash(profile)
        case .surge: return ProfileExporter.surge(profile)
        case .json:
            return String(data: try JSONEncoder.touchflow.encode(profile), encoding: .utf8) ?? "{}"
        }
    }

    /// Detects Clash / Surge / TouchFlow JSON and imports into a new profile.
    public func importFile(at url: URL) throws -> Profile {
        let text = try String(contentsOf: url, encoding: .utf8)
        let profile: Profile
        if url.pathExtension.lowercased() == "json" {
            profile = try JSONDecoder.touchflow.decode(Profile.self, from: Data(text.utf8))
        } else if text.contains("[Rule]") || text.contains("[Proxy]") || text.contains("[General]") {
            profile = try ProfileImporter.surge(text, name: url.deletingPathExtension().lastPathComponent)
        } else {
            profile = try ProfileImporter.clash(text, name: url.deletingPathExtension().lastPathComponent)
        }
        try save(profile)
        return profile
    }

    /// Seeds the bundled starter blocklists into the app-support directory (idempotent).
    public func ensureBundledLists() -> URL {
        let dir = root.appendingPathComponent("lists", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("touchflow-ads.txt")

        if !fm.fileExists(atPath: target.path), let source = Self.bundledListURL(named: "touchflow-ads") {
            // Copy atomically so a half-written list never gets loaded.
            let tmp = dir.appendingPathComponent(".touchflow-ads.txt.tmp")
            if (try? fm.copyItem(at: source, to: tmp)) != nil {
                try? fm.removeItem(at: target)
                try? fm.moveItem(at: tmp, to: target)
            }
        }
        return dir
    }

    /// Finds a bundled resource regardless of how SwiftPM laid out `Resources/` in the bundle.
    static func bundledListURL(named name: String) -> URL? {
        var candidates: [URL] = []
        candidates.append(Bundle.module.bundleURL
            .appendingPathComponent("Resources/blocklists/\(name).txt"))
        candidates.append(Bundle.module.bundleURL
            .appendingPathComponent("Contents/Resources/Resources/blocklists/\(name).txt"))
        if let res = Bundle.module.resourceURL {
            candidates.append(res.appendingPathComponent("blocklists/\(name).txt"))
            candidates.append(res.appendingPathComponent("Resources/blocklists/\(name).txt"))
            if let found = FileManager.default.enumerator(at: res, includingPropertiesForKeys: nil)?
                .compactMap({ $0 as? URL })
                .first(where: { $0.lastPathComponent == "\(name).txt" }) {
                candidates.append(found)
            }
        }
        if let res = Bundle(for: ProfileStore.self).resourceURL {
            candidates.append(res.appendingPathComponent("Resources/blocklists/\(name).txt"))
            if let found = FileManager.default.enumerator(at: res, includingPropertiesForKeys: nil)?
                .compactMap({ $0 as? URL })
                .first(where: { $0.lastPathComponent == "\(name).txt" }) {
                candidates.append(found)
            }
        }
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }
}

public enum ProfileFormat: String, Sendable, CaseIterable {
    case clash = "Clash YAML"
    case surge = "Surge Conf"
    case json = "TouchFlow JSON"
}

extension JSONDecoder {
    public static var touchflow: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    public static var touchflow: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

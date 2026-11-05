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
        // TF_PROFILE_ROOT isolates integration tests (and lets a user run a
        // throwaway instance) without touching the real Application Support
        // directory that the app, its control token and its audit log live in.
        let override = ProcessInfo.processInfo.environment["TF_PROFILE_ROOT"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        let base = root ?? override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
        case .hosts: return ProfileExporter.hosts(profile)
        case .abp: return ProfileExporter.abp(profile)
        case .ruleSet: return ProfileExporter.ruleSet(profile)
        }
    }

    /// Detects Clash / Surge / TouchFlow JSON / base64 subscription and imports
    /// into a new profile, returning the diagnostics the UI should surface.
    public func importFileDetailed(at url: URL) throws -> ProfileImportOutcome {
        let data = try Data(contentsOf: url)
        // Decoding as UTF-8 never fails; the YAML/ABP parsers strip BOM themselves.
        let text = String(decoding: data, as: UTF8.self)
        let name = url.deletingPathExtension().lastPathComponent
        var outcome = try ProfileImporter.importText(text, name: name, pathExtension: url.pathExtension)
        outcome.profile.sourcePath = url.path
        _ = try save(outcome.profile)
        return outcome
    }

    /// Convenience wrapper for callers that only need the profile.
    public func importFile(at url: URL) throws -> Profile {
        try importFileDetailed(at: url).profile
    }

    /// Downloads a remote subscription (base64 list, URI list, or a full
    /// Clash/Surge profile) and imports it with the same diagnostics as files.
    /// Only http(s) is accepted so a pasted file path never reaches the network
    /// layer, and a 20s timeout keeps the UI from hanging on a dead host.
    public func importRemote(_ link: String, name: String? = nil) async throws -> ProfileImportOutcome {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            throw RemoteImportError.badLink(trimmed)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("TouchFlow/0.1 (+profile-import)", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RemoteImportError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RemoteImportError.httpStatus(http.statusCode)
        }
        // Subscriptions are frequently base64 without a declared charset; decoding
        // as UTF-8 first and falling back to Latin-1 avoids losing the whole body.
        guard var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw RemoteImportError.notText
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RemoteImportError.emptyBody }
        let resolvedName = name?.isEmpty == false ? name! : (url.host ?? "远程订阅")
        var outcome = try ProfileImporter.importText(text, name: resolvedName, pathExtension: nil)
        outcome.profile.sourcePath = url.absoluteString
        _ = try save(outcome.profile)
        return outcome
    }

    /// Imports pasted text (drag-drop, clipboard subscription link, tests).
    public func importText(_ text: String, name: String,
                           pathExtension: String? = nil) throws -> ProfileImportOutcome {
        let outcome = try ProfileImporter.importText(text, name: name, pathExtension: pathExtension)
        _ = try save(outcome.profile)
        return outcome
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

/// Failure modes of a remote subscription import, phrased for the UI.
public enum RemoteImportError: Error, LocalizedError, Equatable {
    case badLink(String)
    case httpStatus(Int)
    case notText
    case emptyBody
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .badLink(let text):
            return "链接无效：\(text.isEmpty ? "（空）" : text)，只支持 http/https 订阅地址"
        case .httpStatus(let code):
            return "服务器返回 \(code)，无法下载订阅"
        case .notText:
            return "订阅内容不是文本，可能是压缩包或需要登录"
        case .emptyBody:
            return "订阅内容为空"
        case .network(let message):
            return "下载失败：\(message)"
        }
    }
}

public enum ProfileFormat: String, Sendable, CaseIterable {
    case clash = "Clash YAML"
    case surge = "Surge Conf"
    case json = "TouchFlow JSON"
    /// `/etc/hosts` style blocklist (only exact REJECT domains can be expressed).
    case hosts = "Hosts 拦截表"
    /// Adblock Plus / uBlock Origin filter list.
    case abp = "ABP 过滤列表"
    /// Clash `behavior: classical` rule-set payload.
    case ruleSet = "Clash rule-set"

    /// Stable token used by the CLI and by import/export APIs
    /// (clash / surge / json / hosts / abp / ruleset).
    public var cliName: String {
        switch self {
        case .clash: return "clash"
        case .surge: return "surge"
        case .json: return "json"
        case .hosts: return "hosts"
        case .abp: return "abp"
        case .ruleSet: return "ruleset"
        }
    }

    /// File extension suggested when writing this format to disk.
    public var fileExtension: String {
        switch self {
        case .clash: return "yaml"
        case .surge: return "conf"
        case .json: return "json"
        case .hosts: return "txt"
        case .abp: return "txt"
        case .ruleSet: return "yaml"
        }
    }

    /// Formats that can be imported (network blocklists are export-only).
    public var canImport: Bool {
        switch self {
        case .clash, .surge, .json: return true
        case .hosts, .abp, .ruleSet: return false
        }
    }

    public init?(cliName: String) {
        switch cliName.lowercased() {
        case "clash", "yaml", "yml": self = .clash
        case "surge", "conf": self = .surge
        case "json": self = .json
        case "hosts": self = .hosts
        case "abp", "adblock", "ublock": self = .abp
        case "ruleset", "rule-set": self = .ruleSet
        default: return nil
        }
    }
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

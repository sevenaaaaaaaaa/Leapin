import Foundation
import LeapinCore

/// Loads Surge/Clash rule-set files from local paths or http(s) URLs, with an on-disk
/// cache under `cacheDirectory`. Network problems degrade to cached content, then to an
/// empty set — never a crash.
public enum RuleSetLoader {

    public static func load(sources: [String], cacheDirectory: URL) async -> [String: [Rule]] {
        var result: [String: [Rule]] = [:]
        for rawSource in sources {
            let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { continue }
            let keys = lookupKeys(for: source)
            do {
                let text = try await fetchText(source, cacheDirectory: cacheDirectory)
                let (rules, errors) = RuleParser.parseRules(text)
                if !errors.isEmpty {
                    let sample = errors.prefix(3).joined(separator: "; ")
                    LPLog.shared.warn("policy", "rule set \(source): skipped \(errors.count) line(s) — \(sample)")
                }
                for key in keys where result[key] == nil {
                    result[key] = rules
                }
                LPLog.shared.debug("policy", "rule set \(source): \(rules.count) rule(s)")
            } catch {
                LPLog.shared.warn("policy", "rule set \(source) unavailable (\(error.localizedDescription)) — using empty set")
                for key in keys where result[key] == nil {
                    result[key] = []
                }
            }
        }
        return result
    }

    /// Names a RULE-SET reference may use: the raw source, its last path component, its stem.
    static func lookupKeys(for source: String) -> [String] {
        var keys: [String] = []
        keys.append(source.lowercased())
        var tail = source
        if let scheme = tail.range(of: "://") { tail = String(tail[scheme.upperBound...]) }
        if let cut = tail.firstIndex(where: { $0 == "?" || $0 == "#" }) { tail = String(tail[..<cut]) }
        if let slash = tail.lastIndex(of: "/") { tail = String(tail[tail.index(after: slash)...]) }
        if !tail.isEmpty, tail.lowercased() != source.lowercased() { keys.append(tail.lowercased()) }
        let stem = (tail as NSString).deletingPathExtension
        if !stem.isEmpty, !keys.contains(stem.lowercased()) { keys.append(stem.lowercased()) }
        return keys
    }

    static func isRemote(_ source: String) -> Bool {
        let lowered = source.lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
    }

    static func cacheURL(for source: String, cacheDirectory: URL) -> URL {
        cacheDirectory.appendingPathComponent("rule-sets", isDirectory: true)
            .appendingPathComponent(stableHash(source) + ".txt")
    }

    static func fetchText(_ source: String, cacheDirectory: URL) async throws -> String {
        if isRemote(source) {
            let cacheFile = cacheURL(for: source, cacheDirectory: cacheDirectory)
            do {
                let text = try await download(source)
                try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? text.write(to: cacheFile, atomically: true, encoding: .utf8)
                return text
            } catch {
                if let cached = try? String(contentsOf: cacheFile, encoding: .utf8), !cached.isEmpty {
                    LPLog.shared.warn("policy", "network fetch failed for \(source) (\(error.localizedDescription)) — using cached copy")
                    return cached
                }
                throw error
            }
        }
        let path = (source as NSString).expandingTildeInPath
        let candidates = [path, FileManager.default.currentDirectoryPath + "/" + path]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return try String(contentsOfFile: candidate, encoding: .utf8)
        }
        throw LoaderError.notFound(source)
    }

    private static func download(_ source: String) async throws -> String {
        guard let url = URL(string: source) else { throw LoaderError.badURL(source) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Leapin/0.1 (+rule-set)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LoaderError.httpStatus(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw LoaderError.notUTF8(source)
        }
        return text
    }

    /// FNV-1a 64-bit — stable, dependency free cache-key material.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }
}

public enum LoaderError: Error, LocalizedError, Sendable {
    case notFound(String)
    case badURL(String)
    case httpStatus(Int)
    case notUTF8(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let s): return "rule set not found: \(s)"
        case .badURL(let s): return "invalid URL: \(s)"
        case .httpStatus(let code): return "HTTP \(code)"
        case .notUTF8(let s): return "not UTF-8 text: \(s)"
        }
    }
}

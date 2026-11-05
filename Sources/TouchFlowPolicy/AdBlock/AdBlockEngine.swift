import Foundation
import TouchFlowCore

/// Domain blocker backed by a reversed-label trie: a lookup costs O(labels) dictionary
/// hops, independent of how many filters are loaded. Exceptions always win.
public final class AdBlockEngine: DomainBlocking, @unchecked Sendable {

    private final class TrieNode {
        var children: [String: TrieNode] = [:]
        var blockSuffix: [FilterRule] = []
        var blockExact: [FilterRule] = []
        var allowSuffix: [FilterRule] = []
        var allowExact: [FilterRule] = []
    }

    private let root: TrieNode
    private let blockKeywords: [(pattern: String, rule: FilterRule)]
    private let allowKeywords: [(pattern: String, rule: FilterRule)]
    private let allowDomains: [String]
    private let cosmeticBlocks: [(domain: String, selectors: [String])]
    private let cosmeticExceptions: [(domain: String, selectors: [String])]
    private let totalRules: Int

    public init(blockRules: [FilterRule] = [], allowRules: [FilterRule] = [],
                cosmeticRules: [CosmeticRule] = [], allowList: [String] = []) {
        let trie = TrieNode()
        var blocks: [(String, FilterRule)] = []
        var allows: [(String, FilterRule)] = []

        func insert(_ rule: FilterRule, exception: Bool) {
            guard let domain = rule.domain, !domain.isEmpty else {
                if let keyword = AdBlockEngine.keyword(of: rule.raw) {
                    if exception { allows.append((keyword, rule)) } else { blocks.append((keyword, rule)) }
                }
                return
            }
            let labels = domain.split(separator: ".").map(String.init).reversed()
            var node = trie
            for label in labels {
                if let next = node.children[label] {
                    node = next
                } else {
                    let next = TrieNode()
                    node.children[label] = next
                    node = next
                }
            }
            if AdBlockEngine.isExactAnchored(rule) {
                if exception { node.allowExact.append(rule) } else { node.blockExact.append(rule) }
            } else {
                if exception { node.allowSuffix.append(rule) } else { node.blockSuffix.append(rule) }
            }
        }

        for rule in blockRules { insert(rule, exception: false) }
        for rule in allowRules { insert(rule, exception: true) }

        var blockMap: [(String, [String])] = []
        var exceptionMap: [(String, [String])] = []
        for rule in cosmeticRules {
            let key = rule.domain.isEmpty ? "*" : rule.domain
            if rule.isException {
                AdBlockEngine.appendSelector(rule.selector, for: key, into: &exceptionMap)
            } else {
                AdBlockEngine.appendSelector(rule.selector, for: key, into: &blockMap)
            }
        }

        self.root = trie
        self.blockKeywords = blocks
        self.allowKeywords = allows
        self.allowDomains = allowList.map(HostNormalizer.normalize).filter { !$0.isEmpty }
        self.cosmeticBlocks = blockMap
        self.cosmeticExceptions = exceptionMap
        self.totalRules = blockRules.count + allowRules.count + cosmeticRules.count + allowList.count
    }

    /// Loads ABP/hosts lists from disk. Unreadable files are logged and skipped, never fatal.
    public static func load(listPaths: [String], allowList: [String] = []) throws -> AdBlockEngine {
        var block: [FilterRule] = []
        var allow: [FilterRule] = []
        var cosmetic: [CosmeticRule] = []
        for path in listPaths {
            let expanded = (path as NSString).expandingTildeInPath
            let text: String
            do {
                text = try String(contentsOfFile: expanded, encoding: .utf8)
            } catch {
                let fallback = FileManager.default.currentDirectoryPath + "/" + expanded
                if let cached = try? String(contentsOfFile: fallback, encoding: .utf8) {
                    text = cached
                } else {
                    TFLog.shared.warn("adblock", "cannot read list \(path): \(error.localizedDescription) — skipped")
                    continue
                }
            }
            let parsed = FilterParser.parse(text)
            block.append(contentsOf: parsed.block)
            allow.append(contentsOf: parsed.allow)
            cosmetic.append(contentsOf: parsed.cosmetic)
        }
        return AdBlockEngine(blockRules: block, allowRules: allow,
                             cosmeticRules: cosmetic, allowList: allowList)
    }

    public var ruleCount: Int { totalRules }

    // MARK: - DomainBlocking

    public func verdict(for domain: String, thirdParty: Bool) -> BlockVerdict {
        blockVerdict(for: domain, thirdParty: thirdParty)
    }

    /// Convenience overload: first-party match, used by UI previews.
    public func verdict(for domain: String) -> BlockVerdict {
        blockVerdict(for: domain, thirdParty: false)
    }

    public func isBlocked(_ domain: String) -> Bool {
        blockVerdict(for: domain, thirdParty: false).blocked
    }

    public func cosmeticSelectors(for domain: String) -> [String] {
        let host = HostNormalizer.normalize(domain)
        guard !host.isEmpty else { return [] }
        var removed = Set<String>()
        for entry in cosmeticExceptions where AdBlockEngine.keyMatches(entry.domain, host: host) {
            removed.formUnion(entry.selectors)
        }
        var result: [String] = []
        var seen = Set<String>()
        for entry in cosmeticBlocks where AdBlockEngine.keyMatches(entry.domain, host: host) {
            for selector in entry.selectors
            where !removed.contains(selector) && !seen.contains(selector) {
                seen.insert(selector)
                result.append(selector)
            }
        }
        return result
    }

    // MARK: - Core matching

    private func blockVerdict(for domain: String, thirdParty: Bool) -> BlockVerdict {
        let host = HostNormalizer.normalize(domain)
        guard !host.isEmpty else { return .allow }

        for allowed in allowDomains where HostNormalizer.matchesSuffix(host, allowed) {
            return BlockVerdict(blocked: false, reason: "allow-list: \(allowed)", cosmeticSelectors: [])
        }

        var allowHits: [FilterRule] = []
        var blockHits: [FilterRule] = []

        let labels = host.split(separator: ".").map(String.init)
        let total = labels.count
        var node: TrieNode? = root
        var matchedAllowExact = false
        var matchedBlockExact = false

        var consumed = 0
        for index in stride(from: total - 1, through: 0, by: -1) {
            guard let current = node, let next = current.children[labels[index]] else {
                node = nil
                break
            }
            consumed += 1
            node = next
            for rule in next.allowSuffix where !rule.thirdPartyOnly || thirdParty {
                allowHits.append(rule)
            }
            for rule in next.blockSuffix where !rule.thirdPartyOnly || thirdParty {
                blockHits.append(rule)
            }
            if consumed == total {
                for rule in next.allowExact where !rule.thirdPartyOnly || thirdParty {
                    allowHits.append(rule)
                    matchedAllowExact = true
                }
                for rule in next.blockExact where !rule.thirdPartyOnly || thirdParty {
                    blockHits.append(rule)
                    matchedBlockExact = true
                }
            }
        }
        _ = matchedAllowExact
        _ = matchedBlockExact

        for (pattern, rule) in allowKeywords where host.contains(pattern) {
            allowHits.append(rule)
        }
        for (pattern, rule) in blockKeywords where host.contains(pattern) {
            blockHits.append(rule)
        }

        if let exception = allowHits.first {
            return BlockVerdict(blocked: false, reason: exception.raw, cosmeticSelectors: [])
        }
        if let blocker = blockHits.first {
            return BlockVerdict(blocked: true, reason: blocker.raw,
                                cosmeticSelectors: cosmeticSelectors(for: host))
        }
        return .allow
    }

    // MARK: - Helpers

    static func isExactAnchored(_ rule: FilterRule) -> Bool {
        var raw = rule.raw
        if raw.hasPrefix("@@") { raw = String(raw.dropFirst(2)) }
        return raw.hasPrefix("|http://") || raw.hasPrefix("|https://")
    }

    static func keyword(of raw: String) -> String? {
        var body = raw
        if body.hasPrefix("@@") { body = String(body.dropFirst(2)) }
        if let dollar = body.lastIndex(of: "$") { body = String(body[..<dollar]) }
        body = body.replacingOccurrences(of: "||", with: "")
        body = body.replacingOccurrences(of: "|", with: "")
        body = body.replacingOccurrences(of: "^", with: "")
        body = body.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        guard body.count >= 3 else { return nil }
        return body.lowercased()
    }

    static func keyMatches(_ key: String, host: String) -> Bool {
        if key == "*" { return true }
        return HostNormalizer.matchesSuffix(host, key)
    }

    static func appendSelector(_ selector: String, for domain: String, into list: inout [(String, [String])]) {
        if let index = list.firstIndex(where: { $0.0 == domain }) {
            if !list[index].1.contains(selector) { list[index].1.append(selector) }
        } else {
            list.append((domain, [selector]))
        }
    }
}

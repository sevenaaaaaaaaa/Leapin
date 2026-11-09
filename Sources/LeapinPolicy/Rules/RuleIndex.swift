import Foundation
import LeapinCore

// MARK: - Prepared rules

/// A compiled regular expression that is safe to share across threads.
internal struct RegexBox: @unchecked Sendable { let regex: NSRegularExpression }

/// One rule flattened into everything the matcher and the index need.
/// The index field is the rule's position inside the list it belongs to (profile
/// rules, or one rule-set's members); operands of and/or/not use -1.
internal struct RulePrepared: Sendable {
    let rule: Rule
    let index: Int
    /// Normalized payload: lowercased domain, canonical CIDR text, uppercased geo code.
    let value: String
    let cidr: CIDR?
    let regex: RegexBox?
    let operands: [RulePrepared]

    static func make(_ rule: Rule, index: Int) -> RulePrepared {
        var value = rule.value
        var cidr: CIDR?
        var regex: RegexBox?
        var operands: [RulePrepared] = []

        switch rule.kind {
        case .domain, .domainSuffix, .domainKeyword:
            value = HostNormalizer.normalize(value)
        case .geoIP:
            value = value.uppercased()
        case .ipCIDR, .ipCIDR6, .srcIPCIDR:
            cidr = CIDR(value)
            if let parsed = cidr { value = parsed.description }
        case .domainRegex:
            if let compiled = try? NSRegularExpression(pattern: value) {
                regex = RegexBox(regex: compiled)
            }
        case .and, .or, .not:
            if let parsed = try? RuleParser.parseOperands(value) {
                operands = parsed.map { RulePrepared.make($0, index: -1) }
            }
        default:
            break
        }
        return RulePrepared(rule: rule, index: index, value: value, cidr: cidr,
                            regex: regex, operands: operands)
    }
}

// MARK: - Rule index

/// Pre-computed matcher index used by the RuleEngine hot path.
///
/// candidates(for:) returns an ascending, duplicate-free list of rule positions
/// that is guaranteed to be a superset of every rule that can match the given
/// ConnectionMeta. Evaluating those positions in order therefore produces
/// exactly the same first-match result as the original linear scan, while only
/// touching rules whose matcher family can possibly fire.
///
/// Indexed matchers:
/// - DOMAIN            -> hash table keyed by normalized host
/// - DOMAIN-SUFFIX     -> reverse-label trie (a.example.com walks com, example, a)
/// - DOMAIN-KEYWORD    -> Aho-Corasick over UTF-8 bytes
/// - IP-CIDR / IP-CIDR6 -> bitwise prefix tries for IPv4 (/0.../32) and IPv6 (/0.../128)
/// - SRC-IP-CIDR       -> the same two tries, fed by sourceIP
/// - PROCESS-NAME      -> lowercase dictionary
/// - RULE-SET          -> bucket by set key, members matched through a nested index
///
/// Everything whose match set cannot be narrowed cheaply (AND/OR/NOT, GEOIP,
/// DOMAIN-REGEX, MATCH, and every negated rule) lands in alwaysCheck and is
/// always a candidate.
public struct RuleIndex: Sendable {
    // MARK: Domain suffix trie

    private struct SuffixEdge: Hashable {
        let node: Int32
        let label: String
    }

    private var suffixEdges: [SuffixEdge: Int32] = [:]
    private var suffixRuleHead: [Int32] = [-1]
    private var suffixRuleNext: [Int32] = []
    private var suffixRuleValue: [Int32] = []

    // MARK: Dictionaries

    private var exactDomain: [String: [Int32]] = [:]
    private var processNames: [String: [Int32]] = [:]
    private var setBuckets: [String: [Int32]] = [:]

    // MARK: Keyword Aho-Corasick (byte alphabet)

    private var acNext: [Int64: Int32] = [:]
    private var acFail: [Int32] = [0]
    private var acOutHead: [Int32] = [-1]
    private var acOutLink: [Int32] = [-1]
    private var acOutNext: [Int32] = []
    private var acOutValue: [Int32] = []
    // Build-only adjacency (cleared once the failure links exist).
    private var acFirstChild: [Int32] = [-1]
    private var acChildNext: [Int32] = []
    private var acChildByte: [UInt8] = []
    private var acChildNode: [Int32] = []

    // MARK: IP prefix tries

    private var v4Child: [Int32] = [-1, -1]
    private var v4Head: [Int32] = [-1]
    private var v6Child: [Int32] = [-1, -1]
    private var v6Head: [Int32] = [-1]
    private var srcV4Child: [Int32] = [-1, -1]
    private var srcV4Head: [Int32] = [-1]
    private var srcV6Child: [Int32] = [-1, -1]
    private var srcV6Head: [Int32] = [-1]
    private var ipRuleNext: [Int32] = []
    private var ipRuleValue: [Int32] = []

    // MARK: Everything else

    private var alwaysCheck: [Int32] = []
    /// Member matchers for loaded rule-sets, keyed by lowercased set name.
    private var memberIndex: [String: RuleIndex] = [:]

    /// Number of rules this index was built from.
    public let ruleCount: Int

    // MARK: Init

    /// Builds a standalone index. Rules that reference rule-sets are treated as
    /// always-check candidates because the set contents are unknown here; use the
    /// engine (which knows its loaded sets) for exact two-level matching.
    public init(rules: [Rule]) {
        self.init(prepared: rules.enumerated().map { RulePrepared.make($0.element, index: $0.offset) })
    }

    internal init(prepared rules: [RulePrepared],
                  ruleSetMembers: [String: RuleIndex] = [:]) {
        self.ruleCount = rules.count
        self.memberIndex = ruleSetMembers
        self.build(rules)
    }

    // MARK: Candidate query

    /// Ascending, duplicate-free positions of every rule that could match meta.
    public func candidates(for meta: ConnectionMeta) -> [Int] {
        candidates(for: meta, host: HostNormalizer.normalize(meta.host))
    }

    internal func candidates(for meta: ConnectionMeta, host: String) -> [Int] {
        guard ruleCount > 0 else { return [] }
        // An empty host can only reach a handful of pathological rules (empty
        // DOMAIN values, raw IPs in the host field, process/geo matchers). Rather
        // than reason about it, hand back everything: correctness first, and real
        // traffic never lands here.
        guard !host.isEmpty else { return Array(0..<ruleCount) }
        var out: [Int] = []
        out.reserveCapacity(32)
        collect(meta: meta, host: host, into: &out)
        return RuleIndex.sortedUnique(out)
    }

    internal func memberRuleIndex(for key: String) -> RuleIndex? { memberIndex[key] }

    // MARK: Collection

    internal func collect(meta: ConnectionMeta, host: String, into out: inout [Int]) {
        for value in alwaysCheck { out.append(Int(value)) }

        if let list = exactDomain[host] {
            for value in list { out.append(Int(value)) }
        }

        collectSuffixes(host, into: &out)
        collectKeywords(host, into: &out)

        if let raw = meta.destinationIP, !raw.isEmpty {
            if let v4 = IPParse.ipv4(raw) {
                collectIPv4(v4, source: false, into: &out)
            } else if let v6 = IPParse.ipv6(raw) {
                collectIPv6(v6, source: false, into: &out)
            }
        }
        if let raw = meta.sourceIP, !raw.isEmpty {
            if let v4 = IPParse.ipv4(raw) {
                collectIPv4(v4, source: true, into: &out)
            } else if let v6 = IPParse.ipv6(raw) {
                collectIPv6(v6, source: true, into: &out)
            }
        }

        collectProcessNames(meta, into: &out)

        if !setBuckets.isEmpty {
            for (key, outerRules) in setBuckets {
                // A rule-set rule can only fire when at least one member can.
                guard let member = memberIndex[key] else { continue }
                var scratch: [Int] = []
                member.collect(meta: meta, host: host, into: &scratch)
                if !scratch.isEmpty {
                    for value in outerRules { out.append(Int(value)) }
                }
            }
        }
    }

    private func collectSuffixes(_ host: String, into out: inout [Int]) {
        var node: Int32 = 0
        appendRuleList(suffixRuleHead[0], head: suffixRuleHead, next: suffixRuleNext,
                       values: suffixRuleValue, into: &out)
        for label in host.split(separator: ".", omittingEmptySubsequences: false).reversed() {
            guard let next = suffixEdges[SuffixEdge(node: node, label: String(label))] else { break }
            node = next
            appendRuleList(suffixRuleHead[Int(node)], head: suffixRuleHead, next: suffixRuleNext,
                           values: suffixRuleValue, into: &out)
        }
    }

    private func collectKeywords(_ host: String, into out: inout [Int]) {
        guard !acOutValue.isEmpty else { return }
        var state: Int32 = 0
        for byte in host.utf8 {
            while true {
                let key = (Int64(state) << 8) | Int64(byte)
                if let next = acNext[key] { state = next; break }
                if state == 0 { break }
                state = acFail[Int(state)]
            }
            var node = state
            while node >= 0 {
                var entry = acOutHead[Int(node)]
                while entry >= 0 {
                    out.append(Int(acOutValue[Int(entry)]))
                    entry = acOutNext[Int(entry)]
                }
                node = acOutLink[Int(node)]
            }
        }
    }

    private func collectIPv4(_ value: UInt32, source: Bool, into out: inout [Int]) {
        let child = source ? srcV4Child : v4Child
        let head = source ? srcV4Head : v4Head
        var node: Int32 = 0
        appendRuleList(head[0], head: head, next: ipRuleNext, values: ipRuleValue, into: &out)
        var bit = 31
        while bit >= 0 {
            let slot = Int(node) * 2 + Int((value >> UInt32(bit)) & 1)
            let next = child[slot]
            if next < 0 { break }
            node = next
            appendRuleList(head[Int(node)], head: head, next: ipRuleNext, values: ipRuleValue, into: &out)
            bit -= 1
        }
    }

    private func collectIPv6(_ bytes: [UInt8], source: Bool, into out: inout [Int]) {
        let child = source ? srcV6Child : v6Child
        let head = source ? srcV6Head : v6Head
        var node: Int32 = 0
        appendRuleList(head[0], head: head, next: ipRuleNext, values: ipRuleValue, into: &out)
        var bit = 0
        while bit < 128 {
            let byte = bytes[bit >> 3]
            let value = Int((byte >> UInt8(7 - (bit & 7))) & 1)
            let next = child[Int(node) * 2 + value]
            if next < 0 { break }
            node = next
            appendRuleList(head[Int(node)], head: head, next: ipRuleNext, values: ipRuleValue, into: &out)
            bit += 1
        }
    }

    private func collectProcessNames(_ meta: ConnectionMeta, into out: inout [Int]) {
        guard !processNames.isEmpty else { return }
        for candidate in [meta.sourceApp, meta.sourceBundleID] {
            guard let raw = candidate?.lowercased(), !raw.isEmpty else { continue }
            appendProcess(raw, into: &out)
            let base = (raw as NSString).lastPathComponent
            if base != raw { appendProcess(base, into: &out) }
            if base.hasSuffix(".app") { appendProcess(String(base.dropLast(4)), into: &out) }
        }
    }

    private func appendProcess(_ key: String, into out: inout [Int]) {
        guard let list = processNames[key] else { return }
        for value in list { out.append(Int(value)) }
    }

    private func appendRuleList(_ head: Int32, head heads: [Int32], next: [Int32],
                                values: [Int32], into out: inout [Int]) {
        var entry = head
        while entry >= 0 {
            out.append(Int(values[Int(entry)]))
            entry = next[Int(entry)]
        }
    }

    private static func sortedUnique(_ values: [Int]) -> [Int] {
        guard values.count > 1 else { return values }
        let sorted = values.sorted()
        var result: [Int] = []
        result.reserveCapacity(sorted.count)
        var last = -1
        for value in sorted where value != last {
            result.append(value)
            last = value
        }
        return result
    }

    // MARK: Build

    private mutating func build(_ rules: [RulePrepared]) {
        for prepared in rules {
            guard prepared.index >= 0 else { continue }
            let position = Int32(prepared.index)
            let rule = prepared.rule

            // A negated rule matches the complement of its matcher, so it can fire
            // for almost any connection: never narrow it.
            if rule.negate {
                alwaysCheck.append(position)
                continue
            }

            switch rule.kind {
            case .domain:
                guard !prepared.value.isEmpty else { break }
                exactDomain[prepared.value, default: []].append(position)

            case .domainSuffix:
                guard !prepared.value.isEmpty else { break }
                insertSuffix(prepared.value, rule: position)

            case .domainKeyword:
                guard !prepared.value.isEmpty else { break }
                insertKeyword(prepared.value, rule: position)

            case .ipCIDR, .ipCIDR6, .srcIPCIDR:
                guard let cidr = prepared.cidr else { break }
                let source = rule.kind == .srcIPCIDR
                if cidr.isIPv4 {
                    if source {
                        RuleIndex.insertPrefix(cidr, rule: position, child: &srcV4Child,
                                               head: &srcV4Head, next: &ipRuleNext, values: &ipRuleValue)
                    } else {
                        RuleIndex.insertPrefix(cidr, rule: position, child: &v4Child,
                                               head: &v4Head, next: &ipRuleNext, values: &ipRuleValue)
                    }
                } else {
                    if source {
                        RuleIndex.insertPrefix(cidr, rule: position, child: &srcV6Child,
                                               head: &srcV6Head, next: &ipRuleNext, values: &ipRuleValue)
                    } else {
                        RuleIndex.insertPrefix(cidr, rule: position, child: &v6Child,
                                               head: &v6Head, next: &ipRuleNext, values: &ipRuleValue)
                    }
                }

            case .processName:
                guard !prepared.value.isEmpty else { break }
                processNames[prepared.value.lowercased(), default: []].append(position)

            case .domainRegex:
                // No cheap safe pre-filter for an arbitrary regex: compile-check it
                // (an uncompilable pattern can never match) and always check it.
                guard prepared.regex != nil else { break }
                alwaysCheck.append(position)

            case .ruleSet:
                let key = prepared.value.lowercased()
                guard !key.isEmpty, memberIndex[key] != nil else {
                    // Unknown set contents: evaluate it like the linear engine does.
                    alwaysCheck.append(position)
                    break
                }
                setBuckets[key, default: []].append(position)

            default:
                // GEOIP, AND, OR, NOT, MATCH and any future kind.
                alwaysCheck.append(position)
            }
        }

        buildFailureLinks()
        acFirstChild = []
        acChildNext = []
        acChildByte = []
        acChildNode = []
    }

    private mutating func insertSuffix(_ value: String, rule: Int32) {
        var node: Int32 = 0
        for label in value.split(separator: ".", omittingEmptySubsequences: false).reversed() {
            let key = SuffixEdge(node: node, label: String(label))
            if let next = suffixEdges[key] {
                node = next
            } else {
                let fresh = Int32(suffixRuleHead.count)
                suffixEdges[key] = fresh
                suffixRuleHead.append(-1)
                node = fresh
            }
        }
        suffixRuleNext.append(suffixRuleHead[Int(node)])
        suffixRuleValue.append(rule)
        suffixRuleHead[Int(node)] = Int32(suffixRuleValue.count - 1)
    }

    private mutating func insertKeyword(_ value: String, rule: Int32) {
        var node: Int32 = 0
        for byte in value.utf8 {
            let key = (Int64(node) << 8) | Int64(byte)
            if let next = acNext[key] {
                node = next
            } else {
                let fresh = Int32(acFail.count)
                acNext[key] = fresh
                acFail.append(0)
                acOutHead.append(-1)
                acOutLink.append(-1)
                acFirstChild.append(-1)
                acChildByte.append(byte)
                acChildNode.append(fresh)
                acChildNext.append(acFirstChild[Int(node)])
                acFirstChild[Int(node)] = Int32(acChildNode.count - 1)
                node = fresh
            }
        }
        acOutNext.append(acOutHead[Int(node)])
        acOutValue.append(rule)
        acOutHead[Int(node)] = Int32(acOutValue.count - 1)
    }

    private mutating func buildFailureLinks() {
        guard acFail.count > 1 else { return }
        var queue: [Int32] = []
        queue.reserveCapacity(acFail.count)
        var child = acFirstChild[0]
        while child >= 0 {
            let node = acChildNode[Int(child)]
            acFail[Int(node)] = 0
            queue.append(node)
            child = acChildNext[Int(child)]
        }

        var cursor = 0
        while cursor < queue.count {
            let parent = queue[cursor]
            cursor += 1
            var edge = acFirstChild[Int(parent)]
            while edge >= 0 {
                let byte = acChildByte[Int(edge)]
                let node = acChildNode[Int(edge)]
                var fallback = acFail[Int(parent)]
                while true {
                    if let target = acNext[(Int64(fallback) << 8) | Int64(byte)] {
                        if target != node { acFail[Int(node)] = target }
                        break
                    }
                    if fallback == 0 { break }
                    fallback = acFail[Int(fallback)]
                }
                let fail = acFail[Int(node)]
                acOutLink[Int(node)] = acOutHead[Int(fail)] >= 0 ? fail : acOutLink[Int(fail)]
                queue.append(node)
                edge = acChildNext[Int(edge)]
            }
        }
    }

    private static func insertPrefix(_ cidr: CIDR, rule: Int32,
                                     child: inout [Int32], head: inout [Int32],
                                     next: inout [Int32], values: inout [Int32]) {
        var node: Int32 = 0
        var bit = 0
        while bit < cidr.prefix {
            let byte = cidr.networkBytes[bit >> 3]
            let value = Int((byte >> UInt8(7 - (bit & 7))) & 1)
            let slot = Int(node) * 2 + value
            if child[slot] < 0 {
                let fresh = Int32(head.count)
                child[slot] = fresh
                child.append(-1)
                child.append(-1)
                head.append(-1)
            }
            node = child[slot]
            bit += 1
        }
        next.append(head[Int(node)])
        values.append(rule)
        head[Int(node)] = Int32(values.count - 1)
    }
}

import Foundation
import LeapinCore

/// Human-readable outcome of a routing decision, including a per-rule trace for the UI.
public struct RuleMatch: Sendable {
    public var matchedRule: Rule?
    public var policy: String
    public var trace: [String]
    /// Compact outer-to-inner explanation of the decision (nil when nothing matched).
    public var chain: RuleChain?

    public init(matchedRule: Rule? = nil, policy: String = "DIRECT", trace: [String] = [],
                chain: RuleChain? = nil) {
        self.matchedRule = matchedRule
        self.policy = policy
        self.trace = trace
        self.chain = chain
    }
}

/// Ordered first-match rule engine with Surge/Clash semantics.
public final class RuleEngine: RouteDeciding {
    private struct Evaluation {
        var matched: Bool
        var note: String
        var policyOverride: String?
        /// Rule-set members that fired, outermost first (empty for plain rules).
        var memberChain: [String] = []
    }

    private let rules: [RulePrepared]
    private let ruleSets: [String: [RulePrepared]]
    /// Matcher index over profile rules (and one nested index per loaded rule-set).
    private let index: RuleIndex
    /// Tests flip this off to get the original linear scan as a reference oracle.
    private let indexed: Bool
    private let geoIP: GeoIPDatabase?
    /// The resolver this engine decides with, exposed so the UI can show which
    /// member an automatic group actually picked instead of guessing.
    public var policies: PolicyResolver { resolver }

    private let resolver: PolicyResolver
    private let totalRuleCount: Int
    private let maxTraceLines: Int

    public convenience init(profile: Profile, ruleSets: [String: [Rule]] = [:],
                            geoIP: GeoIPDatabase? = nil) {
        self.init(profile: profile, ruleSets: ruleSets, geoIP: geoIP, useIndex: true)
    }

    internal init(profile: Profile, ruleSets: [String: [Rule]] = [:],
                  geoIP: GeoIPDatabase? = nil, useIndex: Bool) {
        self.resolver = PolicyResolver(profile: profile)
        self.geoIP = geoIP ?? GeoIPDatabase()
        let prepared = profile.rules.enumerated().map {
            RulePrepared.make($0.element, index: $0.offset)
        }
        self.rules = prepared
        var preparedSets: [String: [RulePrepared]] = [:]
        for (name, members) in ruleSets {
            preparedSets[name.lowercased()] = members.enumerated().map {
                RulePrepared.make($0.element, index: $0.offset)
            }
        }
        self.ruleSets = preparedSets
        var members: [String: RuleIndex] = [:]
        for (key, list) in preparedSets {
            members[key] = RuleIndex(prepared: list)
        }
        self.index = RuleIndex(prepared: prepared, ruleSetMembers: members)
        self.indexed = useIndex
        self.totalRuleCount = profile.rules.count + ruleSets.values.reduce(0) { $0 + $1.count }
        self.maxTraceLines = 200
    }

    /// Rules in the profile plus every loaded rule-set entry.
    public var ruleCount: Int { totalRuleCount }

    // MARK: - RouteDeciding

    public func decide(_ meta: ConnectionMeta) -> RouteDecision {
        // Hot path: `match()` keeps the first-match semantics but skips every trace
        // string allocation and the per-rule `describe()` call that `explain()` needs
        // for the UI. With 100k rules the trace used to dominate the decision.
        let outcome = match(meta)
        let outbound = resolver.resolve(outcome.policy)
        let matchedLabel: String?
        if let rule = outcome.matchedRule {
            matchedLabel = rule.raw.isEmpty ? RuleParser.exportLine(rule, matchToken: "FINAL") : rule.raw
        } else {
            matchedLabel = nil
        }
        return RouteDecision(policy: outcome.policy, outbound: outbound,
                             matchedRule: matchedLabel, isBlocked: outbound.type == .reject,
                             chain: outcome.chain)
    }

    /// First-match evaluation without building a trace. `trace` is always empty; use
    /// `explain(_:)` when the per-rule explanation is actually rendered.
    public func match(_ meta: ConnectionMeta) -> RuleMatch {
        let host = HostNormalizer.normalize(meta.host)
        // One reusable set: `evaluateRuleSet` inserts and removes its key before
        // returning, so the set is empty again after every rule. Hoisting it avoids a
        // fresh allocation per rule in the linear scan.
        var visitedSets: Set<String> = []
        let positions = indexed ? index.candidates(for: meta, host: host) : Array(rules.indices)
        for position in positions {
            guard position >= 0 && position < rules.count else { continue }
            let prepared = rules[position]
            let result = evaluate(prepared, meta: meta, host: host, depth: 0, visitedSets: &visitedSets)
            if result.matched {
                let policy = result.policyOverride ?? prepared.rule.policy
                let resolved = policy.isEmpty ? "DIRECT" : policy
                return RuleMatch(matchedRule: prepared.rule,
                                 policy: resolved,
                                 trace: [],
                                 chain: makeChain(rule: prepared.rule, index: position + 1,
                                                  result: result, policy: resolved))
            }
        }
        return RuleMatch(matchedRule: nil, policy: "DIRECT", trace: [])
    }

    /// Outer rule plus any rule-set members that decided it. Built only on a match,
    /// so the hot path keeps paying nothing for connections that fall through.
    private func makeChain(rule: Rule, index: Int, result: Evaluation, policy: String) -> RuleChain {
        let outer = RuleChain.Step(label: describe(rule),
                                   detail: result.note.isEmpty ? nil : result.note)
        let members = result.memberChain.map { RuleChain.Step(label: $0, detail: "rule-set member") }
        return RuleChain(steps: [outer] + members, index: index, total: rules.count,
                         policy: policy, isFinal: rule.kind == .match)
    }

    public func explain(_ meta: ConnectionMeta) -> RuleMatch {
        let host = HostNormalizer.normalize(meta.host)
        var trace: [String] = []
        var header = "host=\(host) port=\(meta.port)"
        if let ip = meta.destinationIP, !ip.isEmpty { header += " ip=\(ip)" }
        if let app = meta.sourceApp, !app.isEmpty { header += " app=\(app)" }
        trace.append(header)

        var visitedSets: Set<String> = []
        for (index, prepared) in rules.enumerated() {
            let result = evaluate(prepared, meta: meta, host: host, depth: 0, visitedSets: &visitedSets)
            if result.matched {
                let policy = result.policyOverride ?? prepared.rule.policy
                let resolved = policy.isEmpty ? "DIRECT" : policy
                if trace.count < maxTraceLines {
                    trace.append("✓ #\(index + 1) \(describe(prepared.rule)) → \(resolved)")
                }
                trace.append("matched rule #\(index + 1) of \(rules.count)")
                return RuleMatch(matchedRule: prepared.rule, policy: resolved, trace: trace)
            }
            if trace.count < maxTraceLines {
                var line = "✗ #\(index + 1) \(describe(prepared.rule))"
                if !result.note.isEmpty { line += " (\(result.note))" }
                trace.append(line)
            } else if trace.count == maxTraceLines {
                trace.append("… \(rules.count - index) more rules not shown")
            }
        }

        trace.append("no rule matched → DIRECT")
        return RuleMatch(matchedRule: nil, policy: "DIRECT", trace: trace)
    }

    // MARK: - Evaluation

    private func evaluate(_ prepared: RulePrepared, meta: ConnectionMeta, host: String,
                          depth: Int, visitedSets: inout Set<String>) -> Evaluation {
        guard depth < 16 else { return Evaluation(matched: false, note: "expression too deep", policyOverride: nil) }
        let rule = prepared.rule
        var result: Evaluation
        switch rule.kind {
        case .domain:
            result = Evaluation(matched: host == prepared.value, note: "", policyOverride: nil)

        case .domainSuffix:
            result = Evaluation(matched: HostNormalizer.matchesSuffix(host, prepared.value),
                                note: "", policyOverride: nil)

        case .domainKeyword:
            result = Evaluation(matched: !prepared.value.isEmpty && host.contains(prepared.value),
                                note: "", policyOverride: nil)

        case .domainRegex:
            guard let box = prepared.regex else {
                result = Evaluation(matched: false, note: "invalid regex", policyOverride: nil)
                break
            }
            let range = NSRange(host.startIndex..<host.endIndex, in: host)
            result = Evaluation(matched: box.regex.firstMatch(in: host, range: range) != nil,
                                note: "", policyOverride: nil)

        case .srcIPCIDR:
            guard let cidr = prepared.cidr else {
                result = Evaluation(matched: false, note: "invalid CIDR", policyOverride: nil)
                break
            }
            guard let ip = meta.sourceIP, !ip.isEmpty else {
                result = Evaluation(matched: false, note: "no client IP", policyOverride: nil)
                break
            }
            result = Evaluation(matched: cidr.contains(address: ip), note: "", policyOverride: nil)

        case .ipCIDR, .ipCIDR6:
            guard let cidr = prepared.cidr else {
                result = Evaluation(matched: false, note: "invalid CIDR", policyOverride: nil)
                break
            }
            guard let ip = meta.destinationIP, !ip.isEmpty else {
                result = Evaluation(matched: false, note: "no destination IP", policyOverride: nil)
                break
            }
            result = Evaluation(matched: cidr.contains(address: ip),
                                note: rule.noResolve ? "no-resolve" : "", policyOverride: nil)

        case .processName:
            result = Evaluation(matched: RuleEngine.processMatches(prepared.value, meta: meta),
                                note: "", policyOverride: nil)

        case .geoIP:
            guard let ip = meta.destinationIP, !ip.isEmpty else {
                result = Evaluation(matched: false, note: "no destination IP", policyOverride: nil)
                break
            }
            let country = geoIP?.country(of: ip)
            result = Evaluation(matched: country?.caseInsensitiveCompare(prepared.value) == .orderedSame,
                                note: country.map { "geo=\($0)" } ?? "geo unknown", policyOverride: nil)

        case .ruleSet:
            result = evaluateRuleSet(prepared, meta: meta, host: host, depth: depth, visitedSets: &visitedSets)

        case .and:
            var allMatched = true
            var note = ""
            for operand in prepared.operands {
                let sub = evaluate(operand, meta: meta, host: host, depth: depth + 1, visitedSets: &visitedSets)
                if !sub.matched { allMatched = false; note = "failed \(describe(operand.rule))"; break }
            }
            result = Evaluation(matched: allMatched, note: note, policyOverride: nil)

        case .or:
            var anyMatched = false
            for operand in prepared.operands {
                let sub = evaluate(operand, meta: meta, host: host, depth: depth + 1, visitedSets: &visitedSets)
                if sub.matched { anyMatched = true; break }
            }
            result = Evaluation(matched: anyMatched, note: "", policyOverride: nil)

        case .not:
            guard let operand = prepared.operands.first else {
                result = Evaluation(matched: false, note: "empty NOT", policyOverride: nil)
                break
            }
            let sub = evaluate(operand, meta: meta, host: host, depth: depth + 1, visitedSets: &visitedSets)
            result = Evaluation(matched: !sub.matched, note: "", policyOverride: nil)

        case .match:
            result = Evaluation(matched: true, note: "", policyOverride: nil)
        }

        if rule.negate {
            result.matched.toggle()
            result.note = result.note.isEmpty ? "negated" : "\(result.note), negated"
        }
        return result
    }

    private func evaluateRuleSet(_ prepared: RulePrepared, meta: ConnectionMeta, host: String,
                                 depth: Int, visitedSets: inout Set<String>) -> Evaluation {
        let key = prepared.value.lowercased()
        guard let entries = ruleSets[key] else {
            return Evaluation(matched: false, note: "rule set '\(prepared.value)' not loaded", policyOverride: nil)
        }
        guard !visitedSets.contains(key) else {
            return Evaluation(matched: false, note: "rule set recursion", policyOverride: nil)
        }
        visitedSets.insert(key)
        defer { visitedSets.remove(key) }

        // Walk the members through their own index, in ascending order, so the
        // first matching member is identical to the original linear scan.
        let positions = index.memberRuleIndex(for: key)?.candidates(for: meta, host: host)
            ?? Array(entries.indices)
        for position in positions {
            guard position >= 0 && position < entries.count else { continue }
            let entry = entries[position]
            let sub = evaluate(entry, meta: meta, host: host, depth: depth + 1, visitedSets: &visitedSets)
            if sub.matched {
                // Surge semantics: RULE-SET,name,POLICY applies that policy to the whole set.
                // A policy-less outer rule (imported sets) keeps the member rule's policy.
                let outer = prepared.rule.policy
                let policy = outer.isEmpty ? (entry.rule.policy.isEmpty ? "DIRECT" : entry.rule.policy) : outer
                let memberLabel = entry.rule.raw.isEmpty
                    ? RuleParser.exportLine(entry.rule, matchToken: "FINAL")
                    : entry.rule.raw
                return Evaluation(matched: true, note: "set '\(prepared.value)'", policyOverride: policy,
                                  memberChain: [memberLabel] + sub.memberChain)
            }
        }
        return Evaluation(matched: false, note: "set '\(prepared.value)'", policyOverride: nil)
    }

    // MARK: - Preparation

    private static func processMatches(_ value: String, meta: ConnectionMeta) -> Bool {
        let target = value.lowercased()
        guard !target.isEmpty else { return false }
        func matches(_ candidate: String?) -> Bool {
            guard let candidate = candidate?.lowercased(), !candidate.isEmpty else { return false }
            if candidate == target { return true }
            let base = (candidate as NSString).lastPathComponent
            if base == target { return true }
            if base.hasSuffix(".app") && String(base.dropLast(4)) == target { return true }
            return false
        }
        return matches(meta.sourceApp) || matches(meta.sourceBundleID)
    }


    // MARK: - Diagnostics

    /// Static analysis over this engine's own rules: duplicates, shadowed rules,
    /// rules after FINAL, and rules that can never match. One entry per rule,
    /// ordered by descending priority within a single pass (never more than one
    /// finding per rule so the editor list stays stable).
    public func diagnostics() -> [RuleDiagnostic] {
        diagnostics(rules.map { $0.rule })
    }

    /// Static analysis for an arbitrary rule list, using this engine's loaded
    /// rule-sets to resolve RULE-SET references.
    public func diagnostics(_ sourceRules: [Rule]) -> [RuleDiagnostic] {
        guard !sourceRules.isEmpty else { return [] }

        var out: [RuleDiagnostic] = []
        out.reserveCapacity(sourceRules.count)

        // First occurrence per exact matcher (kind + value + negate), used for
        // "shadowed"; the full signature adds policy and modifiers for "duplicate".
        var firstMatcher: [String: Int] = [:]
        var firstSignature: [String: Int] = [:]
        // Earlier DOMAIN-SUFFIX rules that may cover later domain matchers.
        var suffixAncestors: [(domain: String, index: Int)] = []
        // Earlier, non-negated, plain CIDR rules that may cover later prefixes.
        var cidrAncestors: [(cidr: CIDR, source: Bool, index: Int)] = []
        // 1-based index of the first reachable FINAL rule; everything after it is dead.
        var finalStop: Int?

        for (offset, rule) in sourceRules.enumerated() {
            // 0-based rule position, matching RuleDiagnostic consumers (the editor
            // preview and the control plane both key by array offset).
            let position = offset
            let prepared = RulePrepared.make(rule, index: offset)
            let raw = rule.raw.isEmpty
                ? RuleParser.exportLine(rule, matchToken: "FINAL")
                : rule.raw

            if let stop = finalStop, position > stop {
                out.append(RuleDiagnostic(ruleID: rule.id, raw: raw, index: position,
                                          kind: .unreachable,
                                          reason: "位于第 \(stop + 1) 条 FINAL/MATCH 之后，永远不会被评估",
                                          shadowedByIndex: stop))
                continue
            }

            if let why = Self.neverMatchReason(rule, prepared: prepared) {
                out.append(RuleDiagnostic(ruleID: rule.id, raw: raw, index: position,
                                          kind: .neverMatch, reason: why,
                                          shadowedByIndex: nil))
                Self.record(rule, prepared: prepared, position: position,
                            matcher: &firstMatcher, signature: &firstSignature,
                            suffixes: &suffixAncestors, cidrs: &cidrAncestors)
                continue
            }

            let key = rule.value.lowercased()
            if rule.kind == .ruleSet, ruleSets[key] == nil {
                out.append(RuleDiagnostic(ruleID: rule.id, raw: raw, index: position,
                                          kind: .ruleSetMissing,
                                          reason: "引用的规则集 '\(rule.value)' 尚未加载",
                                          shadowedByIndex: nil))
                Self.record(rule, prepared: prepared, position: position,
                            matcher: &firstMatcher, signature: &firstSignature,
                            suffixes: &suffixAncestors, cidrs: &cidrAncestors)
                continue
            }

            if let signature = Self.signatureKey(rule, prepared: prepared),
               let earlier = firstSignature[signature] {
                out.append(RuleDiagnostic(ruleID: rule.id, raw: raw, index: position,
                                          kind: .duplicate,
                                          reason: "与第 \(earlier + 1) 条完全重复（同 kind/value/policy/negate/modifiers）",
                                          shadowedByIndex: earlier))
                Self.record(rule, prepared: prepared, position: position,
                            matcher: &firstMatcher, signature: &firstSignature,
                            suffixes: &suffixAncestors, cidrs: &cidrAncestors)
                continue
            }

            if let earlier = Self.shadowingIndex(rule, prepared: prepared,
                                                 firstMatcher: firstMatcher,
                                                 suffixes: suffixAncestors,
                                                 cidrs: cidrAncestors) {
                out.append(RuleDiagnostic(ruleID: rule.id, raw: raw, index: position,
                                          kind: .shadowed,
                                          reason: "被第 \(earlier + 1) 条的规则必然覆盖，永远不会命中",
                                          shadowedByIndex: earlier))
                Self.record(rule, prepared: prepared, position: position,
                            matcher: &firstMatcher, signature: &firstSignature,
                            suffixes: &suffixAncestors, cidrs: &cidrAncestors)
                continue
            }

            Self.record(rule, prepared: prepared, position: position,
                        matcher: &firstMatcher, signature: &firstSignature,
                        suffixes: &suffixAncestors, cidrs: &cidrAncestors)

            // A FINAL rule stops evaluation for everything after it. A negated
            // FINAL can never fire (true toggled to false), so it is not a stop.
            if rule.kind == .match, !rule.negate, finalStop == nil {
                finalStop = position
            }
        }

        return out
    }

    // MARK: - Diagnostics helpers

    /// Records a rule as a possible shadower for later rules. Only simple,
    /// non-negated matchers are eligible: negations and boolean expressions do
    /// not imply "everything the later rule matches, the earlier rule matches".
    private static func record(_ rule: Rule, prepared: RulePrepared, position: Int,
                               matcher: inout [String: Int],
                               signature: inout [String: Int],
                               suffixes: inout [(domain: String, index: Int)],
                               cidrs: inout [(cidr: CIDR, source: Bool, index: Int)]) {
        if let key = matcherKey(rule, prepared: prepared), matcher[key] == nil {
            matcher[key] = position
        }
        if let key = signatureKey(rule, prepared: prepared), signature[key] == nil {
            signature[key] = position
        }
        guard !rule.negate else { return }
        switch rule.kind {
        case .domainSuffix where !prepared.value.isEmpty:
            suffixes.append((prepared.value, position))
        case .ipCIDR, .ipCIDR6, .srcIPCIDR:
            if let cidr = prepared.cidr {
                cidrs.append((cidr, rule.kind == .srcIPCIDR, position))
            }
        default:
            break
        }
    }

    /// Matcher identity without policy: kind family + normalized value + negate.
    private static func matcherKey(_ rule: Rule, prepared: RulePrepared) -> String? {
        switch rule.kind {
        case .domain, .domainSuffix, .domainKeyword:
            guard !prepared.value.isEmpty else { return nil }
            return "\(rule.kind.rawValue)|\(prepared.value)|\(rule.negate)"
        case .domainRegex:
            return "regex|\(rule.value)|\(rule.negate)"
        case .ipCIDR, .ipCIDR6, .srcIPCIDR:
            guard let cidr = prepared.cidr else { return nil }
            let target = rule.kind == .srcIPCIDR ? "src" : "dst"
            return "cidr|\(target)|\(cidr.description)|\(rule.negate)"
        case .processName:
            return "process|\(prepared.value.lowercased())|\(rule.negate)"
        case .geoIP:
            return "geo|\(prepared.value)|\(rule.negate)"
        case .ruleSet:
            return "set|\(prepared.value.lowercased())|\(rule.negate)"
        case .and, .or, .not:
            return "expr|\(rule.kind.rawValue)|\(rule.value)|\(rule.negate)"
        case .match:
            return "final|\(rule.negate)"
        }
    }

    /// Matcher identity plus policy and modifiers: two rules with the same
    /// signature are true duplicates.
    private static func signatureKey(_ rule: Rule, prepared: RulePrepared) -> String? {
        guard let base = matcherKey(rule, prepared: prepared) else { return nil }
        let modifiers = rule.modifiers.sorted().joined(separator: ",")
        return "\(base)|\(rule.policy)|\(modifiers)"
    }

    /// Returns the 1-based index of an earlier rule that necessarily covers this
    /// one, if any. Deliberately conservative: when in doubt, report nothing.
    private static func shadowingIndex(_ rule: Rule, prepared: RulePrepared,
                                       firstMatcher: [String: Int],
                                       suffixes: [(domain: String, index: Int)],
                                       cidrs: [(cidr: CIDR, source: Bool, index: Int)]) -> Int? {
        guard !rule.negate else { return nil }
        // Same matcher, different policy/modifiers: the later one can never win.
        if let key = matcherKey(rule, prepared: prepared), let earlier = firstMatcher[key] {
            return earlier
        }
        guard !prepared.value.isEmpty else { return nil }

        switch rule.kind {
        case .domainSuffix, .domain:
            let value = prepared.value
            for ancestor in suffixes where value == ancestor.domain || value.hasSuffix("." + ancestor.domain) {
                return ancestor.index
            }
        case .ipCIDR, .ipCIDR6, .srcIPCIDR:
            guard let inner = prepared.cidr else { return nil }
            let source = rule.kind == .srcIPCIDR
            for outer in cidrs where outer.source == source && cidrCovers(outer.cidr, inner) {
                return outer.index
            }
        default:
            break
        }
        return nil
    }

    /// True when every address inside inner also lives inside outer. Both must be
    /// the same family; the caller only uses this for non-negated plain CIDRs.
    private static func cidrCovers(_ outer: CIDR, _ inner: CIDR) -> Bool {
        guard outer.family == inner.family, outer.prefix <= inner.prefix else { return false }
        guard outer.prefix > 0 else { return true }
        let wholeBytes = outer.prefix / 8
        if wholeBytes > 0,
           outer.networkBytes[0..<wholeBytes] != inner.networkBytes[0..<wholeBytes] {
            return false
        }
        let remaining = outer.prefix % 8
        guard remaining > 0 else { return true }
        let index = wholeBytes
        let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - remaining))
        return (outer.networkBytes[index] & mask) == (inner.networkBytes[index] & mask)
    }

    /// A rule that can never match, for reasons that are decidable statically.
    private static func neverMatchReason(_ rule: Rule, prepared: RulePrepared) -> String? {
        let trimmed = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch rule.kind {
        case .domain, .domainSuffix, .domainKeyword, .ipCIDR, .ipCIDR6, .srcIPCIDR,
             .processName, .geoIP, .ruleSet:
            if trimmed.isEmpty { return "value 为空，永远不会命中" }
            if rule.kind == .ipCIDR || rule.kind == .ipCIDR6 || rule.kind == .srcIPCIDR,
               prepared.cidr == nil {
                return "CIDR '\(rule.value)' 无法解析，永远不会命中"
            }
        case .domainRegex:
            // An empty but valid pattern matches every host, so only a compile
            // failure counts as never-match.
            if prepared.regex == nil { return "正则 '\(rule.value)' 编译失败，永远不会命中" }
        case .or, .not:
            if prepared.operands.isEmpty { return "缺少子规则，表达式永远不会命中" }
        case .and, .match:
            break
        }
        return nil
    }

    private func describe(_ rule: Rule) -> String {
        if !rule.raw.isEmpty { return rule.raw }
        return RuleParser.exportLine(rule, matchToken: "FINAL")
    }
}

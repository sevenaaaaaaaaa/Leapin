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
    /// Raw rule-set members, kept for diagnostics (the prepared copies drop the
    /// original Rule and cannot be re-analyzed). Keys are lowercased like ruleSets.
    private let ruleSetRules: [String: [Rule]]
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
        var rawSets: [String: [Rule]] = [:]
        for (name, members) in ruleSets {
            rawSets[name.lowercased()] = members
        }
        self.ruleSetRules = rawSets
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

    /// Static analysis over this engine's own rules. Delegates to the shared
    /// analyzer so the engine, control plane and editor cannot drift apart.
    public func diagnostics() -> [RuleDiagnostic] {
        RuleDiagnosticsAnalyzer.analyze(rules.map { $0.rule }, ruleSets: ruleSetRules)
    }

    /// Static analysis for an arbitrary rule list, using this engine's loaded
    /// rule-sets to resolve RULE-SET references.
    public func diagnostics(_ sourceRules: [Rule]) -> [RuleDiagnostic] {
        RuleDiagnosticsAnalyzer.analyze(sourceRules, ruleSets: ruleSetRules)
    }


    private func describe(_ rule: Rule) -> String {
        if !rule.raw.isEmpty { return rule.raw }
        return RuleParser.exportLine(rule, matchToken: "FINAL")
    }
}

import Foundation
import LeapinCore

/// One-pass static analysis shared by the engine, the control plane (/v1/explain)
/// and the rule editor, so all three cannot drift apart.
///
/// For each rule the analyzer reports at most one finding, in this order:
/// unreachable (after FINAL) → never-match → rule-set-missing → duplicate → shadowed.
/// A later rule that stops evaluation (non-negated MATCH/FINAL) also makes every
/// following rule unreachable.
///
/// The ruleSets parameter maps a lowercased rule-set name to its member rules.
/// Pass nil when the sets have never been loaded: references are then treated as
/// unknown instead of missing, so the editor does not flag every RULE-SET rule
/// before the engine starts.
public enum RuleDiagnosticsAnalyzer {

    public static func analyze(_ sourceRules: [Rule],
                               ruleSets: [String: [Rule]]? = nil) -> [RuleDiagnostic] {
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
        // 0-based index of the first reachable FINAL rule; everything after it is dead.
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

            if let why = neverMatchReason(rule, prepared: prepared) {
                out.append(RuleDiagnostic(ruleID: rule.id, raw: raw, index: position,
                                          kind: .neverMatch, reason: why,
                                          shadowedByIndex: nil))
                record(rule, prepared: prepared, position: position,
                       matcher: &firstMatcher, signature: &firstSignature,
                       suffixes: &suffixAncestors, cidrs: &cidrAncestors)
                continue
            }

            if rule.kind == .ruleSet, let ruleSets {
                let key = rule.value.lowercased()
                if ruleSets[key] == nil {
                    out.append(RuleDiagnostic(ruleID: rule.id, raw: raw, index: position,
                                              kind: .ruleSetMissing,
                                              reason: "引用的规则集 '\(rule.value)' 尚未加载",
                                              shadowedByIndex: nil))
                    record(rule, prepared: prepared, position: position,
                           matcher: &firstMatcher, signature: &firstSignature,
                           suffixes: &suffixAncestors, cidrs: &cidrAncestors)
                    continue
                }
                // A non-negated RULE-SET whose members are all statically dead (or
                // which is empty) can never fire. A negated one would always fire,
                // which is a different problem, so it is left alone here.
                if !rule.negate, let count = deadMemberCount(key, ruleSets: ruleSets) {
                    // The loader materializes failed downloads as empty sets, so
                    // "no members" covers both an empty file and a failed fetch;
                    // say so instead of claiming the set is healthy.
                    let reason = count == 0
                        ? "规则集 '\(rule.value)' 没有可命中的成员规则（文件为空或加载失败），永远不会命中"
                        : "规则集 '\(rule.value)' 的 \(count) 条成员规则都无法命中，永远不会命中"
                    out.append(RuleDiagnostic(ruleID: rule.id, raw: raw, index: position,
                                              kind: .neverMatch, reason: reason,
                                              shadowedByIndex: nil))
                    record(rule, prepared: prepared, position: position,
                           matcher: &firstMatcher, signature: &firstSignature,
                           suffixes: &suffixAncestors, cidrs: &cidrAncestors)
                    continue
                }
            }

            if let signature = signatureKey(rule, prepared: prepared),
               let earlier = firstSignature[signature] {
                out.append(RuleDiagnostic(ruleID: rule.id, raw: raw, index: position,
                                          kind: .duplicate,
                                          reason: "与第 \(earlier + 1) 条完全重复（同 kind/value/policy/negate/modifiers）",
                                          shadowedByIndex: earlier))
                record(rule, prepared: prepared, position: position,
                       matcher: &firstMatcher, signature: &firstSignature,
                       suffixes: &suffixAncestors, cidrs: &cidrAncestors)
                continue
            }

            if let earlier = shadowingIndex(rule, prepared: prepared,
                                            firstMatcher: firstMatcher,
                                            suffixes: suffixAncestors,
                                            cidrs: cidrAncestors) {
                out.append(RuleDiagnostic(ruleID: rule.id, raw: raw, index: position,
                                          kind: .shadowed,
                                          reason: "被第 \(earlier + 1) 条的规则必然覆盖，永远不会命中",
                                          shadowedByIndex: earlier))
                record(rule, prepared: prepared, position: position,
                       matcher: &firstMatcher, signature: &firstSignature,
                       suffixes: &suffixAncestors, cidrs: &cidrAncestors)
                continue
            }

            record(rule, prepared: prepared, position: position,
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

    // MARK: - Rule-set reachability

    /// Number of members when every one of them is statically unable to match
    /// (including the empty set), or nil when at least one may match.
    /// Unknown sets are never reported here; the caller checks presence first.
    private static func deadMemberCount(_ name: String,
                                        ruleSets: [String: [Rule]]) -> Int? {
        guard let members = ruleSets[name.lowercased()] else { return nil }
        var visited: Set<String> = [name.lowercased()]
        for member in members {
            if memberCanMatch(member, ruleSets: ruleSets, visited: &visited) { return nil }
        }
        return members.count
    }

    /// Whether a rule-set member can ever evaluate to true. Conservative by
    /// design: unknown and recursive references are treated as live, and only
    /// findings that are provable from the rule text are used.
    private static func memberCanMatch(_ rule: Rule,
                                       ruleSets: [String: [Rule]],
                                       visited: inout Set<String>) -> Bool {
        let prepared = RulePrepared.make(rule, index: -1)
        if neverMatchReason(rule, prepared: prepared) != nil { return false }
        switch rule.kind {
        case .ruleSet:
            // A negated set matches when its members do not, so it can fire even
            // with a dead or empty member list; treat it as live.
            if rule.negate { return true }
            let key = rule.value.lowercased()
            guard let members = ruleSets[key] else { return true }
            guard !visited.contains(key) else { return true }
            visited.insert(key)
            defer { visited.remove(key) }
            for member in members {
                if memberCanMatch(member, ruleSets: ruleSets, visited: &visited) { return true }
            }
            return false
        case .match:
            return !rule.negate
        default:
            return true
        }
    }

    // MARK: - Shadowing helpers

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
        // Negation flips the static verdict. Every reason below describes an
        // inner matcher that is always false (empty value, bad CIDR, failed
        // regex, empty OR/NOT), and negating such a matcher yields a catch-all,
        // not a dead rule. MATCH is the one kind whose inner value is always
        // true, so only a negated MATCH is provably dead.
        if rule.kind == .match {
            return rule.negate ? "MATCH/FINAL 被取反，结果恒为 false，永远不会命中" : nil
        }
        if rule.negate { return nil }
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
        case .match, .and:
            break
        }
        return nil
    }
}

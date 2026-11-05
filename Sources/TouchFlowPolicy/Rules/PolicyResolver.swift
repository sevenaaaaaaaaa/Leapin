import Foundation
import TouchFlowCore

/// Expands policy groups (select / url-test / fallback / load-balance / reject) into a
/// concrete outbound, following `selections` > `group.selected` > first member, with cycle
/// protection and a DIRECT fallback for unknown names.
public final class PolicyResolver: @unchecked Sendable {
    private let profile: Profile
    private let outboundsByKey: [String: OutboundConfig]
    private let groupsByKey: [String: PolicyGroup]
    private let groupOrder: [PolicyGroup]
    private let lock = NSLock()
    private var selectionOverrides: [String: String]
    private var rotation = 0
    /// Last automatic winner per group; used for url-test hysteresis so a 3 ms blip
    /// does not flip the whole machine between two nodes every probe round.
    private var autoWinners: [String: String] = [:]

    public init(profile: Profile, selections: [String: String] = [:]) {
        self.profile = profile
        var outbounds: [String: OutboundConfig] = [:]
        for outbound in profile.outbounds {
            outbounds[outbound.name.lowercased()] = outbound
        }
        var groups: [String: PolicyGroup] = [:]
        var order: [PolicyGroup] = []
        for group in profile.groups {
            groups[group.name.lowercased()] = group
            order.append(group)
        }
        self.outboundsByKey = outbounds
        self.groupsByKey = groups
        self.groupOrder = order
        self.selectionOverrides = selections.reduce(into: [:]) { result, pair in
            result[pair.key.lowercased()] = pair.value
        }
    }

    // MARK: - Selections

    /// Manual group selections currently in effect (lowercased group names).
    public var selections: [String: String] { lock.withLock { selectionOverrides } }

    public func setSelection(group: String, outbound: String) {
        lock.withLock { selectionOverrides[group.lowercased()] = outbound }
    }

    public func clearSelection(group: String) {
        lock.withLock { selectionOverrides.removeValue(forKey: group.lowercased()) }
    }

    public var policyNames: [String] {
        var names = profile.outbounds.map(\.name)
        names.append(contentsOf: profile.groups.map(\.name))
        return names
    }

    // MARK: - Resolve

    public func resolve(_ policy: String) -> OutboundConfig {
        var stack: [String] = []
        return resolve(policy, stack: &stack) ?? .direct
    }

    /// Resolves every rule policy plus every group member, reporting what would silently
    /// fall back to DIRECT at runtime.
    public func validate() -> [String] {
        var issues: [String] = []
        for group in groupOrder {
            if group.proxies.isEmpty {
                issues.append("policy group '\(group.name)' has no members")
            }
            if let selected = group.selected,
               !group.proxies.contains(where: { $0.caseInsensitiveCompare(selected) == .orderedSame }) {
                issues.append("policy group '\(group.name)' selects unknown member '\(selected)'")
            }
            for member in group.proxies where memberKind(member) == nil {
                issues.append("policy group '\(group.name)' references unknown policy '\(member)'")
            }
        }
        issues.append(contentsOf: cycleDiagnostics())
        for outbound in profile.outbounds where !outbound.type.isDialable {
            let token = outbound.rawType ?? outbound.type.rawValue
            issues.append("outbound '\(outbound.name)' uses protocol '\(token)', which cannot be dialed yet")
        }
        for rule in profile.rules where !rule.policy.isEmpty && memberKind(rule.policy) == nil {
            let label = rule.raw.isEmpty ? "\(rule.kind.rawValue) \(rule.value)" : rule.raw
            issues.append("rule '\(label)' references unknown policy '\(rule.policy)'")
        }
        return issues
    }

    // MARK: - Internals

    private enum MemberKind {
        case outbound(OutboundConfig)
        case group(PolicyGroup)
        case builtin(OutboundConfig)
    }

    private func memberKind(_ name: String) -> MemberKind? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        if key.isEmpty { return nil }
        if key == "direct" { return .builtin(.direct) }
        if key == "reject" { return .builtin(.reject) }
        if let outbound = outboundsByKey[key] { return .outbound(outbound) }
        if let group = groupsByKey[key] { return .group(group) }
        return nil
    }

    private func resolve(_ policy: String, stack: inout [String]) -> OutboundConfig? {
        let trimmed = policy.trimmingCharacters(in: .whitespaces)
        guard let kind = memberKind(trimmed) else {
            TFLog.shared.warn("policy", "unknown policy '\(trimmed)' — falling back to DIRECT")
            return .direct
        }
        let key = trimmed.lowercased()
        switch kind {
        case .builtin(let outbound), .outbound(let outbound):
            return outbound
        case .group(let group):
            if stack.contains(key) {
                let path = (stack + [key]).joined(separator: " -> ")
                TFLog.shared.warn("policy", "policy group cycle detected: \(path)")
                return .direct
            }
            if group.type == .reject { return .reject }
            guard let member = chosenMember(group) else {
                TFLog.shared.warn("policy", "policy group '\(group.name)' has no usable member — falling back to DIRECT")
                return .direct
            }
            stack.append(key)
            defer { stack.removeLast() }
            return resolve(member, stack: &stack)
        }
    }

    /// Which member the group would use right now, without resolving it further.
    /// Manual selection wins; url-test and fallback consult the probe health store.
    public func effectiveMember(group name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard let group = groupsByKey[key], group.type != .reject else { return nil }
        return chosenMember(group)
    }

    private func currentSelection(for group: PolicyGroup) -> String? {
        lock.withLock { selectionOverrides[group.name.lowercased()] } ?? group.selected
    }

    private func chosenMember(_ group: PolicyGroup) -> String? {
        if let selection = currentSelection(for: group),
           let member = group.proxies.first(where: { $0.caseInsensitiveCompare(selection) == .orderedSame }) {
            return member
        }
        guard !group.proxies.isEmpty else { return nil }
        switch group.type {
        case .select:
            return group.proxies.first
        case .urlTest:
            // Honest url-test: pick the lowest fresh latency, keep the previous winner
            // while it stays within tolerance, fall back to the first member while no
            // probe has reported yet.
            return bestByLatency(group) ?? group.proxies.first
        case .fallback:
            return firstAlive(group) ?? group.proxies.first
        case .loadBalance:
            let index = lock.withLock { () -> Int in
                let value = rotation
                rotation = (rotation + 1) & 0xFFFF
                return value
            }
            return group.proxies[index % group.proxies.count]
        case .reject:
            return nil
        }
    }

    /// Members with a fresh, successful probe, fastest first.
    private func measured(_ group: PolicyGroup) -> [(name: String, ms: Int)] {
        var scored: [(String, Int)] = []
        for member in group.proxies {
            guard let health = TFHealth.shared.freshHealth(for: member, maxAge: 180),
                  let ms = health.latencyMs else { continue }
            scored.append((member, ms))
        }
        return scored.map { (name: $0.0, ms: $0.1) }.sorted { $0.ms < $1.ms }
    }

    private func bestByLatency(_ group: PolicyGroup) -> String? {
        let scored = measured(group)
        guard let fastest = scored.first else { return nil }
        let tolerance = max(group.tolerance ?? 50, 0)
        let key = group.name.lowercased()
        if let previous = lock.withLock({ autoWinners[key] }),
           let kept = scored.first(where: { $0.name.caseInsensitiveCompare(previous) == .orderedSame }),
           kept.ms <= fastest.ms + tolerance {
            return kept.name
        }
        lock.withLock { autoWinners[key] = fastest.name }
        return fastest.name
    }

    private func firstAlive(_ group: PolicyGroup) -> String? {
        for member in group.proxies {
            if let health = TFHealth.shared.freshHealth(for: member, maxAge: 180), health.isAlive {
                return member
            }
        }
        return nil
    }

    private func cycleDiagnostics() -> [String] {
        var issues: [String] = []
        var visiting: [String] = []
        var done: Set<String> = []

        func walk(_ key: String) {
            guard let group = groupsByKey[key] else { return }
            if done.contains(key) { return }
            if let index = visiting.firstIndex(of: key) {
                let path = (visiting[index...] + [key]).joined(separator: " -> ")
                issues.append("policy group cycle: \(path)")
                return
            }
            visiting.append(key)
            for member in group.proxies {
                let memberKey = member.lowercased()
                if groupsByKey[memberKey] != nil { walk(memberKey) }
            }
            visiting.removeLast()
            done.insert(key)
        }

        for group in groupOrder { walk(group.name.lowercased()) }
        return issues
    }
}

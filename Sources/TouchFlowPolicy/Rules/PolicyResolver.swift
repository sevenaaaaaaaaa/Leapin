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
        case .select, .fallback, .urlTest:
            return group.proxies.first
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

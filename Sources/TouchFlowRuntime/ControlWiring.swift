import Foundation
import TouchFlowCore
import TouchFlowPolicy
import TouchFlowNet

// MARK: - Hot-swappable forwarding boxes
//
// ProxyServer and DNSServer are built once and hold on to these boxes, not to the
// concrete engine/resolver/blocker. A profile reload therefore swaps the object
// behind the box instead of rebuilding listeners, so established connections and
// the listening sockets survive a rules-only edit.

/// Forwards route decisions to the current RuleEngine.
final class RouterBox: RouteDeciding, @unchecked Sendable {
    private let lock = NSLock()
    private var router: any RouteDeciding

    init(_ router: any RouteDeciding) {
        self.router = router
    }

    func swap(_ router: any RouteDeciding) {
        lock.withLock { self.router = router }
    }

    func decide(_ meta: ConnectionMeta) -> RouteDecision {
        let current = lock.withLock { router }
        return current.decide(meta)
    }
}

/// Forwards name resolution to the current DNSResolver.
final class ResolverBox: NameResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var resolver: any NameResolving

    init(_ resolver: any NameResolving) {
        self.resolver = resolver
    }

    func swap(_ resolver: any NameResolving) {
        lock.withLock { self.resolver = resolver }
    }

    func resolve(_ host: String) async throws -> [String] {
        let current = lock.withLock { resolver }
        return try await current.resolve(host)
    }
}

/// Forwards adblock verdicts to the current AdBlockEngine (nil = allow everything).
final class BlockerBox: DomainBlocking, @unchecked Sendable {
    private let lock = NSLock()
    private var blocker: (any DomainBlocking)?

    init(_ blocker: (any DomainBlocking)?) {
        self.blocker = blocker
    }

    func swap(_ blocker: (any DomainBlocking)?) {
        lock.withLock { self.blocker = blocker }
    }

    private var current: (any DomainBlocking)? {
        lock.withLock { blocker }
    }

    func verdict(for domain: String, thirdParty: Bool) -> BlockVerdict {
        current?.verdict(for: domain, thirdParty: thirdParty) ?? .allow
    }

    func verdict(for domain: String, path: String?, thirdParty: Bool) -> BlockVerdict {
        current?.verdict(for: domain, path: path, thirdParty: thirdParty) ?? .allow
    }

    func cosmeticSelectors(for domain: String) -> [String] {
        current?.cosmeticSelectors(for: domain) ?? []
    }
}

// MARK: - Temporary rule diagnostics
//
// RuleEngine.diagnostics() is being implemented by the rule-index workstream.
// Until it lands, this scanner surfaces the two classes of dead rule the editor
// needs most (byte-duplicates and shadowed domain matchers) plus rules hidden
// behind a MATCH/FINAL fallback. Delete once diagnostics() is available.

enum RuleDiagnosticsScanner {
    static func scan(profile: Profile) -> [RuleDiagnostic] {
        var diagnostics: [RuleDiagnostic] = []
        var seen: [String: Int] = [:]
        var domainOwner: [String: Int] = [:]
        var fallbackAt: Int?

        for (index, rule) in profile.rules.enumerated() {
            if let fallbackAt {
                diagnostics.append(RuleDiagnostic(
                    ruleID: rule.id, raw: rule.raw, index: index, kind: .unreachable,
                    reason: "排在第 \(fallbackAt + 1) 条兜底规则之后，永远不会被匹配",
                    shadowedByIndex: fallbackAt))
                continue
            }

            let key = "\(rule.kind.rawValue)|\(rule.value.lowercased())|\(rule.policy.lowercased())"
            if let earlier = seen[key] {
                diagnostics.append(RuleDiagnostic(
                    ruleID: rule.id, raw: rule.raw, index: index, kind: .duplicate,
                    reason: "与第 \(earlier + 1) 条规则完全相同",
                    shadowedByIndex: earlier))
            } else {
                seen[key] = index
            }

            if !rule.negate, rule.value.isEmpty {
                switch rule.kind {
                case .match:
                    break
                default:
                    diagnostics.append(RuleDiagnostic(
                        ruleID: rule.id, raw: rule.raw, index: index, kind: .neverMatch,
                        reason: "匹配值为空，永远不会命中"))
                }
            }

            switch rule.kind {
            case .domain, .domainSuffix:
                if !rule.negate {
                    let domain = rule.value.lowercased()
                    let covered = (rule.kind == .domainSuffix ? ".\(domain)" : domain)
                    if let earlier = domainOwner[covered], earlier != index,
                       profile.rules[earlier].policy.caseInsensitiveCompare(rule.policy) != .orderedSame {
                        diagnostics.append(RuleDiagnostic(
                            ruleID: rule.id, raw: rule.raw, index: index, kind: .shadowed,
                            reason: "域名已被第 \(earlier + 1) 条规则以其它策略匹配",
                            shadowedByIndex: earlier))
                    } else {
                        domainOwner[covered] = index
                    }
                }
            case .match:
                fallbackAt = index
            default:
                break
            }
        }
        return diagnostics
    }
}

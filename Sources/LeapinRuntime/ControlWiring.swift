import Foundation
import LeapinCore
import LeapinPolicy
import LeapinNet

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

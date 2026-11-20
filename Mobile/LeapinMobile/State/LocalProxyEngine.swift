import Foundation
import LeapinCore
import LeapinNet

/// Runs the real proxy engine inside the phone.
///
/// This is the seed of standalone mode: the same ProxyServer, DNS resolver and
/// (next) the rule engine the Mac uses, listening on loopback. A VPN extension on
/// iOS and a VpnService on Android will feed their packets into exactly this
/// pipeline, so nothing here is a mock.
@MainActor
@Observable
final class LocalProxyEngine {
    private(set) var isRunning = false
    private(set) var port: UInt16 = 0
    private(set) var lastError: String?
    private(set) var lastCheck: String?
    private(set) var isChecking = false

    private var server: ProxyServer?
    private var resolver: DNSResolver?

    init() {
        #if DEBUG
        // Simulator QA hook: start and self-check on launch, the same way the other
        // LEAPIN_MOBILE_* variables let a build open a specific tab.
        if ProcessInfo.processInfo.environment["LEAPIN_MOBILE_LOCAL_PROXY"] == "1" {
            start()
            Task { await selfCheck() }
        }
        #endif
    }

    func start() {
        guard !isRunning else { return }
        let config = DNSConfig(mode: .system, upstreams: [], fallback: [], cacheTTL: 120)
        let resolver = DNSResolver(config: config)
        do {
            let server = try ProxyServer(options: .init(port: 0, allowLAN: false),
                                         router: DirectRouter(),
                                         resolver: resolver,
                                         blocker: nil,
                                         flows: nil,
                                         capture: nil)
            try server.start()
            self.server = server
            self.resolver = resolver
            port = server.listeningPort
            isRunning = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        server?.stop()
        server = nil
        resolver = nil
        isRunning = false
        port = 0
    }

    /// Fetches a URL through the local proxy. Success here means the engine really
    /// parses a CONNECT, dials upstream and pumps bytes on this device — not that a
    /// class was constructed.
    func selfCheck(_ url: String = "https://example.com") async {
        guard isRunning else { return }
        isChecking = true
        defer { isChecking = false }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: Int(port),
            "HTTPSEnable": true,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": Int(port),
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        guard let target = URL(string: url) else {
            lastCheck = "URL 无效"
            return
        }
        do {
            let (data, response) = try await session.data(from: target)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            lastCheck = "经本机代理 http://127.0.0.1:\(port) 收到 HTTP \(code)，\(data.count) 字节"
        } catch {
            lastCheck = "经本机代理失败：\(error.localizedDescription)"
        }
    }
}

/// Everything goes DIRECT for now; the rule engine plugs in here next.
struct DirectRouter: RouteDeciding {
    func decide(_ meta: ConnectionMeta) -> RouteDecision {
        RouteDecision(policy: "DIRECT", outbound: .direct)
    }
}

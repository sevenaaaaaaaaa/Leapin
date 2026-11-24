import Foundation
import LeapinCore
import LeapinNet
import LeapinControl

/// Collects what the phone's own engine does, in the shape the console pages already
/// render. Without this the 状态 and 连接 pages could only ever show the Mac.
final class LocalFlowLog: FlowRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [FlowEvent] = []
    private var open: Set<UUID> = []
    private var bytesIn = 0
    private var bytesOut = 0
    private let limit = 200

    func record(_ event: FlowEvent) {
        lock.withLock {
            switch event.phase {
            case .opened:
                open.insert(event.id)
            case .closed:
                open.remove(event.id)
                bytesIn += event.bytesIn
                bytesOut += event.bytesOut
            case .failed, .rejected:
                open.remove(event.id)
            }
            events.append(event)
            if events.count > limit { events.removeFirst(events.count - limit) }
        }
    }

    /// Newest first, matching what the connection list shows.
    func snapshot() -> (rows: [ControlConnection], active: Int, bytesIn: Int, bytesOut: Int) {
        lock.withLock {
            // One row per connection: opened and closed share an id, and the list
            // shows the newest event for each.
            var seen = Set<String>()
            let latest = events.reversed().filter { event in
                seen.insert(event.id.uuidString).inserted
            }
            let rows = latest.map { event in
                ControlConnection(id: event.id.uuidString,
                                  timestampMs: event.timestamp.timeIntervalSince1970 * 1000,
                                  phase: event.phase.rawValue,
                                  host: event.host,
                                  port: Int(event.port),
                                  network: event.network,
                                  policy: event.policy,
                                  matchedRule: event.matchedRule ?? "",
                                  outbound: event.outbound,
                                  sourceApp: "本机",
                                  sourcePID: 0,
                                  bytesIn: Int64(event.bytesIn),
                                  bytesOut: Int64(event.bytesOut),
                                  durationMs: Double(event.durationMs),
                                  chainSummary: event.chain.map { chain in
                                      chain.steps.map(\.label).joined(separator: " → ")
                                  } ?? "")
            }
            return (rows, open.count, bytesIn, bytesOut)
        }
    }
}

/// Runs the real proxy engine inside the phone.
///
/// The same ProxyServer, DNS resolver and rule engine the Mac uses, listening on
/// loopback. A VPN extension on iOS and a VpnService on Android will feed their
/// packets into exactly this pipeline, so nothing here is a mock.
@MainActor
@Observable
final class LocalProxyEngine {
    static let shared = LocalProxyEngine()

    /// 固定端口：用户要把它手填进系统的 Wi-Fi 代理设置，随机端口做不到。
    /// 51003 与 docs/MOBILE-STANDALONE.md 的记录一致。
    static let defaultPort: UInt16 = 51003

    private(set) var isRunning = false
    private(set) var port: UInt16 = 0
    private(set) var lastError: String?
    private(set) var lastCheck: String?
    private(set) var isChecking = false
    /// Live view of this engine's traffic, for 状态 and 连接.
    private(set) var localConnections: [ControlConnection] = []
    private(set) var activeConnections = 0
    private(set) var totalBytesIn = 0
    private(set) var totalBytesOut = 0
    private(set) var startedAt: Date?

    private var server: ProxyServer?
    private var resolver: DNSResolver?
    private let log = LocalFlowLog()
    private var ticker: Task<Void, Never>?

    init() {
        #if DEBUG
        // Simulator QA hook: start and self-check on launch, the same way the other
        // LEAPIN_MOBILE_* variables let a build open a specific tab.
        if ProcessInfo.processInfo.environment["LEAPIN_MOBILE_LOCAL_PROXY"] == "1" {
            start()
            Task { await selfCheck() }
            return
        }
        #endif
        // 打开 App 就开引擎：首页第一问是「开没开」，默认答案应当是「开着」。
        start()
    }

    func start() {
        guard !isRunning else { return }
        let config = DNSConfig(mode: .system, upstreams: [], fallback: [], cacheTTL: 120)
        let resolver = DNSResolver(config: config)
        do {
            let server = try ProxyServer(options: .init(port: Self.defaultPort, allowLAN: false),
                                         router: DirectRouter(),
                                         resolver: resolver,
                                         blocker: nil,
                                         flows: log,
                                         capture: nil)
            try server.start()
            self.server = server
            self.resolver = resolver
            port = server.listeningPort
            isRunning = true
            lastError = nil
            startedAt = Date()
            startTicking()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        server?.stop()
        server = nil
        resolver = nil
        isRunning = false
        port = 0
        startedAt = nil
        localConnections = []
        activeConnections = 0
        totalBytesIn = 0
        totalBytesOut = 0
    }

    /// Polls the flow log four times a second while running; the log itself is
    /// lock-protected and safe to read from the main actor.
    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = self.log.snapshot()
                self.localConnections = snapshot.rows
                self.activeConnections = snapshot.active
                self.totalBytesIn = snapshot.bytesIn
                self.totalBytesOut = snapshot.bytesOut
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
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

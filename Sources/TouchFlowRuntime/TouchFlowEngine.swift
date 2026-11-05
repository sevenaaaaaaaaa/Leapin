import Foundation
import Combine
import TouchFlowCore
import TouchFlowPolicy
import TouchFlowNet
import TouchFlowIntegrations

public enum EngineState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case failed(String)

    public var label: String {
        switch self {
        case .stopped: return "已停止"
        case .starting: return "启动中"
        case .running: return "运行中"
        case .failed(let m): return "错误：\(m)"
        }
    }
}

public struct EngineStats: Sendable, Equatable {
    public var bytesIn: Int = 0
    public var bytesOut: Int = 0
    public var connections: Int = 0
    public var blocked: Int = 0
    public var captures: Int = 0
    public var requests: Int = 0
    public var startedAt: Date?
}

/// Glue layer: builds the policy + proxy + DNS stack for the active profile.
@MainActor
public final class TouchFlowEngine: ObservableObject {
    public static let shared = TouchFlowEngine()

    @Published public private(set) var state: EngineState = .stopped
    @Published public private(set) var profile: Profile
    @Published public private(set) var flows: [FlowEvent] = []
    @Published public private(set) var captures: [CapturedRequest] = []
    @Published public private(set) var logs: [LogEntry] = []
    @Published public private(set) var stats = EngineStats()
    @Published public private(set) var ruleTraceCount: Int = 0
    @Published public var lastError: String?
    @Published public var systemProxyActive: Bool = false
    @Published public var adblockActive: Bool = false
    @Published public var mitmActive: Bool = false

    public let store: ProfileStore
    private var proxies: [ProxyServer] = []
    /// The primary mixed-port listener (kept for introspection helpers).
    private var proxy: ProxyServer? { proxies.first }
    private var dnsServer: DNSServer?
    private var resolver: DNSResolver?
    private var ruleEngine: RuleEngine?
    private var adblock: AdBlockEngine?
    private var ca: CertificateAuthority?
    private let sink = EngineSink()
    private var logObserverInstalled = false

    public init(store: ProfileStore = .shared) {
        self.store = store
        self.profile = store.activeProfile()
        sink.engine = self
        installLogObserver()
    }

    private func installLogObserver() {
        guard !logObserverInstalled else { return }
        logObserverInstalled = true
        TFLog.shared.addObserver { [weak self] entry in
            Task { @MainActor in
                guard let self else { return }
                self.logs.append(entry)
                if self.logs.count > 1500 { self.logs.removeFirst(self.logs.count - 1500) }
            }
        }
    }

    // MARK: - Lifecycle

    public func start() async {
        guard state != .running, state != .starting else { return }
        state = .starting
        lastError = nil
        do {
            let ruleSets = await RuleSetLoader.load(sources: ruleSetSources(), cacheDirectory: store.cacheDirectory)
            let engine = RuleEngine(profile: profile, ruleSets: ruleSets)
            ruleEngine = engine

            let listDir = store.ensureBundledLists()
            var listPaths = profile.adblock.blockLists
            let bundled = listDir.appendingPathComponent("touchflow-ads.txt").path
            if profile.adblock.enabled, !listPaths.contains(bundled) { listPaths.append(bundled) }
            let blocker: AdBlockEngine? = profile.adblock.enabled
                ? (try? AdBlockEngine.load(listPaths: listPaths, allowList: profile.adblock.allowList))
                : nil
            adblock = blocker
            adblockActive = (blocker?.ruleCount ?? 0) > 0

            let dnsResolver = DNSResolver(config: profile.dns, blocker: blocker)
            resolver = dnsResolver
            if profile.general.dnsHijack {
                let server = DNSServer(port: profile.dns.listenPort, resolver: dnsResolver,
                                       blocker: blocker,
                                       fakeIP: profile.dns.mode == .fakeIP ? FakeIPPool(range: profile.dns.fakeIPRange) : nil)
                try server.start()
                dnsServer = server
            }

            if profile.general.mitmEnabled {
                let authority = try CertificateAuthority(directory: store.root.appendingPathComponent("ca", isDirectory: true))
                ca = authority
                mitmActive = true
            } else {
                ca = nil
                mitmActive = false
            }

            sink.reset()
            let general = profile.general
            let sinkCapture: CaptureSink? = general.captureEnabled ? sink : nil
            func makeServer(_ port: UInt16, http: Bool, socks: Bool) -> ProxyServer {
                let options = ProxyServer.Options(port: port,
                                                  allowLAN: general.allowLAN,
                                                  enableSOCKS5: socks, enableHTTP: http,
                                                  mitm: general.mitmEnabled,
                                                  mitmHosts: general.mitmHosts)
                return ProxyServer(options: options, router: engine, resolver: dnsResolver,
                                   blocker: blocker, flows: sink, capture: sinkCapture, ca: ca)
            }

            // Mixed port is required; the dedicated HTTP/SOCKS ports are best-effort so a
            // port clash there never prevents the main listener from coming up.
            let mixed = makeServer(general.mixedPort, http: true, socks: true)
            try mixed.start()
            proxies = [mixed]
            if general.httpPort != 0, general.httpPort != general.mixedPort {
                let http = makeServer(general.httpPort, http: true, socks: false)
                do { try http.start(); proxies.append(http) }
                catch { TFLog.shared.warn("engine", "HTTP 端口 \(general.httpPort) 未启动：\(error.localizedDescription)") }
            }
            if general.socksPort != 0, general.socksPort != general.httpPort, general.socksPort != general.mixedPort {
                let socks = makeServer(general.socksPort, http: false, socks: true)
                do { try socks.start(); proxies.append(socks) }
                catch { TFLog.shared.warn("engine", "SOCKS 端口 \(general.socksPort) 未启动：\(error.localizedDescription)") }
            }
            stats.startedAt = Date()
            state = .running
            TFLog.shared.info("engine", "代理已启动 127.0.0.1:\(profile.general.mixedPort)，规则 \(profile.rules.count) 条")
        } catch {
            teardown()
            state = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            TFLog.shared.error("engine", "启动失败：\(error.localizedDescription)")
        }
    }

    public func stop() {
        teardown()
        state = .stopped
        stats.startedAt = nil
        TFLog.shared.info("engine", "代理已停止")
    }

    private func teardown() {
        proxies.forEach { $0.stop() }
        proxies.removeAll()
        dnsServer?.stop(); dnsServer = nil
        resolver = nil
        ruleEngine = nil
        adblock = nil
        ca = nil
        adblockActive = false
        mitmActive = false
    }

    // MARK: - Profile

    public func reloadProfile() async {
        let wasRunning = state == .running
        if wasRunning { stop() }
        profile = store.activeProfile()
        if wasRunning { await start() }
    }

    @discardableResult
    public func saveProfile() -> Bool {
        do {
            _ = try store.save(profile)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    public func activate(_ id: UUID) async {
        guard let loaded = try? store.load(id: id) else { return }
        let wasRunning = state == .running
        if wasRunning { stop() }
        store.activeProfileID = id
        profile = loaded
        if wasRunning { await start() }
    }

    public func importProfile(from url: URL) async throws -> Profile {
        let imported = try store.importFile(at: url)
        store.activeProfileID = imported.id
        let wasRunning = state == .running
        if wasRunning { stop() }
        profile = imported
        if wasRunning { await start() }
        return imported
    }

    public func exportProfile(_ format: ProfileFormat) throws -> String {
        try store.export(profile, format: format)
    }

    public var profiles: [ProfileMeta] { store.list() }

    // MARK: - Rule / adblock inspection

    public func explain(host: String, port: UInt16 = 443) -> RuleMatch? {
        guard let engine = ruleEngine else { return nil }
        return engine.explain(ConnectionMeta(host: host, port: port))
    }

    public func adblockVerdict(domain: String) -> BlockVerdict {
        adblock?.verdict(for: domain, thirdParty: false) ?? .allow
    }

    private func ruleSetSources() -> [String] {
        // RuleSetLoader accepts local paths and URLs; names resolve against the profile directory.
        profile.rules.filter { $0.kind == .ruleSet }.map { $0.value }
    }

    // MARK: - System proxy

    public func toggleSystemProxy(_ enabled: Bool) {
        do {
            if enabled {
                try SystemProxy.enable(host: "127.0.0.1", port: Int(profile.general.httpPort),
                                       socksPort: Int(profile.general.socksPort))
            } else {
                try SystemProxy.disable()
            }
            systemProxyActive = enabled
        } catch {
            lastError = error.localizedDescription
            TFLog.shared.error("system", "系统代理设置失败：\(error.localizedDescription)")
        }
    }

    public func refreshSystemProxyStatus() {
        systemProxyActive = SystemProxy.status().enabled
    }

    // MARK: - Capture

    public func clearFlows() { flows.removeAll(); captures.removeAll() }

    public func exportHAR() throws -> Data {
        try HARExporter.export(captures, redact: true)
    }

    // MARK: - Sink callbacks (any thread)

    fileprivate func ingest(_ event: FlowEvent) {
        Task { @MainActor in
            self.stats.requests += 1
            self.stats.bytesIn += event.bytesIn
            self.stats.bytesOut += event.bytesOut
            if event.blockedBy != nil { self.stats.blocked += 1 }
            if event.phase == .opened { self.stats.connections += 1 }
            self.flows.append(event)
            if self.flows.count > 2000 { self.flows.removeFirst(self.flows.count - 2000) }
        }
    }

    fileprivate func ingest(_ request: CapturedRequest) {
        Task { @MainActor in
            self.stats.captures += 1
            self.captures.append(request)
            if self.captures.count > 1000 { self.captures.removeFirst(self.captures.count - 1000) }
        }
    }
}

private final class EngineSink: FlowRecording, CaptureSink, @unchecked Sendable {
    weak var engine: TouchFlowEngine?
    func reset() {}
    func record(_ event: FlowEvent) {
        Task { @MainActor [weak engine] in engine?.ingest(event) }
    }
    func capture(_ request: CapturedRequest) {
        Task { @MainActor [weak engine] in engine?.ingest(request) }
    }
}


// MARK: - Live editing (same file so the private(set) profile setter is reachable)

public extension TouchFlowEngine {
    // MARK: - Read-only introspection for the UI

    var ruleCount: Int { ruleEngine?.ruleCount ?? profile.rules.count }
    var adblockRuleCount: Int { adblock?.ruleCount ?? 0 }
    var activeConnections: Int { proxies.reduce(0) { $0 + $1.activeConnections } }

    func cosmeticSelectors(for domain: String) -> [String] {
        adblock?.cosmeticSelectors(for: domain) ?? []
    }

    /// Mutates the active profile, persists it, and optionally restarts the proxy stack.
    func updateProfile(restart: Bool = false, _ mutate: (inout Profile) -> Void) {
        var next = profile
        mutate(&next)
        profile = next
        _ = saveProfile()
        if restart, state == .running {
            Task { [weak self] in
                guard let self else { return }
                self.stop()
                await self.start()
            }
        }
    }

    @discardableResult
    func addRules(_ rules: [Rule], restart: Bool = true) -> Int {
        guard !rules.isEmpty else { return 0 }
        updateProfile(restart: restart) { $0.rules.append(contentsOf: rules) }
        return rules.count
    }

    /// Replaces the active profile in memory (optionally persisting it). Does not restart;
    /// call `stop()`/`start()` yourself when the engine is already running.
    func applyProfile(_ newProfile: Profile, persist: Bool = false) {
        profile = newProfile
        if persist { _ = saveProfile() }
    }

    func removeRule(id: String) {
        updateProfile(restart: false) { $0.rules.removeAll { $0.id == id } }
    }

    func moveRules(from offsets: IndexSet, to destination: Int) {
        updateProfile(restart: false) { profile in
            // SwiftUI's `move(fromOffsets:toOffset:)` is unavailable outside SwiftUI,
            // so reimplement the standard reorder here (drop-then-insert semantics).
            let moving = offsets.sorted().compactMap { (i: Int) -> Rule? in
                i >= 0 && i < profile.rules.count ? profile.rules[i] : nil
            }
            guard !moving.isEmpty else { return }
            var rest = profile.rules
            for i in offsets.sorted(by: >) where i >= 0 && i < rest.count {
                rest.remove(at: i)
            }
            let removedBefore = offsets.filter { $0 < destination }.count
            let target = max(0, min(rest.count, destination - removedBefore))
            rest.insert(contentsOf: moving, at: target)
            profile.rules = rest
        }
    }

    /// Policy-group manual selection ("Proxy" -> "HK-01").
    func selectOutbound(group: String, outbound: String) {
        updateProfile(restart: true) { profile in
            if let idx = profile.groups.firstIndex(where: { $0.name == group }) {
                profile.groups[idx].selected = outbound
            }
        }
    }

    func setAdBlockEnabled(_ enabled: Bool) {
        updateProfile(restart: true) { $0.adblock.enabled = enabled }
    }

    func setMITMEnabled(_ enabled: Bool) {
        updateProfile(restart: true) { $0.general.mitmEnabled = enabled }
    }

    func setSystemProxyBypass(_ hosts: [String]) {
        updateProfile(restart: false) { $0.general.bypass = hosts }
    }
}

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
    private var healthProber: HealthProber?
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
                // Hysteresis: trimming on every append meant an O(n) memmove per line.
                if self.logs.count > 1800 { self.logs.removeFirst(self.logs.count - 1500) }
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
                do {
                    try server.start()
                    dnsServer = server
                } catch {
                    // A busy DNS port must not take the whole proxy down: the mixed port
                    // keeps working, only DNS hijack is skipped (audit DNS-01).
                    dnsServer = nil
                    TFLog.shared.warn("engine", "DNS 端口 \(profile.dns.listenPort) 未启动：\(error.localizedDescription)")
                }
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
            resetRecordings()
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
            let probes = Self.probeTargets(for: profile)
            if !probes.isEmpty {
                let prober = HealthProber(dialer: OutboundDialer(resolver: dnsResolver), probes: probes)
                prober.start()
                healthProber = prober
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
        // Roll the system proxy back *before* the listeners disappear. Otherwise every
        // app on the machine keeps pointing at a port that is about to close, which
        // looks exactly like "the network is down".
        rollbackSystemProxyIfNeeded()
        teardown()
        state = .stopped
        stats.startedAt = nil
        TFLog.shared.info("engine", "代理已停止")
    }

    /// Disables the system proxy when TouchFlow enabled it. Safe to call from every
    /// stop path: explicit stop, profile switch, failed start and app termination.
    /// Returns false when the rollback failed, in which case `systemProxyActive`
    /// stays true so the UI can still offer a retry.
    @discardableResult
    private func rollbackSystemProxyIfNeeded() -> Bool {
        guard systemProxyActive else { return true }
        do {
            try SystemProxy.disable()
            systemProxyActive = false
            TFLog.shared.info("system", "已回滚系统代理")
            return true
        } catch {
            lastError = error.localizedDescription
            TFLog.shared.error("system", "系统代理回滚失败：\(error.localizedDescription)")
            return false
        }
    }

    /// Members of url-test / fallback groups, one probe per distinct outbound.
    /// The probe uses the group's own test URL when it has one, so latency matches
    /// what the config author intended to measure.
    private static func probeTargets(for profile: Profile) -> [HealthProber.Probe] {
        var probes: [HealthProber.Probe] = []
        var seen = Set<String>()
        for group in profile.groups where group.type == .urlTest || group.type == .fallback {
            let target = probeEndpoint(group.url)
            for member in group.proxies {
                guard let outbound = profile.outbound(named: member), outbound.type.isDialable else { continue }
                let key = outbound.name.lowercased()
                guard seen.insert(key).inserted else { continue }
                probes.append(.init(name: outbound.name, outbound: outbound,
                                    host: target.host, port: target.port))
            }
        }
        return probes
    }

    /// host/port for a group test URL; 443 gstatic is the sane default when the
    /// config has no url (or one we cannot parse).
    private static func probeEndpoint(_ url: String?) -> (host: String, port: UInt16) {
        if let url, let components = URLComponents(string: url), let host = components.host, !host.isEmpty {
            let port = components.port.map { UInt16(clamping: $0) } ?? (components.scheme == "http" ? 80 : 443)
            return (host, port)
        }
        return ("www.gstatic.com", 443)
    }

    /// Latest measured latency for an outbound, for the UI.
    public func latency(for outbound: String) -> Int? {
        TFHealth.shared.freshHealth(for: outbound, maxAge: 600)?.latencyMs
    }

    /// Member an automatic group (url-test / fallback) is using right now.
    /// Nil for select groups (their selection is the answer) and while stopped.
    public func effectiveMember(group: String) -> String? {
        ruleEngine?.policies.effectiveMember(group: group)
    }

    private func teardown() {
        healthProber?.stop()
        healthProber = nil
        TFHealth.shared.reset()
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
        try await importProfileDetailed(from: url).profile
    }

    /// Same as importProfile(from:) but also returns per-item diagnostics so the
    /// UI can tell the user what was dropped instead of silently losing nodes.
    @discardableResult
    public func importProfileDetailed(from url: URL) async throws -> ProfileImportOutcome {
        let outcome = try store.importFileDetailed(at: url)
        let imported = outcome.profile
        store.activeProfileID = imported.id
        let wasRunning = state == .running
        if wasRunning { stop() }
        profile = imported
        if wasRunning { await start() }
        return outcome
    }

    /// Imports a remote subscription link (http/https) and keeps the engine
    /// running across the swap, mirroring importProfileDetailed(from:).
    @discardableResult
    public func importRemoteProfile(_ link: String) async throws -> ProfileImportOutcome {
        let outcome = try await store.importRemote(link)
        let imported = outcome.profile
        store.activeProfileID = imported.id
        let wasRunning = state == .running
        if wasRunning { stop() }
        profile = imported
        if wasRunning { await start() }
        return outcome
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

    public func adblockVerdict(domain: String, path: String? = nil) -> BlockVerdict {
        adblock?.verdict(for: domain, path: path, thirdParty: false) ?? .allow
    }

    private func ruleSetSources() -> [String] {
        // RuleSetLoader accepts local paths and URLs; names resolve against the profile directory.
        profile.rules.filter { $0.kind == .ruleSet }.map { $0.value }
    }

    // MARK: - System proxy

    public func toggleSystemProxy(_ enabled: Bool) {
        do {
            if enabled {
                try enableSystemProxy()
                systemProxyActive = true
            } else {
                try SystemProxy.disable()
                systemProxyActive = false
            }
        } catch {
            lastError = error.localizedDescription
            TFLog.shared.error("system", "系统代理设置失败：\(error.localizedDescription)")
        }
    }

    /// Points the system proxy at the mixed listener that is actually bound.
    ///
    /// The dedicated HTTP/SOCKS ports are best-effort (see `start()`), so writing
    /// `general.httpPort`/`general.socksPort` could aim the whole machine at a port
    /// that never came up. The mixed port speaks both protocols and is mandatory.
    private func enableSystemProxy() throws {
        guard state == .running, let proxy, proxy.isRunning else {
            throw TouchFlowError.invalidConfiguration("代理尚未运行，无法开启系统代理")
        }
        let port = Int(proxy.listeningPort)
        guard (1...65535).contains(port) else {
            throw TouchFlowError.invalidConfiguration("代理监听端口不可用（\(port)）")
        }
        try SystemProxy.enable(host: "127.0.0.1", port: port, socksPort: port)
        TFLog.shared.info("system", "系统代理已指向 127.0.0.1:\(port)")
    }

    public func refreshSystemProxyStatus() {
        systemProxyActive = SystemProxy.status().enabled
    }

    // MARK: - Capture

    public func clearFlows() { flows.removeAll(); captures.removeAll() }

    public func exportHAR() throws -> Data {
        try HARExporter.export(captures, redact: true)
    }

    // MARK: - Sink callbacks

    private static let flowLimit = 2000
    private static let captureLimit = 1000

    /// Applies one coalesced batch coming from `EngineSink`.
    fileprivate func applyBuffered(_ events: [FlowEvent], _ requests: [CapturedRequest]) {
        if !requests.isEmpty {
            stats.captures += requests.count
            captures.append(contentsOf: requests)
            Self.trim(&captures, to: Self.captureLimit)
        }
        guard !events.isEmpty else { return }
        for event in events {
            stats.requests += 1
            stats.bytesIn += event.bytesIn
            stats.bytesOut += event.bytesOut
            if event.blockedBy != nil { stats.blocked += 1 }
            if event.phase == .opened { stats.connections += 1 }
        }
        flows.append(contentsOf: events)
        Self.trim(&flows, to: Self.flowLimit)
    }

    private static func trim<T>(_ list: inout [T], to limit: Int) {
        guard list.count > limit + limit / 4 else { return }
        list.removeFirst(list.count - limit)
    }

    /// Clears per-session recordings so restarting the engine does not keep stale
    /// flows/captures (PF-10).
    private func resetRecordings() {
        flows.removeAll(keepingCapacity: false)
        captures.removeAll(keepingCapacity: false)
        stats = EngineStats()
        ruleTraceCount = 0
    }
}

/// Buffers events from any thread and flushes them to the engine in ~16ms batches.
///
/// This used to allocate two `Task`s per event and push onto the main actor one by
/// one, so a single page load could enqueue hundreds of hops and every hop published
/// `flows` again (full SwiftUI invalidation).
private final class EngineSink: FlowRecording, CaptureSink, @unchecked Sendable {
    weak var engine: TouchFlowEngine?

    private let lock = NSLock()
    private var pendingFlows: [FlowEvent] = []
    private var pendingCaptures: [CapturedRequest] = []
    private var flushScheduled = false
    private static let maxPending = 4096

    func reset() {
        lock.lock()
        pendingFlows.removeAll(keepingCapacity: true)
        pendingCaptures.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func record(_ event: FlowEvent) {
        lock.lock()
        pendingFlows.append(event)
        if pendingFlows.count > Self.maxPending {
            pendingFlows.removeFirst(pendingFlows.count - Self.maxPending)
        }
        let schedule = !flushScheduled
        if schedule { flushScheduled = true }
        lock.unlock()
        if schedule { scheduleFlush() }
    }

    func capture(_ request: CapturedRequest) {
        lock.lock()
        pendingCaptures.append(request)
        if pendingCaptures.count > Self.maxPending {
            pendingCaptures.removeFirst(pendingCaptures.count - Self.maxPending)
        }
        let schedule = !flushScheduled
        if schedule { flushScheduled = true }
        lock.unlock()
        if schedule { scheduleFlush() }
    }

    private func scheduleFlush() {
        // The hop is what used to happen per event; now a whole burst shares one.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard let self else { return }
            let (events, requests) = self.drain()
            self.engine?.applyBuffered(events, requests)
        }
    }

    /// Takes the pending batch. Callable from any thread; the engine hop happens
    /// on the caller's main-actor task.
    private func drain() -> ([FlowEvent], [CapturedRequest]) {
        lock.lock()
        defer { lock.unlock() }
        flushScheduled = false
        let events = pendingFlows
        let requests = pendingCaptures
        pendingFlows.removeAll(keepingCapacity: true)
        pendingCaptures.removeAll(keepingCapacity: true)
        return (events, requests)
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

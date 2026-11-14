import Foundation
import Observation
import LeapinCore
import LeapinControl

/// Single source of truth for the mobile console: one endpoint, one snapshot of
/// the Mac agent, and the actions the screens can trigger.
@MainActor
@Observable
public final class ConsoleStore {
    public private(set) var endpoint: ConsoleEndpoint?
    public private(set) var status: ControlStatus?
    public private(set) var connections: [ControlConnection] = []
    public private(set) var policies: [ControlPolicyGroup] = []
    public private(set) var lastUpdated: Date?
    public private(set) var isRefreshing = false
    public private(set) var isConnecting = false
    public private(set) var lastError: String?

    /// Live polling keeps the dashboard honest without the user pulling to refresh.
    public var autoRefresh = true
    private var pollTask: Task<Void, Never>?

    public init() {
        self.endpoint = ConsoleEndpointStore.load()
    }

    public var isConnected: Bool { endpoint != nil && status != nil }

    public var connectionCount: Int { status?.activeConnections ?? connections.count }

    // MARK: - Session

    /// Verifies the endpoint with one `/v1/status` call before it is persisted,
    /// so a typo never leaves the app stuck on a dead address.
    public func connect(host: String, port: String, token: String) async -> Bool {
        guard let candidate = ConsoleEndpoint.parse(host: host, port: port, token: token) else {
            lastError = "请填写 Mac 的 IP、端口和令牌"
            return false
        }
        isConnecting = true
        lastError = nil
        defer { isConnecting = false }

        do {
            let loaded = try await ControlClient(endpoint: candidate).status()
            endpoint = candidate
            status = loaded
            ConsoleEndpointStore.save(candidate)
            lastUpdated = Date()
            startPolling()
            await refresh()
            return true
        } catch {
            lastError = message(for: error)
            return false
        }
    }

    public func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        endpoint = nil
        status = nil
        connections = []
        policies = []
        lastUpdated = nil
        ConsoleEndpointStore.clear()
    }

    // MARK: - Reads

    public func refresh() async {
        guard let endpoint else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let client = ControlClient(endpoint: endpoint)
        do {
            async let statusValue = client.status()
            async let connectionValue = client.connections(limit: 60)
            let (freshStatus, freshConnections) = try await (statusValue, connectionValue)
            status = freshStatus
            connections = freshConnections
            lastUpdated = Date()
            lastError = nil
        } catch {
            lastError = message(for: error)
            if case ControlClientError.unauthorized = error { /* keep session, show the error */ }
        }

        if policies.isEmpty, let fresh = try? await client.policies() {
            policies = fresh
        }
    }

    public func loadPolicies() async {
        guard let endpoint else { return }
        do {
            policies = try await ControlClient(endpoint: endpoint).policies()
            lastError = nil
        } catch {
            lastError = message(for: error)
        }
    }

    // MARK: - Actions

    public func select(group: String, outbound: String) async -> Bool {
        guard let endpoint else { return false }
        do {
            _ = try await ControlClient(endpoint: endpoint).select(group: group, outbound: outbound)
            await loadPolicies()
            return true
        } catch {
            lastError = message(for: error)
            return false
        }
    }

    public func reloadRules() async -> ControlReloadResult? {
        guard let endpoint else { return nil }
        do {
            let result = try await ControlClient(endpoint: endpoint).reload()
            await refresh()
            return result
        } catch {
            lastError = message(for: error)
            return nil
        }
    }

    public func explain(host: String, port: Int) async -> ControlExplainResult? {
        guard let endpoint else { return nil }
        do {
            return try await ControlClient(endpoint: endpoint).explain(host: host, port: port)
        } catch {
            lastError = message(for: error)
            return nil
        }
    }

    public func dnsTrace(host: String) async -> DNSTrace? {
        guard let endpoint else { return nil }
        do {
            return try await ControlClient(endpoint: endpoint).dnsTrace(host: host)
        } catch {
            lastError = message(for: error)
            return nil
        }
    }

    public func httpProbe(url: String) async -> HTTPProbeResult? {
        guard let endpoint else { return nil }
        do {
            return try await ControlClient(endpoint: endpoint).httpProbe(url: url)
        } catch {
            lastError = message(for: error)
            return nil
        }
    }

    public func clearError() { lastError = nil }

    // MARK: - Polling

    public func startPolling() {
        pollTask?.cancel()
        guard autoRefresh else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                if self.autoRefresh { await self.refresh() }
            }
        }
    }

    private func message(for error: Error) -> String {
        if let control = error as? ControlClientError { return control.localizedDescription }
        return error.localizedDescription
    }
}

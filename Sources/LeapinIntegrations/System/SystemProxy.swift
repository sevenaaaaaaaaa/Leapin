import Foundation
import LeapinCore

public struct SystemProxyStatus: Sendable, Hashable {
    public var enabled: Bool
    public var host: String
    public var port: Int

    public init(enabled: Bool, host: String = "", port: Int = 0) {
        self.enabled = enabled
        self.host = host
        self.port = port
    }

    public var display: String {
        enabled ? "\(host):\(port)" : "off"
    }
}

/// Reads and writes the macOS network service proxy settings via `networksetup`.
///
/// Every call is bounded by a 10 s timeout, captures stderr and surfaces failures
/// as `LeapinError`. `status()` never throws and never mutates anything.
///
/// The async API is the one to use from anything a user can see: each
/// `networksetup` spawn waits off the caller's thread, so toggling the system
/// proxy cannot freeze the window. The blocking wrappers exist for the CLI and for
/// shutdown paths that cannot await; they bridge onto the same async code.
public enum SystemProxy {
    static let networksetup = "/usr/sbin/networksetup"
    static let routeBinary = "/sbin/route"

    /// Preference order when the default route interface cannot be mapped.
    static let preferredServices = ["Wi-Fi", "USB 10/100/1000 LAN", "Ethernet", "Thunderbolt Bridge"]

    // MARK: - Blocking API

    public static func status() -> SystemProxyStatus {
        (try? bridge { await statusAsync() }) ?? SystemProxyStatus(enabled: false)
    }

    public static func status(service: String) -> SystemProxyStatus {
        (try? bridge { await statusAsync(service: service) }) ?? SystemProxyStatus(enabled: false)
    }

    public static func enable(host: String, port: Int, socksPort: Int) throws {
        try bridge { try await enableAsync(host: host, port: port, socksPort: socksPort) }
    }

    public static func disable() throws {
        try bridge { try await disableAsync() }
    }

    public static func currentService() -> String? {
        (try? bridge { await currentServiceAsync() }) ?? nil
    }

    // MARK: - Async API

    public static func statusAsync() async -> SystemProxyStatus {
        guard let service = await currentServiceAsync() else { return SystemProxyStatus(enabled: false) }
        return await statusAsync(service: service)
    }

    /// Reads the three proxy kinds for one service. Stops at the first enabled one,
    /// and costs one `networksetup` spawn per kind.
    public static func statusAsync(service: String) async -> SystemProxyStatus {
        for kind in ["webproxy", "securewebproxy", "socksfirewallproxy"] {
            guard let output = try? await CommandRunner.runAsync(executable: networksetup,
                                                                 arguments: ["-get\(kind)", service],
                                                                 timeout: 10) else { continue }
            let parsed = parseProxy(output.stdout)
            if parsed.enabled { return parsed }
        }
        return SystemProxyStatus(enabled: false)
    }

    public static func enableAsync(host: String, port: Int, socksPort: Int) async throws {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard host.isEmpty == false, (1...65535).contains(port), (1...65535).contains(socksPort) else {
            throw LeapinError.invalidConfiguration("invalid proxy host or port")
        }
        let service = try await resolveServiceAsync()
        do {
            try await runAsync(["-setwebproxy", service, host, String(port)])
            try await runAsync(["-setsecurewebproxy", service, host, String(port)])
            try await runAsync(["-setsocksfirewallproxy", service, host, String(socksPort)])
            try await runAsync(["-setwebproxystate", service, "on"])
            try await runAsync(["-setsecurewebproxystate", service, "on"])
            try await runAsync(["-setsocksfirewallproxystate", service, "on"])
            // networksetup can exit 0 while refusing the change (e.g. missing admin rights);
            // read the state back so the caller never believes a no-op succeeded.
            let state = await statusAsync(service: service)
            guard state.enabled else {
                throw LeapinError.connectionFailed("networksetup did not enable the proxy on \(service); administrator privileges may be required")
            }
        } catch {
            // A half-applied setup (HTTP proxy on, SOCKS off, or a stale host) breaks
            // every app on the machine, so never leave one behind.
            try? await disableAsync(service: service)
            throw error
        }
        LPLog.shared.info("integrations.proxy", "enabled \(host):\(port) (socks \(socksPort)) on \(service)")
    }

    public static func disableAsync() async throws {
        let service = try await resolveServiceAsync()
        try await disableAsync(service: service)
    }

    static func disableAsync(service: String) async throws {
        try await runAsync(["-setwebproxystate", service, "off"])
        try await runAsync(["-setsecurewebproxystate", service, "off"])
        try await runAsync(["-setsocksfirewallproxystate", service, "off"])
        let state = await statusAsync(service: service)
        guard state.enabled == false else {
            throw LeapinError.connectionFailed("networksetup did not disable the proxy on \(service); administrator privileges may be required")
        }
        LPLog.shared.info("integrations.proxy", "disabled on \(service)")
    }

    // MARK: - Service resolution

    /// The network service that owns the default route, falling back to the first
    /// enabled service and finally to a well-known name.
    public static func currentServiceAsync() async -> String? {
        let services = (try? await CommandRunner.runAsync(executable: networksetup,
                                                          arguments: ["-listallnetworkservices"],
                                                          timeout: 10)).map { parseServices($0.stdout) } ?? []
        if let device = await defaultRouteDeviceAsync(),
           let order = (try? await CommandRunner.runAsync(executable: networksetup,
                                                          arguments: ["-listnetworkserviceorder"],
                                                          timeout: 10)).map({ parseServiceOrder($0.stdout) }),
           let match = order.first(where: { $0.device == device }) {
            return match.service
        }
        for preferred in preferredServices where services.contains(preferred) {
            return preferred
        }
        return services.first
    }

    static func resolveServiceAsync() async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: networksetup) else {
            throw LeapinError.unsupported("\(networksetup) not found")
        }
        guard let service = await currentServiceAsync() else {
            throw LeapinError.connectionFailed("no active network service found")
        }
        return service
    }

    static func defaultRouteDeviceAsync() async -> String? {
        guard let output = try? await CommandRunner.runAsync(executable: routeBinary,
                                                             arguments: ["-n", "get", "default"],
                                                             timeout: 10) else { return nil }
        for line in output.stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                let device = trimmed.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
                return device.isEmpty ? nil : device
            }
        }
        return nil
    }

    // MARK: - Pure parsers (unit tested)

    /// `-listallnetworkservices` output; lines starting with `*` are disabled.
    static func parseServices(_ output: String) -> [String] {
        var services: [String] = []
        for line in output.components(separatedBy: .newlines) {
            var value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            if value.hasPrefix("An asterisk") || value.hasPrefix("Denotes") { continue }
            var enabled = true
            if value.hasPrefix("*") {
                enabled = false
                value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if value.isEmpty == false, enabled, services.contains(value) == false {
                services.append(value)
            }
        }
        return services
    }

    /// `-listnetworkserviceorder` output: pairs of "(1) Wi-Fi" and
    /// "(Hardware Port: Wi-Fi, Device: en0)".
    static func parseServiceOrder(_ output: String) -> [(service: String, device: String?)] {
        var result: [(service: String, device: String?)] = []
        var pending: String?
        for line in output.components(separatedBy: .newlines) {
            var value = line.trimmingCharacters(in: .whitespaces)
            guard value.isEmpty == false else { continue }
            guard value.hasPrefix("(") else { continue }
            // Both "(1) Wi-Fi" and "(Hardware Port: Wi-Fi, Device: en0)" are wrapped in parens.
            value = String(value.dropFirst())
            if value.hasSuffix(")") { value = String(value.dropLast()) }
            if value.hasPrefix("Hardware Port") {
                if let service = pending {
                    let device = value.components(separatedBy: "Device:")
                        .dropFirst().first?
                        .trimmingCharacters(in: CharacterSet(charactersIn: ") "))
                    result.append((service, device))
                }
                pending = nil
            } else if let close = value.firstIndex(of: ")") {
                // Strip the service index, e.g. "1) Wi-Fi" -> "Wi-Fi".
                let name = String(value[value.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                if name.isEmpty == false { pending = name }
            } else if value.isEmpty == false {
                pending = value
            }
        }
        return result
    }

    /// Parses `networksetup -getwebproxy` style output.
    static func parseProxy(_ output: String) -> SystemProxyStatus {
        var enabled = false
        var host = ""
        var port = 0
        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "enabled": enabled = parts[1].lowercased() == "yes"
            case "server": host = parts[1]
            case "port": port = Int(parts[1]) ?? 0
            default: break
            }
        }
        return SystemProxyStatus(enabled: enabled, host: host, port: port)
    }

    // MARK: - Execution

    static func runAsync(_ arguments: [String]) async throws {
        try await CommandRunner.runCheckedAsync(executable: networksetup, arguments: arguments, timeout: 10)
    }

    /// Runs the async implementation and blocks until it returns. Used by the CLI
    /// and by shutdown paths that cannot await; the wait happens on this thread,
    /// the work itself does not.
    private static func bridge<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached(priority: .userInitiated) {
            do { box.store(.success(try await body())) }
            catch { box.store(.failure(error)) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.load()
    }
}

/// Carries one result across the bridge above.
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?

    func store(_ value: Result<T, Error>) { lock.withLock { result = value } }

    func load() throws -> T {
        let stored = lock.withLock { result }
        guard let stored else { throw LeapinError.connectionFailed("command bridge produced no result") }
        return try stored.get()
    }
}

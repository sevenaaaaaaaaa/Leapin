import Foundation
import LeapinCore

/// Where the Mac control plane lives, plus the bearer token that unlocks it.
///
/// The token is kept in the Keychain (through `LeapinCore.Keychain`) and never in
/// UserDefaults, because it grants full control of the desktop agent.
public struct ConsoleEndpoint: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var token: String

    public init(host: String, port: Int = 7900, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }

    /// Normalises user input: trims spaces, drops a pasted http:// scheme and a
    /// trailing slash, splits `host:port` when the port came along for the ride.
    public static func parse(host rawHost: String, port rawPort: String, token rawToken: String) -> ConsoleEndpoint? {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !token.isEmpty else { return nil }

        for prefix in ["http://", "https://"] where host.lowercased().hasPrefix(prefix) {
            host = String(host.dropFirst(prefix.count))
        }
        if host.hasSuffix("/") { host = String(host.dropLast()) }

        var resolvedPort = Int(rawPort.trimmingCharacters(in: .whitespaces)) ?? 7900
        if let colon = host.lastIndex(of: ":"), host[host.index(after: colon)...].allSatisfy(\.isNumber) {
            if let embedded = Int(host[host.index(after: colon)...]), embedded > 0 {
                resolvedPort = embedded
            }
            host = String(host[..<colon])
        }
        guard !host.isEmpty, (1...65535).contains(resolvedPort) else { return nil }
        return ConsoleEndpoint(host: host, port: resolvedPort, token: token)
    }

    public var displayAddress: String { "\(host):\(port)" }

    var baseURL: URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        return components.url
    }

    func url(path: String, query: [URLQueryItem] = []) -> URL? {
        guard let base = baseURL else { return nil }
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        return components?.url
    }
}

/// Persists the endpoint across launches: address in UserDefaults, token in the Keychain.
public enum ConsoleEndpointStore {
    private static let hostKey = "leapin.mobile.control.host"
    private static let portKey = "leapin.mobile.control.port"
    private static let tokenAccount = "mobile.control.token"

    public static func load() -> ConsoleEndpoint? {
        #if DEBUG
        // Simulator QA shortcut: launch with LEAPIN_MOBILE_HOST / LEAPIN_MOBILE_TOKEN
        // to skip the pairing screen. Debug builds only; a Release build never reads it.
        if let injected = debugInjection() { return injected }
        #endif
        let defaults = UserDefaults.standard
        guard let host = defaults.string(forKey: hostKey), !host.isEmpty,
              let token = Keychain.get(account: tokenAccount), !token.isEmpty else { return nil }
        let port = defaults.object(forKey: portKey) as? Int ?? 7900
        return ConsoleEndpoint(host: host, port: port, token: token)
    }

    #if DEBUG
    private static func debugInjection() -> ConsoleEndpoint? {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["LEAPIN_MOBILE_HOST"],
              let token = environment["LEAPIN_MOBILE_TOKEN"] else { return nil }
        return ConsoleEndpoint.parse(host: host,
                                     port: environment["LEAPIN_MOBILE_PORT"] ?? "7900",
                                     token: token)
    }
    #endif

    public static func save(_ endpoint: ConsoleEndpoint) {
        let defaults = UserDefaults.standard
        defaults.set(endpoint.host, forKey: hostKey)
        defaults.set(endpoint.port, forKey: portKey)
        Keychain.set(endpoint.token, account: tokenAccount)
    }

    public static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: hostKey)
        defaults.removeObject(forKey: portKey)
        Keychain.delete(account: tokenAccount)
    }
}

import Foundation

/// The phone's public address, asked of whichever endpoint answers first.
///
/// One hardcoded endpoint (`api.ipify.org`) made the tools page — the page that is
/// supposed to work with no Mac at all — show a red error where the address belongs,
/// because that host is unreachable from a number of networks. Endpoints are tried in
/// order and the first body containing an address wins, so a network that blocks one
/// of them still gets an answer.
enum PublicAddress {
    static let endpoints = [
        "https://myip.ipip.net",   // answers `当前 IP：1.2.3.4 来自于：…`
        "https://api.ip.sb/ip",
        "https://ifconfig.me/ip",
        "https://api.ipify.org",
    ]

    /// Pulls the address out of a plain or decorated body: these endpoints answer
    /// with anything from `1.2.3.4` to a whole sentence around it.
    static func parse(_ body: String) -> String? {
        for token in body.split(whereSeparator: { !($0.isNumber || $0 == "." || $0 == ":") }) {
            if isIPv4(token) || isIPv6(token) { return String(token) }
        }
        return nil
    }

    static func fetch(timeout: TimeInterval = 6) async throws -> String {
        var failure: Error = URLError(.cannotConnectToHost)
        for raw in endpoints {
            guard let url = URL(string: raw) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let text = String(data: data, encoding: .utf8),
                      let address = parse(text) else {
                    failure = URLError(.cannotParseResponse)
                    continue
                }
                return address
            } catch {
                failure = error
            }
        }
        throw failure
    }

    private static func isIPv4(_ token: Substring) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }

    private static func isIPv6(_ token: Substring) -> Bool {
        guard token.contains(":"), token.count >= 3 else { return false }
        return token.allSatisfy { $0.isHexDigit || $0 == ":" }
    }
}

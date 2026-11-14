import Foundation
import LeapinCore
import LeapinControl

/// Transport-level failures the console surfaces to the user.
public enum ControlClientError: LocalizedError {
    case invalidAddress
    case unauthorized
    case unreachable(String)
    case server(status: Int, message: String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "地址无效，请检查 IP 与端口"
        case .unauthorized:
            return "令牌无效或已轮换，请在 Mac 上重新读取 control-token"
        case .unreachable(let detail):
            return "无法连接到 Mac：\(detail)"
        case .server(let status, let message):
            return "Mac 返回错误 \(status)：\(message)"
        case .malformedResponse:
            return "响应格式无法解析，版本可能不匹配"
        }
    }
}

/// Envelopes exactly as the control server writes them:
/// list endpoints wrap their items, single-object endpoints answer flat with `ok`.
private struct ListEnvelope<Item: Decodable>: Decodable {
    var ok: Bool?
    var count: Int?
    var items: [Item]

    private enum CodingKeys: String, CodingKey {
        case ok, count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: DynamicKey("ok"))
        count = try container.decodeIfPresent(Int.self, forKey: DynamicKey("count"))
        for key in ["connections", "policies", "records"] {
            if let decoded = try container.decodeIfPresent([Item].self, forKey: DynamicKey(key)) {
                items = decoded
                return
            }
        }
        items = []
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private struct TraceEnvelope: Decodable { var ok: Bool?; var trace: DNSTrace }
private struct ProbeEnvelope: Decodable { var ok: Bool?; var probe: HTTPProbeResult }

private struct SelectBody: Encodable { var group: String; var outbound: String }
private struct HostBody: Encodable { var host: String; var port: Int? }
private struct ProbeBody: Encodable { var url: String; var timeoutMs: Int }

private struct ErrorBody: Decodable { var ok: Bool?; var error: String?; var message: String? }

/// Thin client over the desktop agent's local action API (`/v1/...`).
public struct ControlClient {
    public let endpoint: ConsoleEndpoint
    private let session: URLSession

    public init(endpoint: ConsoleEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    // MARK: - Endpoints

    public func status() async throws -> ControlStatus {
        try await fetch(path: "/v1/status", method: "GET", as: ControlStatus.self)
    }

    public func connections(limit: Int = 50) async throws -> [ControlConnection] {
        let envelope: ListEnvelope<ControlConnection> = try await fetch(
            path: "/v1/connections", method: "GET",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            as: ListEnvelope<ControlConnection>.self)
        return envelope.items
    }

    public func policies() async throws -> [ControlPolicyGroup] {
        let envelope: ListEnvelope<ControlPolicyGroup> = try await fetch(
            path: "/v1/policies", method: "GET", as: ListEnvelope<ControlPolicyGroup>.self)
        return envelope.items
    }

    public func select(group: String, outbound: String) async throws -> ControlSelectionResult {
        try await fetch(path: "/v1/policies/select", method: "POST",
                        body: SelectBody(group: group, outbound: outbound),
                        as: ControlSelectionResult.self)
    }

    public func reload() async throws -> ControlReloadResult {
        try await fetch(path: "/v1/reload", method: "POST", as: ControlReloadResult.self)
    }

    public func explain(host: String, port: Int = 443) async throws -> ControlExplainResult {
        try await fetch(path: "/v1/explain", method: "POST",
                        body: HostBody(host: host, port: port),
                        as: ControlExplainResult.self)
    }

    public func dnsTrace(host: String) async throws -> DNSTrace {
        let envelope: TraceEnvelope = try await fetch(path: "/v1/dns/trace", method: "POST",
                                                      body: HostBody(host: host, port: nil),
                                                      as: TraceEnvelope.self)
        return envelope.trace
    }

    public func httpProbe(url: String, timeoutMs: Int = 10_000) async throws -> HTTPProbeResult {
        let envelope: ProbeEnvelope = try await fetch(path: "/v1/http/probe", method: "POST",
                                                      body: ProbeBody(url: url, timeoutMs: timeoutMs),
                                                      as: ProbeEnvelope.self)
        return envelope.probe
    }

    // MARK: - Transport

    private func fetch<T: Decodable>(path: String, method: String,
                                     query: [URLQueryItem] = [],
                                     body: (any Encodable)? = nil,
                                     as type: T.Type) async throws -> T {
        guard let url = endpoint.url(path: path, query: query) else {
            throw ControlClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ControlClientError.unreachable(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let decoded = try? JSONDecoder().decode(ErrorBody.self, from: data)
            if http.statusCode == 401 { throw ControlClientError.unauthorized }
            throw ControlClientError.server(status: http.statusCode,
                                            message: decoded?.message ?? decoded?.error ?? "HTTP \(http.statusCode)")
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ControlClientError.malformedResponse
        }
    }
}

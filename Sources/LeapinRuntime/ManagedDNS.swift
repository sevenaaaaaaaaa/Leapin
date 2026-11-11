import Foundation
import LeapinCore

public extension LeapinEngine {
    func managedDNSTrace(_ host: String) async throws -> DNSTrace {
        let started = Date()
        let profileID = profile.id
        let port = managedKernel.proxyPort
        guard let encoded = host.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw LeapinError.invalidConfiguration("域名无效")
        }
        var addresses: [String] = []
        var ttl: Int?
        for type in ["A", "AAAA"] {
            let data = try await managedKernel.request("dns/query?name=\(encoded)&type=\(type)", timeout: 6)
            guard profile.id == profileID, managedKernel.proxyPort == port else { throw LeapinError.connectionFailed("检查期间内核已切换") }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let status = object["Status"] as? Int else {
                throw LeapinError.protocolError("内核未返回 DNS 状态")
            }
            guard status == 0 else {
                return DNSTrace(host: host, source: .failed, upstream: "Mihomo 来源 DNS 策略", elapsedMs: Date().timeIntervalSince(started) * 1000,
                    error: "Mihomo DNS 返回状态 \(status)（\(type)）")
            }
            for answer in object["Answer"] as? [[String: Any]] ?? [] {
                if [1, 28].contains(answer["type"] as? Int ?? 0), let value = answer["data"] as? String {
                    addresses.append(value)
                    if let value = answer["TTL"] as? Int { ttl = min(ttl ?? value, value) }
                }
            }
        }
        return DNSTrace(host: host, source: addresses.isEmpty ? .failed : .upstream, resolved: addresses,
            upstream: "Mihomo 来源 DNS 策略", elapsedMs: Date().timeIntervalSince(started) * 1000, cacheTTL: ttl,
            steps: [DNSTraceStep(stage: "kernel", detail: "由运行中的 Mihomo 解析；返回值可能是 fake-IP，不等于真实出口 IP")],
            error: addresses.isEmpty ? "内核没有返回 A / AAAA 地址" : nil)
    }
}

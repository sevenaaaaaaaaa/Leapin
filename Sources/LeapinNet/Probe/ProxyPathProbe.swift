import Foundation
import CFNetwork
import LeapinCore

/// A HEAD request through the explicit local HTTP proxy. Unlike HTTPProbe this
/// verifies the proxy path; callers label the method and do not infer page usability.
public enum ProxyPathProbe {
    public static func probe(_ origin: String, port: UInt16) async -> HTTPProbeResult {
        let started = Date()
        var result = HTTPProbeResult(url: origin)
        guard let url = URL(string: origin), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, port > 0 else { result.error = "测试地址或端口无效"; return result }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // iOS marks the HTTPS proxy keys unavailable, but its HTTP proxy already
        // tunnels https:// originals through CONNECT, so one entry covers both.
        var proxy: [AnyHashable: Any] = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: Int(port),
        ]
        #if os(macOS)
        proxy[kCFNetworkProxiesHTTPSEnable as String] = 1
        proxy[kCFNetworkProxiesHTTPSProxy as String] = "127.0.0.1"
        proxy[kCFNetworkProxiesHTTPSPort as String] = Int(port)
        #endif
        config.connectionProxyDictionary = proxy
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LeapinError.protocolError("未收到 HTTP 响应") }
            result.statusCode = http.statusCode
            result.tls = url.scheme?.lowercased() == "https"
        } catch { result.error = Redactor.redact(error.localizedDescription) }
        result.elapsedMs = Date().timeIntervalSince(started) * 1000
        return result
    }
}

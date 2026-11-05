import Foundation
import Network
import TouchFlowCore

/// Terminates TLS for CONNECT requests that match `options.mitmHosts`, parses
/// HTTP/1.1, forwards each request to the origin (direct, plain or TLS) and
/// reports the exchange to the capture sink.
///
/// Implementation note: Network.framework cannot upgrade an accepted plain TCP
/// connection to TLS, so the client socket is bridged byte-for-byte into a
/// loopback TLS listener owned by `LocalTLSServer`. The decrypted stream is then
/// handled as ordinary HTTP.
///
/// Only HTTP/1.1 is offered via ALPN; HTTP/2 clients cannot be terminated here.
final class MITMHandler: @unchecked Sendable {
    private let ca: CertificateAuthority
    private let blocker: DomainBlocking?
    private let capture: CaptureSink?
    private let dialer: OutboundDialer
    private let connectHost: String
    private let connectPort: UInt16
    private let outbound: OutboundConfig
    private let sourceApp: String?
    private let sourcePID: Int32?
    private let idleTimeout: TimeInterval

    init(ca: CertificateAuthority,
         blocker: DomainBlocking?,
         capture: CaptureSink?,
         dialer: OutboundDialer,
         connectHost: String,
         connectPort: UInt16,
         outbound: OutboundConfig,
         sourceApp: String?,
         sourcePID: Int32?,
         idleTimeout: TimeInterval = 300) {
        self.ca = ca
        self.blocker = blocker
        self.capture = capture
        self.dialer = dialer
        self.connectHost = connectHost
        self.connectPort = connectPort
        self.outbound = outbound
        self.sourceApp = sourceApp
        self.sourcePID = sourcePID
        self.idleTimeout = idleTimeout
    }

    /// Runs the MITM session; returns when the client or origin is done.
    func run(client: NetSocket) async {
        let identity: sec_identity_t
        do {
            identity = try ca.identity(for: connectHost)
        } catch {
            TFLog.shared.error("net.mitm",
                "no certificate for \(connectHost): \(error.localizedDescription); refusing MITM")
            await writePlainError(client, status: 502, message: "TouchFlow cannot mint a certificate for \(connectHost)")
            client.close()
            return
        }

        var server: LocalTLSServer?
        var loopback: NetSocket?
        var tlsSocket: NetSocket?
        var flushSignal: FlushSignal?
        do {
            try await client.write(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))

            let listener = try await LocalTLSServer.start(identity: identity, alpn: ["http/1.1"])
            server = listener
            let bridge = try await NetSocket.connect(host: "127.0.0.1",
                                                     port: listener.port,
                                                     timeout: 5,
                                                     tls: nil)
            loopback = bridge
            // Pipe raw client TLS records into the loopback TLS listener.
            let flush = FlushSignal()
            Task.detached(priority: .utility) {
                let stats = await BytePump.run(client, bridge, idleTimeout: self.idleTimeout)
                flush.signal()
                TFLog.shared.debug("net.mitm",
                    "bridge closed for \(self.connectHost): in=\(stats.bytesIn) out=\(stats.bytesOut) idle=\(stats.idleTimedOut)")
            }
            flushSignal = flush

            let decrypted = try await listener.accept(timeout: 10)
            tlsSocket = decrypted
            TFLog.shared.info("net.mitm", "TLS established for \(connectHost):\(connectPort)")
            try await serve(tls: decrypted)
        } catch {
            TFLog.shared.warn("net.mitm",
                "mitm for \(connectHost):\(connectPort) ended: \(error.localizedDescription)")
        }

        // Graceful teardown: `NetSocket.close()` cancels the underlying connection,
        // which discards TLS records that are still buffered. Half-close the
        // terminator first so its close_notify (and any pending response) is flushed
        // through the loopback bridge, then give the bridge pump a bounded window to
        // hand those bytes to the client before the sockets are torn down.
        if let terminator = tlsSocket, let half = terminator as WriteHalfClosable? { half.closeWrite() }
        if let flushSignal {
            let deadline = Date().addingTimeInterval(2)
            while !flushSignal.isSignaled, Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        tlsSocket?.close()
        loopback?.close()
        server?.close()
        client.close()
    }

    // MARK: - HTTP/1.1 loop

    private func serve(tls: NetSocket) async throws {
        let stream = BufferedStream(tls)
        while true {
            guard let request = try await HTTPCodec.readRequestHead(stream) else {
                TFLog.shared.debug("net.mitm", "client closed HTTP session for \(connectHost)")
                return
            }
            TFLog.shared.debug("net.mitm", "request \(request.method) \(request.target) for \(connectHost)")
            let framing = try HTTPCodec.framing(for: request.headers, isRequest: true)
            let requestBody = try await HTTPCodec.readBody(stream, framing: framing)

            let wantsClose = (request.headers.first("Connection") ?? "").lowercased().contains("close")
            let handled = try await handle(request: request, body: requestBody, out: tls, connectionClose: wantsClose)
            if wantsClose || !handled {
                return
            }
        }
    }

    private struct Target {
        let host: String
        let port: UInt16
        let scheme: String
        let path: String

        var url: String {
            let defaultPort = scheme == "https" ? 443 : 80
            let authority = port == UInt16(defaultPort) ? host : "\(host):\(port)"
            return "\(scheme)://\(authority)\(path)"
        }
    }

    private func target(for request: HTTPRequestHead) -> Target {
        let raw = request.target
        if let schemeRange = raw.range(of: "://") {
            let scheme = String(raw[raw.startIndex..<schemeRange.lowerBound]).lowercased()
            let rest = String(raw[schemeRange.upperBound...])
            let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" } ?? rest.endIndex
            let authority = String(rest[rest.startIndex..<authorityEnd])
            var path = String(rest[authorityEnd...])
            if path.isEmpty { path = "/" }
            if !path.hasPrefix("/") { path = "/" + path }
            let defaultPort: UInt16 = scheme == "https" ? 443 : 80
            if let parsed = NetAddress.parseAuthority(authority, defaultPort: defaultPort) {
                return Target(host: parsed.host, port: parsed.port, scheme: scheme, path: path)
            }
        }
        let hostHeader = request.headers.first("Host") ?? connectHost
        let parsed = NetAddress.parseAuthority(hostHeader, defaultPort: connectPort)
        let host = parsed?.host ?? connectHost
        let port = parsed?.port ?? connectPort
        let scheme = port == 443 ? "https" : "http"
        let path = HTTPCodec.originFormTarget(raw)
        return Target(host: host, port: port, scheme: scheme, path: path)
    }

    /// Returns false when the connection should be closed after this exchange.
    @discardableResult
    private func handle(request: HTTPRequestHead, body: Data, out: NetSocket, connectionClose: Bool = false) async throws -> Bool {
        let target = self.target(for: request)
        let started = Date()

        if let blocker, let verdict = blocker.verdict(for: target.host, path: target.path, thirdParty: false) as BlockVerdict?, verdict.blocked {
            let reason = verdict.reason ?? "blocked"
            TFLog.shared.info("net.mitm", "blocked \(request.method) \(target.url): \(reason)")
            let payload = Data("TouchFlow blocked this request: \(reason)".utf8)
            var headers = HTTPHeaders()
            headers.set("Content-Type", "text/plain; charset=utf-8")
            headers.set("Content-Length", String(payload.count))
            headers.set("Connection", "close")
            let head = HTTPResponseHead(status: 403, reason: "Forbidden", headers: headers)
            var outData = head.serialized
            outData.append(payload)
            try await out.write(outData)
            capture?.capture(CapturedRequest(
                method: request.method,
                url: target.url,
                host: target.host,
                requestHeaders: HTTPCodec.stripHopByHop(request.headers).dictionary,
                requestBody: body.isEmpty ? nil : body,
                statusCode: 403,
                responseHeaders: headers.dictionary,
                responseBody: payload,
                mimeType: "text/plain",
                durationMs: elapsedMs(since: started),
                sourceApp: sourceApp,
                blocked: true))
            return false
        }

        let upstream: ByteStream
        do {
            upstream = try await openUpstream(target)
        } catch {
            TFLog.shared.warn("net.mitm", "upstream \(target.host):\(target.port) failed: \(error.localizedDescription)")
            try await writePlainResponse(out, status: 502, reason: "Bad Gateway",
                                         message: "TouchFlow could not reach \(target.host):\(target.port)")
            return false
        }

        defer { upstream.close() }

        TFLog.shared.debug("net.mitm", "upstream open for \(target.url)")
        let upstreamStream = BufferedStream(upstream)
        var upHeaders = HTTPCodec.stripHopByHop(request.headers)
        upHeaders.remove("Proxy-Authorization")
        upHeaders.set("Host", target.port == (target.scheme == "https" ? 443 : 80) ? target.host : "\(target.host):\(target.port)")
        var payload = body
        _ = HTTPCodec.serialize(body: payload, headers: &upHeaders)
        if request.method.uppercased() == "HEAD" {
            upHeaders.remove("Content-Length")
            payload = Data()
        }
        let forwarded = HTTPRequestHead(method: request.method, target: target.path, headers: upHeaders)
        var requestBytes = forwarded.serialized()
        requestBytes.append(payload)
        try await upstream.write(requestBytes)

        TFLog.shared.debug("net.mitm", "request forwarded for \(target.url)")
        guard let response = try await HTTPCodec.readResponseHead(upstreamStream) else {
            TFLog.shared.warn("net.mitm", "origin closed without a response: \(target.url)")
            try await writePlainResponse(out, status: 502, reason: "Bad Gateway", message: "empty origin response")
            return false
        }

        TFLog.shared.debug("net.mitm", "response head \(response.status) for \(target.url)")
        let responseBody = try await readResponseBody(response, request: request, stream: upstreamStream)
        let mimeType = response.headers.first("Content-Type")
        let isHTML = (mimeType ?? "").lowercased().contains("text/html")
        let isIdentity = (response.headers.first("Content-Encoding")?.lowercased() ?? "identity") == "identity"

        var deliveredBody = responseBody
        let selectors = isHTML ? (blocker?.cosmeticSelectors(for: target.host) ?? []) : []
        if !selectors.isEmpty, isIdentity {
            deliveredBody = Self.injectCosmeticStyle(into: responseBody, selectors: selectors)
            TFLog.shared.debug("net.mitm",
                "injected \(selectors.count) cosmetic selector(s) into \(target.url)")
        }

        var responseHeaders = HTTPCodec.stripHopByHop(response.headers)
        if request.method.uppercased() != "HEAD", !(isHTML && !selectors.isEmpty && !isIdentity) {
            _ = HTTPCodec.serialize(body: deliveredBody, headers: &responseHeaders)
        }
        responseHeaders.set("Connection", connectionClose ? "close" : "keep-alive")
        let head = HTTPResponseHead(status: response.status, reason: response.reason, headers: responseHeaders)
        var outData = head.serialized
        outData.append(deliveredBody)
        TFLog.shared.debug("net.mitm", "writing \(outData.count) bytes for \(target.url)")
        try await out.write(outData)
        TFLog.shared.debug("net.mitm", "wrote \(outData.count) bytes for \(target.url)")

        capture?.capture(CapturedRequest(
            method: request.method,
            url: target.url,
            host: target.host,
            requestHeaders: upHeaders.dictionary,
            requestBody: body.isEmpty ? nil : body,
            statusCode: response.status,
            responseHeaders: responseHeaders.dictionary,
            responseBody: deliveredBody.isEmpty ? nil : deliveredBody,
            mimeType: mimeType,
            durationMs: elapsedMs(since: started),
            sourceApp: sourceApp,
            blocked: false))
        return true
    }

    private func readResponseBody(_ response: HTTPResponseHead,
                                  request: HTTPRequestHead,
                                  stream: BufferedStream) async throws -> Data {
        if request.method.uppercased() == "HEAD" { return Data() }
        if response.status == 204 || response.status == 304 || (100..<200).contains(response.status) {
            return Data()
        }
        let hasLength = response.headers.contains("Content-Length")
        let hasTransfer = response.headers.contains("Transfer-Encoding")
        if !hasLength && !hasTransfer {
            // Origin will close the connection to delimit the body.
            var body = Data()
            while let chunk = try await stream.readSome(maxLength: 16 * 1024) {
                body.append(chunk)
                if body.count > HTTPCodec.bodyLimit {
                    throw TouchFlowError.protocolError("mitm: response body exceeds limit")
                }
            }
            return body
        }
        let framing = try HTTPCodec.framing(for: response.headers, isRequest: false)
        return try await HTTPCodec.readBody(stream, framing: framing)
    }

    private func openUpstream(_ target: Target) async throws -> ByteStream {
        let useTLS = target.scheme == "https" || target.port == 443
        if outbound.type == .direct {
            let tls = useTLS ? TLSFactory.clientOptions(serverName: target.host) : nil
            return try await NetSocket.connect(host: target.host, port: target.port, timeout: 10, tls: tls)
        }
        // A CONNECT tunnel cannot be upgraded to TLS after the fact, so proxy
        // outbounds are bypassed for MITM'd HTTPS; logged for the UI/诊断.
        TFLog.shared.warn("net.mitm",
            "outbound \(outbound.name) (\(outbound.type.rawValue)) bypassed for MITM: origin \(target.host):\(target.port) dialed directly")
        let tls = useTLS ? TLSFactory.clientOptions(serverName: target.host) : nil
        return try await NetSocket.connect(host: target.host, port: target.port, timeout: 10, tls: tls)
    }

    // MARK: - Helpers

    static func injectCosmeticStyle(into html: Data, selectors: [String]) -> Data {
        guard !selectors.isEmpty else { return html }
        let css = selectors.joined(separator: ",\n") + " { display: none !important; }"
        let style = "<style id=\"touchflow-cosmetic-hide\">\(css)</style>"
        var text = String(decoding: html, as: UTF8.self)
        if let headEnd = text.range(of: "</head>", options: .caseInsensitive) {
            text.insert(contentsOf: style, at: headEnd.lowerBound)
        } else if let bodyStart = text.range(of: "<body", options: .caseInsensitive) {
            text.insert(contentsOf: style, at: bodyStart.lowerBound)
        } else {
            text = style + text
        }
        return Data(text.utf8)
    }

    private func writePlainResponse(_ out: NetSocket,
                                    status: Int,
                                    reason: String,
                                    message: String) async throws {
        let payload = Data(message.utf8)
        var headers = HTTPHeaders()
        headers.set("Content-Type", "text/plain; charset=utf-8")
        headers.set("Content-Length", String(payload.count))
        headers.set("Connection", "close")
        var data = HTTPResponseHead(status: status, reason: reason, headers: headers).serialized
        data.append(payload)
        try await out.write(data)
    }

    private func writePlainError(_ client: NetSocket, status: Int, message: String) async {
        let payload = Data(message.utf8)
        var headers = HTTPHeaders()
        headers.set("Content-Type", "text/plain; charset=utf-8")
        headers.set("Content-Length", String(payload.count))
        headers.set("Connection", "close")
        var data = HTTPResponseHead(status: status, reason: HTTPStatusText.reason(for: status), headers: headers).serialized
        data.append(payload)
        do {
            try await client.write(data)
        } catch {
            TFLog.shared.debug("net.mitm", "could not write plain error: \(error.localizedDescription)")
        }
    }

    private func elapsedMs(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }
}

/// One-shot flag used to observe the bridge pump finishing (flush-on-teardown).
final class FlushSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false

    var isSignaled: Bool { lock.withLock { signaled } }

    func signal() { lock.withLock { signaled = true } }
}

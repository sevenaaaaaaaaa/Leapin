import Foundation
import Network
import Security
import XCTest
@testable import TouchFlowCore
@testable import TouchFlowNet

/// Certificate authority, HAR export and MITM tests.
///
/// The MITM test tunnels a real TLS client through a plain relay into the proxy,
/// so the whole chain is exercised: CONNECT → minted leaf → TLS termination →
/// HTTP/1.1 parsing → upstream forward → cosmetic injection → capture.
final class CaptureTests: XCTestCase {
    // MARK: - Certificate authority

    func testCertificateAuthorityMintsCAAndLeafIdentity() throws {
        let directory = try makeTempDirectory("ca")
        defer { try? FileManager.default.removeItem(at: directory) }

        let ca = try CertificateAuthority(directory: directory)
        XCTAssertEqual(ca.caCertificateURL.lastPathComponent, "ca.pem")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ca.caCertificateURL.path))

        let caData = try Data(contentsOf: ca.caCertificateURL)
        XCTAssertFalse(caData.isEmpty)
        XCTAssertTrue(String(decoding: caData.prefix(64), as: UTF8.self).contains("-----BEGIN CERTIFICATE-----"),
                      "caCertificateURL must be an installable PEM certificate")
        XCTAssertNotNil(try derCertificate(forPEM: ca.caCertificateURL), "CA must be a parseable X.509 certificate")

        let caText = try openssl(["x509", "-noout", "-text", "-in", ca.caCertificateURL.path])
        XCTAssertTrue(caText.contains("CA:TRUE"), "CA certificate must carry basicConstraints CA:TRUE")
        XCTAssertTrue(caText.contains("TouchFlow"))

        let identity = try ca.identity(for: "mitm.test")
        XCTAssertNotNil(sec_identity_copy_ref(identity), "identity must wrap a SecIdentity")

        let leafURL = ca.leafCertificateURL(for: "mitm.test")
        XCTAssertTrue(FileManager.default.fileExists(atPath: leafURL.path))
        let leafText = try openssl(["x509", "-noout", "-text", "-in", leafURL.path])
        XCTAssertTrue(leafText.contains("DNS:mitm.test"), "leaf must carry a SAN for the host")
        XCTAssertTrue(leafText.contains("CA:FALSE"))
        // Leaf must be signed by our CA (issuer subject matches the CA subject).
        XCTAssertTrue(leafText.contains("TouchFlow"))

        let p12 = leafURL.deletingLastPathComponent().appendingPathComponent("leaf.p12")
        XCTAssertTrue(FileManager.default.fileExists(atPath: p12.path), "p12 bundle is needed for SecPKCS12Import")
        let p12Size = (try? Data(contentsOf: p12).count) ?? 0
        XCTAssertGreaterThan(p12Size, 0)
    }

    func testCertificateAuthorityHandlesIPHosts() throws {
        let directory = try makeTempDirectory("ca-ip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ca = try CertificateAuthority(directory: directory)
        _ = try ca.identity(for: "127.0.0.1")
        let leafText = try openssl(["x509", "-noout", "-text", "-in", ca.leafCertificateURL(for: "127.0.0.1").path])
        XCTAssertTrue(leafText.contains("IP Address:127.0.0.1"), "IP SAN required for MITM of IP literals")
    }

    func testCertificateAuthorityReusesCAAndCachesLeaves() throws {
        let directory = try makeTempDirectory("ca-cache")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try CertificateAuthority(directory: directory)
        let firstData = try Data(contentsOf: first.caCertificateURL)
        _ = try first.identity(for: "cached.test")
        let leafURL = first.leafCertificateURL(for: "cached.test")
        let firstLeaf = try Data(contentsOf: leafURL)

        let second = try CertificateAuthority(directory: directory)
        let secondData = try Data(contentsOf: second.caCertificateURL)
        XCTAssertEqual(firstData, secondData, "existing CA must be reused, not regenerated")

        _ = try second.identity(for: "cached.test")
        let secondLeaf = try Data(contentsOf: leafURL)
        XCTAssertEqual(firstLeaf, secondLeaf, "leaf certificates must be cached per host")
    }

    // MARK: - HAR export

    func testHARExportShapeAndRedaction() throws {
        let requests = [
            CapturedRequest(method: "GET",
                            url: "https://example.test/page?a=1",
                            host: "example.test",
                            requestHeaders: ["Host": "example.test",
                                             "Authorization": "Bearer super-secret-token",
                                             "Cookie": "session=abc123",
                                             "Accept": "text/html"],
                            statusCode: 200,
                            responseHeaders: ["Content-Type": "text/html; charset=utf-8",
                                              "Set-Cookie": "session=def456",
                                              "Cache-Control": "no-store"],
                            responseBody: Data("<html>hi</html>".utf8),
                            mimeType: "text/html",
                            durationMs: 42,
                            sourceApp: "Safari"),
            CapturedRequest(method: "POST",
                            url: "https://api.example.test/v1/items",
                            host: "api.example.test",
                            requestHeaders: ["Content-Type": "application/json"],
                            requestBody: Data("{\"name\":\"x\"}".utf8),
                            statusCode: 201,
                            responseHeaders: ["Content-Type": "application/json"],
                            responseBody: Data("{\"id\":1}".utf8),
                            mimeType: "application/json",
                            durationMs: 17,
                            blocked: false)
        ]

        let data = try HARExporter.export(requests, redact: true)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let log = try XCTUnwrap(root["log"] as? [String: Any])
        XCTAssertEqual(log["version"] as? String, "1.2")
        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)

        let first = entries[0]
        XCTAssertEqual(first["startedDateTime"] as? String != nil, true)
        let request = try XCTUnwrap(first["request"] as? [String: Any])
        XCTAssertEqual(request["method"] as? String, "GET")
        XCTAssertEqual(request["url"] as? String, "https://example.test/page?a=1")
        let requestHeaders = try XCTUnwrap(request["headers"] as? [[String: Any]])
        let authorization = requestHeaders.first { ($0["name"] as? String)?.lowercased() == "authorization" }
        XCTAssertNotNil(authorization, "header entry should still be present")
        let authValue = (authorization?["value"] as? String) ?? ""
        XCTAssertFalse(authValue.contains("super-secret-token"), "authorization value must be redacted, got \(authValue)")
        let cookie = requestHeaders.first { ($0["name"] as? String)?.lowercased() == "cookie" }
        XCTAssertFalse(((cookie?["value"] as? String) ?? "").contains("abc123"))

        let response = try XCTUnwrap(first["response"] as? [String: Any])
        XCTAssertEqual(response["status"] as? Int, 200)
        let responseHeaders = try XCTUnwrap(response["headers"] as? [[String: Any]])
        let setCookie = responseHeaders.first { ($0["name"] as? String)?.lowercased() == "set-cookie" }
        XCTAssertFalse(((setCookie?["value"] as? String) ?? "").contains("def456"))

        let content = try XCTUnwrap(response["content"] as? [String: Any])
        XCTAssertEqual(content["text"] as? String, "<html>hi</html>")
        XCTAssertEqual(content["mimeType"] as? String, "text/html")
        XCTAssertEqual(response["bodySize"] as? Int, "<html>hi</html>".utf8.count)

        let second = try XCTUnwrap(entries[1]["request"] as? [String: Any])
        XCTAssertEqual(second["method"] as? String, "POST")
        let postData = try XCTUnwrap(second["postData"] as? [String: Any])
        XCTAssertEqual(postData["text"] as? String, "{\"name\":\"x\"}")
    }

    func testLargeBodiesAreRedactedWithLinearScan() throws {
        // Longer than the regex path allows, so the linear scanner handles it.
        var payload = String(repeating: "a", count: HARExporter.redactionBodyLimit + 1024)
        payload += " password=hunter2&token=abc123\nAuthorization: Bearer leak-me\n"
        let request = CapturedRequest(method: "GET",
                                      url: "https://big.test/app.js",
                                      host: "big.test",
                                      requestHeaders: [:],
                                      statusCode: 200,
                                      responseHeaders: ["Content-Type": "text/plain"],
                                      responseBody: Data(payload.utf8),
                                      mimeType: "text/plain",
                                      durationMs: 5)
        let data = try HARExporter.export([request], redact: true)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let log = try XCTUnwrap(root["log"] as? [String: Any])
        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        let response = try XCTUnwrap(entries.first?["response"] as? [String: Any])
        let content = try XCTUnwrap(response["content"] as? [String: Any])
        let text = try XCTUnwrap(content["text"] as? String)
        XCTAssertFalse(text.contains("hunter2"), "password value must be masked")
        XCTAssertFalse(text.contains("abc123"), "token value must be masked")
        XCTAssertFalse(text.contains("leak-me"), "authorization value must be masked")
        XCTAssertTrue(text.contains("<redacted>"))
        XCTAssertTrue(text.contains(String(repeating: "a", count: 64)), "payload must survive masking")
    }

    func testHARExportKeepsSecretsWhenRedactionDisabled() throws {
        let request = CapturedRequest(method: "GET",
                                      url: "https://example.test/",
                                      host: "example.test",
                                      requestHeaders: ["Authorization": "Bearer keep-me"],
                                      statusCode: 200,
                                      responseHeaders: [:],
                                      durationMs: 1)
        let data = try HARExporter.export([request], redact: false)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("keep-me"), "redact: false must not touch header values")
    }

    func testHARExportTruncatesBodiesLargerThanOneMegabyte() throws {
        let big = Data(repeating: 0x41, count: HARExporter.maxBodyBytes + 4096)
        let request = CapturedRequest(method: "GET",
                                      url: "https://big.test/blob",
                                      host: "big.test",
                                      requestHeaders: [:],
                                      statusCode: 200,
                                      responseHeaders: ["Content-Type": "text/plain"],
                                      responseBody: big,
                                      mimeType: "text/plain",
                                      durationMs: 3)
        let data = try HARExporter.export([request], redact: true)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let log = try XCTUnwrap(root["log"] as? [String: Any])
        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        let response = try XCTUnwrap(entries.first?["response"] as? [String: Any])
        let content = try XCTUnwrap(response["content"] as? [String: Any])
        let text = try XCTUnwrap(content["text"] as? String)
        XCTAssertEqual(text.utf8.count, HARExporter.maxBodyBytes, "body text must be truncated to the cap")
        XCTAssertEqual(content["size"] as? Int, big.count, "content.size keeps the original size")
        XCTAssertNotNil(content["comment"], "truncation must be annotated")
        XCTAssertEqual(response["bodySize"] as? Int, big.count)
    }

    func testHARExportMarksBlockedRequests() throws {
        let request = CapturedRequest(method: "GET",
                                      url: "https://ads.test/banner.js",
                                      host: "ads.test",
                                      statusCode: nil,
                                      durationMs: 0,
                                      blocked: true)
        let data = try HARExporter.export([request], redact: true)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let log = try XCTUnwrap(root["log"] as? [String: Any])
        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        let response = try XCTUnwrap(entries.first?["response"] as? [String: Any])
        XCTAssertEqual(response["status"] as? Int, 403)
        XCTAssertEqual(response["statusText"] as? String, "Blocked")
    }

    // MARK: - MITM end to end

    /// Isolates the loopback TLS bridge from the proxy/relay plumbing.
    func testLocalTLSServerCompletesHandshakeWithCAIdentity() async throws {
        let directory = try makeTempDirectory("tls-bridge")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ca = try CertificateAuthority(directory: directory)
        let identity = try ca.identity(for: "127.0.0.1")
        let listener = try await LocalTLSServer.start(identity: identity, alpn: ["http/1.1"])
        defer { listener.close() }

        let caCertificate = try derCertificate(forPEM: ca.caCertificateURL)
        let tls = TLSFactory.clientOptions(serverName: "127.0.0.1", alpn: ["http/1.1"], customVerify: { trust in
            SecTrustSetAnchorCertificates(trust, [caCertificate] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            var error: CFError?
            return SecTrustEvaluateWithError(trust, &error)
        })

        async let accepted = listener.accept(timeout: 15)
        let client = try await NetSocket.connect(host: "127.0.0.1", port: listener.port, timeout: 15, tls: tls)
        defer { client.close() }
        let server = try await accepted
        defer { server.close() }

        try await client.write(Data("ping".utf8))
        let echoed = try await BufferedStream(server).readExactly(4)
        XCTAssertEqual(String(decoding: echoed, as: UTF8.self), "ping")
    }

    func testMITMTerminatesTLSInjectsCosmeticAndCaptures() async throws {
        let html = "<html><head><title>t</title></head><body><div class=\"ad-slot\">ad</div><p>keep</p></body></html>"
        let origin = try await HTTPOriginServer.start(mode: .html(html))
        let directory = try makeTempDirectory("mitm")
        defer { try? FileManager.default.removeItem(at: directory) }

        let ca = try CertificateAuthority(directory: directory)
        let blocker = StaticBlocker(selectors: ["127.0.0.1": [".ad-slot", "#banner"]])
        let flows = FlowCollector()
        let capture = CaptureCollector()
        let server = ProxyServer(options: ProxyServer.Options(port: 0,
                                                             allowLAN: false,
                                                             enableSOCKS5: true,
                                                             enableHTTP: true,
                                                             mitm: true,
                                                             mitmHosts: ["*"]),
                                 router: StaticRouter(fallback: .direct),
                                 resolver: MapResolver([:]),
                                 blocker: blocker,
                                 flows: flows,
                                 capture: capture,
                                 ca: ca)
        try server.start()
        defer { server.stop() }

        // A plain relay forwards the CONNECT handshake and then raw TLS records,
        // mirroring what a browser does after a CONNECT tunnel is established.
        let connectHead = Data("CONNECT 127.0.0.1:\(origin.port) HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n".utf8)
        let (relayListener, relayPort) = try await startRelay(proxyPort: server.listeningPort, preamble: connectHead)
        defer { relayListener.cancel() }

        let caCertificate = try derCertificate(forPEM: ca.caCertificateURL)
        let tls = TLSFactory.clientOptions(serverName: "127.0.0.1", alpn: ["http/1.1"], customVerify: { trust in
            SecTrustSetAnchorCertificates(trust, [caCertificate] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            var error: CFError?
            return SecTrustEvaluateWithError(trust, &error)
        })

        let socket = try await NetSocket.connect(host: "127.0.0.1", port: relayPort, timeout: 10, tls: tls)
        defer { socket.close() }
        let stream = BufferedStream(socket)
        try await stream.write(Data("GET /page HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\nConnection: close\r\n\r\n".utf8))

        let peek = try await stream.readSome(maxLength: 4096)
        if let peek { stream.pushBack(peek) }

        let head = try await HTTPCodec.readResponseHead(stream)
        let response = try XCTUnwrap(head, "MITM must answer the request")
        XCTAssertEqual(response.status, 200)
        let framing = try HTTPCodec.framing(for: response.headers, isRequest: false)
        let body = try await HTTPCodec.readBody(stream, framing: framing)
        let bodyText = String(decoding: body, as: UTF8.self)

        XCTAssertTrue(bodyText.contains("touchflow-cosmetic-hide"),
                      "text/html responses must get the cosmetic hiding style, got: \(bodyText)")
        XCTAssertTrue(bodyText.contains(".ad-slot"))
        XCTAssertTrue(bodyText.contains("#banner"))
        XCTAssertTrue(bodyText.contains("<p>keep</p>"), "original markup must survive injection")

        let captured = await capture.waitFor(count: 1)
        XCTAssertTrue(captured, "MITM must record the request in the capture sink")
        let request = try XCTUnwrap(capture.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.statusCode, 200)
        XCTAssertEqual(request.host, "127.0.0.1")
        XCTAssertTrue(request.url.contains("/page"))
        XCTAssertEqual(request.mimeType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) },
                       "text/html")
        let capturedBody = String(decoding: request.responseBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(capturedBody.contains("touchflow-cosmetic-hide"))
        XCTAssertNotNil(request.durationMs)
    }

    func testMITMIsNotUsedForUnmatchedHosts() async throws {
        let origin = try await HTTPOriginServer.start(mode: .echo)
        let directory = try makeTempDirectory("mitm-skip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ca = try CertificateAuthority(directory: directory)
        let server = ProxyServer(options: ProxyServer.Options(port: 0, mitm: true, mitmHosts: ["*.only-here.test"]),
                                 router: StaticRouter(fallback: .direct),
                                 resolver: MapResolver([:]),
                                 blocker: nil,
                                 flows: FlowCollector(),
                                 capture: CaptureCollector(),
                                 ca: ca)
        try server.start()
        defer { server.stop() }

        let socket = try await NetSocket.connect(host: "127.0.0.1", port: server.listeningPort, timeout: 5, tls: nil)
        defer { socket.close() }
        let stream = BufferedStream(socket)
        try await stream.write(Data("CONNECT 127.0.0.1:\(origin.port) HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n".utf8))
        let head = try await HTTPCodec.readResponseHead(stream)
        XCTAssertEqual(head?.status, 200)
        // Plain tunnel: no TLS, so a plain GET must reach the origin.
        try await stream.write(Data("GET /plain HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8))
        let response = try await HTTPCodec.readResponseHead(stream)
        XCTAssertEqual(response?.status, 200)
    }

    // MARK: - Helpers

    /// Starts a plain TCP relay: accepts a client, opens the CONNECT handshake
    /// against the proxy, swallows the `200 Connection Established` reply and
    /// then pumps bytes bidirectionally.
    private func startRelay(proxyPort: UInt16, preamble: Data) async throws -> (NWListener, UInt16) {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let listener = try NWListener(using: parameters, on: .any)
        let queue = DispatchQueue(label: "test.mitm.relay")
        let held = SocketRetainer()

        listener.newConnectionHandler = { connection in
            let client = NetSocket(connection: connection, description: "relay-client")
            held.retain(client)
            Task {
                do {
                    try await client.start(timeout: 5)
                    TFLog.shared.warn("test", "relay accepted client, dialing proxy \(proxyPort)")
                    let proxySocket = try await NetSocket.connect(host: "127.0.0.1",
                                                                 port: proxyPort,
                                                                 timeout: 5,
                                                                 tls: nil)
                    held.retain(proxySocket)
                    try await proxySocket.write(preamble)
                    let proxyStream = BufferedStream(proxySocket)
                    let head = try await HTTPCodec.readResponseHead(proxyStream)
                    guard let reply = head, reply.status == 200 else {
                        TFLog.shared.warn("test", "relay non-200 reply: \(String(describing: head?.status))")
                        client.close()
                        proxySocket.close()
                        return
                    }
                    TFLog.shared.warn("test", "relay got 200, pumping")
                    let leftover = proxyStream.drainBuffer()
                    if !leftover.isEmpty {
                        try await client.write(leftover)
                    }
                    _ = await BytePump.run(client, proxySocket, idleTimeout: 20)
                } catch {
                    TFLog.shared.warn("test", "relay error: \(error)")
                    client.close()
                }
            }
        }

        let port = try await listenerPort(listener, queue: queue)
        return (listener, port)
    }

    private func makeTempDirectory(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tfnet-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// SecCertificateCreateWithData needs DER, while the CA stores PEM.
    private func derCertificate(forPEM url: URL) throws -> SecCertificate {
        let derURL = url.deletingLastPathComponent()
            .appendingPathComponent("test-" + url.deletingPathExtension().lastPathComponent + ".der")
        defer { try? FileManager.default.removeItem(at: derURL) }
        _ = try openssl(["x509", "-in", url.path, "-outform", "DER", "-out", derURL.path])
        let data = try Data(contentsOf: derURL)
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw TouchFlowError.connectionFailed("cannot parse DER certificate at \(derURL.path)")
        }
        return certificate
    }

    private func openssl(_ arguments: [String]) throws -> String {        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TouchFlowError.connectionFailed("openssl \(arguments.first ?? "") failed: "
                + String(decoding: errorOutput, as: UTF8.self))
        }
        return String(decoding: output, as: UTF8.self)
    }
}

/// Keeps relay sockets alive for the duration of the test without mutating a
/// captured `var` from a @Sendable listener callback.
private final class SocketRetainer: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [NetSocket] = []

    func retain(_ socket: NetSocket) {
        lock.lock()
        sockets.append(socket)
        lock.unlock()
    }
}

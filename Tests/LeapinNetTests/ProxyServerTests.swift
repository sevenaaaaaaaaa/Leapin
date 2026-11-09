import Foundation
import Network
import XCTest
@testable import LeapinCore
@testable import LeapinNet

final class ProxyServerTests: XCTestCase {
    private var servers: [Any] = []
    private var proxy: ProxyServer?

    override func tearDown() {
        proxy?.stop()
        proxy = nil
        for server in servers {
            switch server {
            case let echo as EchoServer: echo.stop()
            case let http as HTTPOriginServer: http.stop()
            case let socks as FakeSOCKS5Server: socks.stop()
            case let connect as FakeHTTPConnectServer: connect.stop()
            case let dns as FakeDNSServer: dns.stop()
            default: break
            }
        }
        servers.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeProxy(port: UInt16 = 0,
                           allowLAN: Bool = false,
                           router: RouteDeciding,
                           resolver: NameResolving,
                           blocker: DomainBlocking? = nil,
                           flows: FlowRecording? = nil,
                           capture: CaptureSink? = nil,
                           ca: CertificateAuthority? = nil) throws -> ProxyServer {
        let options = ProxyServer.Options(port: port, allowLAN: allowLAN)
        let server = ProxyServer(options: options,
                                 router: router,
                                 resolver: resolver,
                                 blocker: blocker,
                                 flows: flows,
                                 capture: capture,
                                 ca: ca)
        try server.start()
        proxy = server
        return server
    }

    // MARK: - HTTP through the proxy (URLSession, connectionProxyDictionary)

    func testURLSessionHTTPThroughProxy() async throws {
        let origin = try await HTTPOriginServer.start(mode: .echo)
        servers.append(origin)
        let resolver = MapResolver(["leapin-test.internal": ["127.0.0.1"]])
        let router = StaticRouter()
        let flows = FlowCollector()
        let server = try makeProxy(router: router, resolver: resolver, flows: flows)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: Int(server.listeningPort),
            kCFNetworkProxiesHTTPSEnable as String: 0,
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let url = try XCTUnwrap(URL(string: "http://leapin-test.internal:\(origin.port)/hello?x=1"))
        let (data, response) = try await session.data(from: url)

        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "GET")
        XCTAssertEqual(object["target"] as? String, "/hello?x=1")
        XCTAssertEqual(object["host"] as? String, "leapin-test.internal:\(origin.port)")

        let opened = await flows.waitFor(phase: .opened, timeout: 5)
        let closedEvent = await flows.waitFor(phase: .closed, timeout: 5)
        XCTAssertTrue(opened, "no opened flow event")
        XCTAssertTrue(closedEvent, "no closed flow event")
        let metas = router.metas
        XCTAssertEqual(metas.first?.host, "leapin-test.internal")
        XCTAssertEqual(metas.first?.port, origin.port)
        XCTAssertEqual(metas.first?.network, "tcp")
    }

    // MARK: - HTTP CONNECT tunnel

    func testHTTPConnectTunnelEchoesBytes() async throws {
        let echo = try await EchoServer.start()
        servers.append(echo)
        let resolver = MapResolver(["leapin-test.internal": ["127.0.0.1"]])
        let flows = FlowCollector()
        let server = try makeProxy(router: StaticRouter(), resolver: resolver, flows: flows)

        let socket = try await NetSocket.connect(host: "127.0.0.1",
                                                port: server.listeningPort,
                                                timeout: 5,
                                                tls: nil)
        let stream = BufferedStream(socket)
        let request = "CONNECT leapin-test.internal:\(echo.port) HTTP/1.1\r\nHost: leapin-test.internal:\(echo.port)\r\n\r\n"
        try await stream.write(Data(request.utf8))
        let status = try await stream.readLine(limit: 4096)
        let statusLine = try XCTUnwrap(status.map { String(decoding: $0, as: UTF8.self) })
        XCTAssertTrue(statusLine.contains("200"), "unexpected status line: \(statusLine)")
        while true {
            guard let line = try await stream.readLine(limit: 4096) else { break }
            if line.isEmpty { break }
        }

        let payload = Data("ping-pong-1234".utf8)
        try await stream.write(payload)
        let echoed = try await stream.readExactly(payload.count)
        XCTAssertEqual(echoed, payload)

        let opened = await flows.waitFor(phase: .opened, timeout: 5)
        XCTAssertTrue(opened, "no opened flow event")
        let larger = Data(repeating: 0x41, count: 200_000)
        try await stream.write(larger)
        var received = Data()
        while received.count < larger.count {
            let chunk = try await stream.readExactly(min(larger.count - received.count, 64 * 1024))
            received.append(chunk)
        }
        XCTAssertEqual(received, larger)
        socket.close()

        let closedOK = await flows.waitFor(phase: .closed, timeout: 5)
        XCTAssertTrue(closedOK, "no closed flow event")
        let closed = try XCTUnwrap(flows.events(phase: .closed).first)
        XCTAssertGreaterThanOrEqual(closed.bytesIn, larger.count)
        XCTAssertGreaterThanOrEqual(closed.bytesOut, larger.count)
    }

    // MARK: - SOCKS5 handshake through the proxy

    func testSOCKS5HandshakeToEchoServer() async throws {
        let echo = try await EchoServer.start()
        servers.append(echo)
        let resolver = MapResolver(["leapin-test.internal": ["127.0.0.1"]])
        let flows = FlowCollector()
        let server = try makeProxy(router: StaticRouter(), resolver: resolver, flows: flows)

        let client = try await RawSOCKS5Client.connect(to: server.listeningPort,
                                                       host: "leapin-test.internal",
                                                       port: echo.port)
        let payload = Data("socks5-through-proxy".utf8)
        try await client.stream.write(payload)
        let echoed = try await client.stream.readExactly(payload.count)
        XCTAssertEqual(echoed, payload)
        client.close()

        let opened = await flows.waitFor(phase: .opened, timeout: 5)
        let closedOK = await flows.waitFor(phase: .closed, timeout: 5)
        XCTAssertTrue(opened, "no opened flow event")
        XCTAssertTrue(closedOK, "no closed flow event")
    }

    // MARK: - Blocking

    func testBlockerRejectsHTTPConnectWith403() async throws {
        let echo = try await EchoServer.start()
        servers.append(echo)
        let blocker = StaticBlocker(blocked: ["leapin-test.internal": "adblock: test list"])
        let server = try makeProxy(router: StaticRouter(), resolver: MapResolver(), blocker: blocker)

        let socket = try await NetSocket.connect(host: "127.0.0.1",
                                                port: server.listeningPort,
                                                timeout: 5,
                                                tls: nil)
        let stream = BufferedStream(socket)
        try await stream.write(Data("CONNECT leapin-test.internal:\(echo.port) HTTP/1.1\r\nHost: leapin-test.internal\r\n\r\n".utf8))
        let rawStatus = try await stream.readLine(limit: 4096)
        let statusLine = try XCTUnwrap(rawStatus.map { String(decoding: $0, as: UTF8.self) })
        XCTAssertTrue(statusLine.contains("403"), "expected 403, got: \(statusLine)")
        socket.close()
    }

    func testRouterRejectOutboundIsNotDialed() async throws {
        let echo = try await EchoServer.start()
        servers.append(echo)
        let router = StaticRouter()
        router.route(host: "blocked.test", via: .reject)
        let flows = FlowCollector()
        let server = try makeProxy(router: router, resolver: MapResolver(), flows: flows)

        let client = try await NetSocket.connect(host: "127.0.0.1", port: server.listeningPort, timeout: 5, tls: nil)
        defer { client.close() }
        let stream = BufferedStream(client)
        try await stream.write(Data("CONNECT blocked.test:\(echo.port) HTTP/1.1\r\nHost: blocked.test\r\n\r\n".utf8))
        let rawStatus = try await stream.readLine(limit: 4096)
        let statusLine = try XCTUnwrap(rawStatus.map { String(decoding: $0, as: UTF8.self) })
        XCTAssertTrue(statusLine.contains("403"), "expected 403, got: \(statusLine)")
    }

    // MARK: - Lifecycle

    func testPortInUseProducesReadableError() async throws {
        let first = try makeProxy(router: StaticRouter(), resolver: MapResolver())
        let port = first.listeningPort
        XCTAssertTrue(first.isRunning)

        let second = ProxyServer(options: ProxyServer.Options(port: port),
                                 router: StaticRouter(),
                                 resolver: MapResolver(),
                                 blocker: nil,
                                 flows: nil,
                                 capture: nil)
        XCTAssertThrowsError(try second.start()) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(message.contains("in use"), "unexpected message: \(message)")
        }
    }

    func testStopIsGracefulAndRestartable() async throws {
        let echo = try await EchoServer.start()
        servers.append(echo)
        let resolver = MapResolver(["leapin-test.internal": ["127.0.0.1"]])
        let server = try makeProxy(router: StaticRouter(), resolver: resolver)

        let client = try await RawSOCKS5Client.connect(to: server.listeningPort,
                                                       host: "leapin-test.internal",
                                                       port: echo.port)
        XCTAssertEqual(server.activeConnections, 1)
        server.stop()
        XCTAssertFalse(server.isRunning)
        XCTAssertEqual(server.activeConnections, 0)
        client.close()

        let restarted = try makeProxy(router: StaticRouter(), resolver: resolver)
        XCTAssertTrue(restarted.isRunning)
    }

    func testMalformedRequestIsAnsweredOrClosedWithoutCrashing() async throws {
        let server = try makeProxy(router: StaticRouter(), resolver: MapResolver())
        let payloads = ["POST /x HTTP/1.1\r\nHost: h\r\n\r\n", "GARBAGE\r\n\r\n"]
        for payload in payloads {
            let socket = try await NetSocket.connect(host: "127.0.0.1",
                                                    port: server.listeningPort,
                                                    timeout: 5,
                                                    tls: nil)
            let stream = BufferedStream(socket)
            try await stream.write(Data(payload.utf8))
            let line = try? await stream.readLine(limit: 4096)
            if let line, !line.isEmpty {
                let text = String(decoding: line, as: UTF8.self)
                XCTAssertTrue(text.hasPrefix("HTTP/1.1 "), "unexpected response line: \(text)")
            }
            socket.close()
        }
        XCTAssertTrue(server.isRunning)
    }

    func testAllowLANPeerCanConnect() async throws {
        guard let address = Self.nonLoopbackIPv4() else {
            throw XCTSkip("no non-loopback IPv4 address available")
        }
        let echo = try await EchoServer.start()
        servers.append(echo)
        let resolver = MapResolver(["leapin-test.internal": ["127.0.0.1"]])
        let server = try makeProxy(allowLAN: true, router: StaticRouter(), resolver: resolver)

        let client = try await RawSOCKS5Client.connect(to: server.listeningPort,
                                                       host: "leapin-test.internal",
                                                       port: echo.port,
                                                       hostOverride: address)
        let payload = Data("lan".utf8)
        try await client.stream.write(payload)
        let echoed = try await client.stream.readExactly(payload.count)
        XCTAssertEqual(echoed, payload)
        client.close()
    }

    private static func nonLoopbackIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(addr.pointee.sa_len)
                if getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(cString: host)
                    if text != "127.0.0.1" { return text }
                }
            }
            pointer = interface.ifa_next
        }
        return nil
    }
}

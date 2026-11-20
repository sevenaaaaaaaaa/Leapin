import XCTest
@testable import LeapinCore
@testable import LeapinNet

/// The tunnel reaches the proxy through this client, so it has to behave like one.
final class Socks5Tests: XCTestCase {

    func testConnectsThroughTheLocalEngine() async throws {
        let echo = try await EchoServer.start()
        defer { echo.stop() }

        let proxy = try ProxyServer(options: .init(port: 0, allowLAN: false, enableSOCKS5: true),
                                    router: DirectRouteDecider(),
                                    resolver: MapResolver(["echo.test": ["127.0.0.1"]]),
                                    blocker: nil,
                                    flows: nil,
                                    capture: nil)
        try proxy.start()
        defer { proxy.stop() }

        let socket = try await Socks5.connect(via: proxy.listeningPort, host: "echo.test", port: echo.port)
        defer { socket.close() }
        try await socket.write(Data("through socks".utf8))
        let reply = try await socket.read(maxLength: 64)
        XCTAssertEqual(reply.map { String(decoding: $0, as: UTF8.self) }, "through socks")
    }
}

/// Everything goes DIRECT: the tunnel only needs a working pipe to prove itself.
private struct DirectRouteDecider: RouteDeciding {
    func decide(_ meta: ConnectionMeta) -> RouteDecision {
        RouteDecision(policy: "DIRECT", outbound: .direct)
    }
}

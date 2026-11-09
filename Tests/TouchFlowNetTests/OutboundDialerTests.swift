import Foundation
import XCTest
@testable import TouchFlowCore
@testable import TouchFlowNet

final class OutboundDialerTests: XCTestCase {
    private var servers: [Any] = []

    override func tearDown() {
        for server in servers {
            switch server {
            case let echo as EchoServer: echo.stop()
            case let socks as FakeSOCKS5Server: socks.stop()
            case let connect as FakeHTTPConnectServer: connect.stop()
            default: break
            }
        }
        servers.removeAll()
        super.tearDown()
    }

    private func echoServer() async throws -> EchoServer {
        let echo = try await EchoServer.start()
        servers.append(echo)
        return echo
    }

    private func roundTrip(_ stream: ByteStream, payload: Data) async throws -> Data {
        let buffered = BufferedStream(stream)
        try await buffered.write(payload)
        return try await buffered.readExactly(payload.count)
    }

    // MARK: - direct

    func testDirectOutboundConnectsByIP() async throws {
        let echo = try await echoServer()
        let dialer = OutboundDialer(resolver: MapResolver())
        let stream = try await dialer.connect(via: .direct, host: "127.0.0.1", port: echo.port)
        defer { stream.close() }
        let payload = Data("direct-outbound".utf8)
        let echoed = try await roundTrip(stream, payload: payload)
        XCTAssertEqual(echoed, payload)
        XCTAssertTrue(stream.remoteDescription.contains("127.0.0.1"))
    }

    func testDirectOutboundResolvesHostname() async throws {
        let echo = try await echoServer()
        let resolver = MapResolver(["dial.test": ["127.0.0.1"]])
        let dialer = OutboundDialer(resolver: resolver)
        let stream = try await dialer.connect(via: .direct, host: "dial.test", port: echo.port)
        defer { stream.close() }
        let echoed = try await roundTrip(stream, payload: Data("resolved".utf8))
        XCTAssertEqual(echoed, Data("resolved".utf8))
    }

    func testDirectOutboundFailsOnUnresolvableHost() async throws {
        let dialer = OutboundDialer(resolver: MapResolver())
        do {
            let stream = try await dialer.connect(via: .direct, host: "missing.test", port: 9)
            stream.close()
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue("\(error)".contains("missing.test") || error is TouchFlowError)
        }
    }

    // MARK: - reject

    func testRejectOutboundThrowsBlocked() async throws {
        let dialer = OutboundDialer(resolver: MapResolver())
        do {
            let stream = try await dialer.connect(via: .reject, host: "example.com", port: 443)
            stream.close()
            XCTFail("expected blocked error")
        } catch let error as TouchFlowError {
            guard case .blocked(let reason) = error else {
                XCTFail("expected .blocked, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("example.com"))
        }
    }

    // MARK: - http CONNECT upstream

    func testHTTPOutboundConnectsThroughFakeUpstream() async throws {
        let echo = try await echoServer()
        let upstream = try await FakeHTTPConnectServer.start()
        servers.append(upstream)

        let outbound = OutboundConfig(name: "http-proxy",
                                      type: .http,
                                      host: "127.0.0.1",
                                      port: upstream.port,
                                      username: "user",
                                      password: "pa ss")
        let dialer = OutboundDialer(resolver: MapResolver(["dial.test": ["127.0.0.1"]]))
        let stream = try await dialer.connect(via: outbound, host: "127.0.0.1", port: echo.port)
        defer { stream.close() }

        let payload = Data("through-http-connect".utf8)
        let echoed = try await roundTrip(stream, payload: payload)
        XCTAssertEqual(echoed, payload)

        let expected = "Basic " + Data("user:pa ss".utf8).base64EncodedString()
        XCTAssertEqual(upstream.authorizationHeaders.first ?? nil, expected)
        XCTAssertEqual(upstream.targetAuthorities.first, "127.0.0.1:\(echo.port)")
    }

    func testHTTPOutboundWithoutCredentialsSendsNoProxyAuthorization() async throws {
        let echo = try await echoServer()
        let upstream = try await FakeHTTPConnectServer.start()
        servers.append(upstream)

        let outbound = OutboundConfig(name: "http-anon", type: .http, host: "127.0.0.1", port: upstream.port)
        let dialer = OutboundDialer(resolver: MapResolver(["dial.test": ["127.0.0.1"]]))
        let stream = try await dialer.connect(via: outbound, host: "127.0.0.1", port: echo.port)
        defer { stream.close() }
        _ = try await roundTrip(stream, payload: Data("anon".utf8))
        let header = upstream.authorizationHeaders.first ?? nil
        XCTAssertNil(header)
    }

    // MARK: - socks5 upstream

    func testSOCKS5OutboundWithUserPassAuth() async throws {
        let echo = try await echoServer()
        let upstream = try await FakeSOCKS5Server.start(requireAuth: ("alice", "s3cret"))
        servers.append(upstream)

        let outbound = OutboundConfig(name: "socks-up",
                                      type: .socks5,
                                      host: "127.0.0.1",
                                      port: upstream.port,
                                      username: "alice",
                                      password: "s3cret")
        let dialer = OutboundDialer(resolver: MapResolver(["dial.test": ["127.0.0.1"]]))
        let stream = try await dialer.connect(via: outbound, host: "127.0.0.1", port: echo.port)
        defer { stream.close() }

        let payload = Data("through-socks5".utf8)
        let echoed = try await roundTrip(stream, payload: payload)
        XCTAssertEqual(echoed, payload)
        let seen = try XCTUnwrap(upstream.authSeen)
        XCTAssertEqual(seen.0, "alice")
        XCTAssertEqual(seen.1, "s3cret")
    }

    func testSOCKS5OutboundWithoutAuth() async throws {
        let echo = try await echoServer()
        let upstream = try await FakeSOCKS5Server.start()
        servers.append(upstream)

        let outbound = OutboundConfig(name: "socks-anon", type: .socks5, host: "127.0.0.1", port: upstream.port)
        let dialer = OutboundDialer(resolver: MapResolver(["dial.test": ["127.0.0.1"]]))
        let stream = try await dialer.connect(via: outbound, host: "127.0.0.1", port: echo.port)
        defer { stream.close() }
        let echoed = try await roundTrip(stream, payload: Data("anon-socks".utf8))
        XCTAssertEqual(echoed, Data("anon-socks".utf8))
        XCTAssertNil(upstream.authSeen)
    }

    func testSOCKS5OutboundRejectsBadCredentials() async throws {
        let upstream = try await FakeSOCKS5Server.start(requireAuth: ("alice", "right"))
        servers.append(upstream)
        let outbound = OutboundConfig(name: "socks-bad",
                                      type: .socks5,
                                      host: "127.0.0.1",
                                      port: upstream.port,
                                      username: "alice",
                                      password: "wrong")
        let dialer = OutboundDialer(resolver: MapResolver(["dial.test": ["127.0.0.1"]]))
        do {
            let stream = try await dialer.connect(via: outbound, host: "dial.test", port: 9)
            stream.close()
            XCTFail("expected auth failure")
        } catch {
            XCTAssertTrue("\(error)".lowercased().contains("auth") || error is TouchFlowError,
                          "unexpected error: \(error)")
        }
    }

    // MARK: - misconfiguration

    func testShadowsocksOutboundRequiresCipherAndPassword() async throws {
        let dialer = OutboundDialer(resolver: MapResolver())
        let outbound = OutboundConfig(name: "ss-broken", type: .shadowsocks, host: "127.0.0.1", port: 8388)
        do {
            let stream = try await dialer.connect(via: outbound, host: "dial.test", port: 80)
            stream.close()
            XCTFail("expected invalid configuration")
        } catch let error as TouchFlowError {
            // Missing or unknown cipher surfaces as unsupported configuration.
            XCTAssertTrue("\(error)".contains("cipher"), "unexpected error \(error)")
        }
    }

    func testUnsupportedCipherIsRejected() async throws {
        let dialer = OutboundDialer(resolver: MapResolver())
        let outbound = OutboundConfig(name: "ss-bad-cipher",
                                      type: .shadowsocks,
                                      host: "127.0.0.1",
                                      port: 8388,
                                      password: "pw",
                                      cipher: "rc4-md5")
        do {
            let stream = try await dialer.connect(via: outbound, host: "dial.test", port: 80)
            stream.close()
            XCTFail("expected unsupported cipher error")
        } catch let error as TouchFlowError {
            XCTAssertTrue("\(error)".contains("rc4-md5"), "unexpected error \(error)")
        }
    }
}

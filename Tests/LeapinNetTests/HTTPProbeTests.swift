import Foundation
import Network
import XCTest
import LeapinCore
@testable import LeapinNet

/// Direct HTTP probe tests. Everything runs against an in-process Network.framework
/// server on port 0 — no external network, no proxy.
final class HTTPProbeTests: XCTestCase {

    // MARK: - Local server

    /// Minimal HTTP/1.1 server: answers one request per connection from a closure.
    /// Returning nil leaves the connection open and silent (timeout test).
    final class ProbeServer: @unchecked Sendable {
        struct Response: Sendable {
            var status: String
            var headers: [String: String]
            var body: Data

            init(status: String = "200 OK", headers: [String: String] = [:], body: Data = Data()) {
                self.status = status
                self.headers = headers
                self.body = body
            }
        }

        private(set) var port: UInt16 = 0
        private let listener: NWListener
        private let queue = DispatchQueue(label: "test.http-probe-server")
        private let lock = NSLock()
        private var connections: [NWConnection] = []
        private let responder: @Sendable (String) -> Response?

        private init(listener: NWListener, responder: @escaping @Sendable (String) -> Response?) {
            self.listener = listener
            self.responder = responder
        }

        static func start(_ responder: @escaping @Sendable (String) -> Response?) async throws -> ProbeServer {
            let listener = try NWListener(using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options()), on: .any)
            let server = ProbeServer(listener: listener, responder: responder)
            listener.newConnectionHandler = { connection in
                server.lock.withLock { server.connections.append(connection) }
                let socket = NetSocket(connection: connection, description: "probe-test")
                Task { await server.serve(socket) }
            }
            server.port = try await listenerPort(listener, queue: server.queue)
            return server
        }

        private func serve(_ socket: NetSocket) async {
            do {
                try await socket.start(timeout: 5)
                let request = try await socket.read(maxLength: 16 * 1024)
                let target = request.flatMap(Self.requestTarget) ?? "/"
                guard let response = responder(target) else { return }
                try await socket.write(Self.serialize(response))
                socket.close()
            } catch {
                socket.close()
            }
        }

        private static func requestTarget(_ data: Data) -> String? {
            guard let line = String(data: data, encoding: .utf8)?.components(separatedBy: "\r\n").first else {
                return nil
            }
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { return nil }
            return String(parts[1])
        }

        private static func serialize(_ response: Response) -> Data {
            var head = "HTTP/1.1 \(response.status)\r\n"
            if response.headers.keys.contains(where: { $0.lowercased() == "content-length" }) == false {
                head += "Content-Length: \(response.body.count)\r\n"
            }
            for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) {
                head += "\(name): \(value)\r\n"
            }
            head += "Connection: close\r\n\r\n"
            return Data(head.utf8) + response.body
        }

        func stop() {
            listener.cancel()
            for connection in lock.withLock({ connections }) { connection.cancel() }
            lock.withLock { connections.removeAll() }
        }
    }

    // MARK: - Tests

    func testProbe200ReportsStatusHeadersAndBytes() async throws {
        let server = try await ProbeServer.start { target in
            guard target == "/ok" else { return ProbeServer.Response(status: "404 Not Found") }
            return ProbeServer.Response(status: "200 OK",
                                        headers: ["X-Probe": "yes", "Content-Type": "text/plain"],
                                        body: Data("hello".utf8))
        }
        defer { server.stop() }

        let result = await HTTPProbe.probe("http://127.0.0.1:\(server.port)/ok", timeoutMs: 2000)

        XCTAssertNil(result.error)
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.httpVersion, "HTTP/1.1")
        XCTAssertEqual(result.headers["x-probe"], "yes")
        XCTAssertEqual(result.headers["content-type"], "text/plain")
        XCTAssertEqual(result.bodyBytes, 5)
        XCTAssertGreaterThan(result.headerBytes, 0)
        XCTAssertEqual(result.redirects, 0)
        XCTAssertFalse(result.tls)
        XCTAssertNotNil(result.remoteAddress)
        XCTAssertGreaterThan(result.elapsedMs, 0)
    }

    func testProbeFollowsRelativeRedirectAndCountsIt() async throws {
        let server = try await ProbeServer.start { target in
            switch target {
            case "/start":
                return ProbeServer.Response(status: "302 Found", headers: ["Location": "/ok"])
            case "/ok":
                return ProbeServer.Response(status: "200 OK", headers: ["X-Final": "1"], body: Data("done".utf8))
            default:
                return ProbeServer.Response(status: "404 Not Found")
            }
        }
        defer { server.stop() }

        let result = await HTTPProbe.probe("http://127.0.0.1:\(server.port)/start", timeoutMs: 2000)

        XCTAssertNil(result.error)
        XCTAssertEqual(result.redirects, 1)
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.headers["x-final"], "1")
        XCTAssertEqual(result.bodyBytes, 4)
    }

    func testProbeStopsAfterThreeRedirects() async throws {
        let server = try await ProbeServer.start { _ in
            ProbeServer.Response(status: "302 Found", headers: ["Location": "/loop"])
        }
        defer { server.stop() }

        let result = await HTTPProbe.probe("http://127.0.0.1:\(server.port)/loop", timeoutMs: 2000)

        XCTAssertNil(result.error)
        XCTAssertEqual(result.redirects, 3)
        XCTAssertEqual(result.statusCode, 302)
    }

    func testProbeConnectionRefusedSetsError() async throws {
        // 先拿到一个空闲端口再立刻关掉监听：之后连接该端口必然被拒绝。
        let server = try await ProbeServer.start { _ in ProbeServer.Response() }
        let port = server.port
        server.stop()
        try? await Task.sleep(nanoseconds: 300_000_000)

        let result = await HTTPProbe.probe("http://127.0.0.1:\(port)/", timeoutMs: 1000)

        XCTAssertNotNil(result.error)
        XCTAssertNil(result.statusCode)
        XCTAssertGreaterThan(result.elapsedMs, 0)
    }

    func testProbeTimeoutSetsError() async throws {
        // 服务端读完请求后保持沉默，probe 必须在 timeoutMs 后放弃。
        let server = try await ProbeServer.start { _ in nil }
        defer { server.stop() }

        let result = await HTTPProbe.probe("http://127.0.0.1:\(server.port)/slow", timeoutMs: 500)

        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error?.contains("超时") == true, "unexpected error: \(result.error ?? "nil")")
    }

    func testProbeRejectsNonHTTPScheme() async throws {
        let result = await HTTPProbe.probe("ftp://example.com/file", timeoutMs: 500)
        XCTAssertNotNil(result.error)
        XCTAssertNil(result.statusCode)
    }
}

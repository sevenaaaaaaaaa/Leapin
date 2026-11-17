import XCTest
@testable import LeapinNet
import LeapinCore
import Network

/// Loopback coverage for NodeSpeedTest: a scripted local HTTP server means the
/// byte-counting, status handling and partial-timeout paths are all deterministic.
final class NodeSpeedTestTests: XCTestCase {

    private final class SpeedServer: @unchecked Sendable {
        private(set) var port: UInt16 = 0
        private let listener: NWListener
        private let queue = DispatchQueue(label: "test.speed-server")
        private let lock = NSLock()
        private var connections: [NWConnection] = []
        private let script: @Sendable (NetSocket) async throws -> Void

        private init(listener: NWListener, script: @escaping @Sendable (NetSocket) async throws -> Void) {
            self.listener = listener
            self.script = script
        }

        static func start(_ script: @escaping @Sendable (NetSocket) async throws -> Void) async throws -> SpeedServer {
            let listener = try NWListener(using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options()), on: .any)
            let server = SpeedServer(listener: listener, script: script)
            listener.newConnectionHandler = { connection in
                server.lock.withLock { server.connections.append(connection) }
                let socket = NetSocket(connection: connection, description: "speed-test")
                Task { await server.serve(socket) }
            }
            server.port = try await listenerPort(listener, queue: server.queue)
            return server
        }

        private func serve(_ socket: NetSocket) async {
            do {
                try await socket.start(timeout: 5)
                _ = try await socket.read(maxLength: 16 * 1024)
                try await script(socket)
                socket.close()
            } catch {
                socket.close()
            }
        }

        func stop() {
            listener.cancel()
            for connection in lock.withLock({ connections }) { connection.cancel() }
            lock.withLock { connections.removeAll() }
        }
    }

    private func dialer() throws -> OutboundDialer {
        let resolver = MapResolver()
        resolver.set("speed.test", ["127.0.0.1"])
        return OutboundDialer(resolver: resolver)
    }

    private static func header(_ extra: String = "") -> Data {
        Data(("HTTP/1.1 200 OK\r\nContent-Length: 10000000\r\nConnection: close\r\n" + extra + "\r\n").utf8)
    }

    func testMeasuresThroughputUntilByteCap() async throws {
        let body = Data(repeating: 0x61, count: 2_000_000)
        let server = try await SpeedServer.start { socket in
            try await socket.write(Self.header() + body)
        }
        defer { server.stop() }

        let result = try await NodeSpeedTest.measure(dialer: dialer(), outbound: .direct,
                                                     host: "speed.test", port: server.port, path: "/big",
                                                     maxBytes: 1_000_000, timeout: 10)
        // The cap is checked between 64 KB reads, so one final chunk may overshoot.
        XCTAssertGreaterThanOrEqual(result.bytes, 1_000_000)
        XCTAssertLessThanOrEqual(result.bytes, 1_000_000 + 65_536)
        XCTAssertGreaterThan(result.mbps, 0)
        XCTAssertGreaterThan(result.elapsedMs, 0)
    }

    func testNon2xxStatusThrows() async throws {
        let server = try await SpeedServer.start { socket in
            try await socket.write(Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8))
        }
        defer { server.stop() }

        do {
            _ = try await NodeSpeedTest.measure(dialer: dialer(), outbound: .direct,
                                                host: "speed.test", port: server.port, path: "/missing",
                                                maxBytes: 1_000_000, timeout: 5)
            XCTFail("a 404 must fail the measurement")
        } catch let error as LeapinError {
            guard case .protocolError = error else { return XCTFail("expected protocolError, got \(error)") }
        }
    }

    func testTimeoutWithEnoughDataReturnsPartialResult() async throws {
        let chunk = Data(repeating: 0x62, count: 128 * 1024)
        let server = try await SpeedServer.start { socket in
            try await socket.write(Self.header() + chunk)
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        defer { server.stop() }

        let result = try await NodeSpeedTest.measure(dialer: dialer(), outbound: .direct,
                                                     host: "speed.test", port: server.port, path: "/slow",
                                                     maxBytes: 10_000_000, timeout: 1)
        XCTAssertEqual(result.bytes, 128 * 1024, "timeout keeps the bytes already read")
        XCTAssertGreaterThan(result.mbps, 0)
    }

    func testTimeoutWithTooLittleDataFails() async throws {
        let server = try await SpeedServer.start { socket in
            try await socket.write(Self.header())
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        defer { server.stop() }

        do {
            _ = try await NodeSpeedTest.measure(dialer: dialer(), outbound: .direct,
                                                host: "speed.test", port: server.port, path: "/stuck",
                                                maxBytes: 10_000_000, timeout: 1)
            XCTFail("under 64 KB on timeout means the node is dead for bulk traffic")
        } catch let error as LeapinError {
            guard case .timeout = error else { return XCTFail("expected timeout, got \(error)") }
        }
    }
}
import Foundation
import LeapinCore

/// Downlink bandwidth measurement through an outbound's real dial path.
///
/// The dialer hands us an already-proxied ByteStream, and Network.framework
/// cannot layer TLS on top of an existing stream, so the measurement speaks
/// plain HTTP/1.1: GET a large object, count bytes until the cap or the
/// deadline. Chunk framing and headers are counted too, which keeps the code
/// honest at the cost of a small overestimate (well under 1% at these sizes).
public enum NodeSpeedTest {
    public struct Result: Sendable {
        public var bytes: Int
        public var elapsedMs: Double
        public var mbps: Double
    }

    /// Bytes counter shared between the transfer task and the timeout path,
    /// so a slow-but-alive transfer still yields a partial measurement.
    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = 0
        func add(_ n: Int) { lock.withLock { bytes += n } }
        var value: Int { lock.withLock { bytes } }
    }

    /// Runs one download. A timeout with at least 64 KB read returns a partial
    /// result instead of failing; anything less means the node is effectively
    /// dead for bulk traffic and the timeout propagates.
    public static func measure(dialer: OutboundDialer, outbound: OutboundConfig,
                               host: String, port: UInt16, path: String,
                               maxBytes: Int, timeout: TimeInterval) async throws -> Result {
        let box = ProgressBox()
        let started = Date()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let stream = try await dialer.connect(via: outbound, host: host, port: port)
                    defer { stream.close() }
                    let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\n"
                        + "User-Agent: Leapin-SpeedTest/1.0\r\nAccept: */*\r\nConnection: close\r\n\r\n"
                    try await stream.write(Data(request.utf8))

                    let separator = Data("\r\n\r\n".utf8)
                    var head = Data()
                    var headerEnd: Range<Data.Index>?
                    while headerEnd == nil {
                        guard let chunk = try await stream.read(maxLength: 16384) else {
                            throw LeapinError.connectionFailed("closed before response headers")
                        }
                        head.append(chunk)
                        headerEnd = head.range(of: separator)
                        if head.count > 65_536 {
                            throw LeapinError.protocolError("response headers too large")
                        }
                    }
                    let sep = headerEnd!
                    let statusLine = String(decoding: head[head.startIndex..<sep.lowerBound], as: UTF8.self)
                    guard let code = statusCode(statusLine), (200..<300).contains(code) else {
                        throw LeapinError.protocolError("unexpected response: \(statusLine.prefix(80))")
                    }
                    box.add(head.count - sep.upperBound)
                    while box.value < maxBytes {
                        guard let chunk = try await stream.read(maxLength: 65_536) else { break }
                        box.add(chunk.count)
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw LeapinError.timeout
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch LeapinError.timeout {
            guard box.value >= 64 * 1024 else { throw LeapinError.timeout }
        }
        let elapsed = max(0.05, Date().timeIntervalSince(started))
        let mbps = Double(box.value) * 8 / elapsed / 1_000_000
        return Result(bytes: box.value, elapsedMs: elapsed * 1000,
                      mbps: (mbps * 100).rounded() / 100)
    }

    private static func statusCode(_ head: String) -> Int? {
        guard let first = head.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }
}
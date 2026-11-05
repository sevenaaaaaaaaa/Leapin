import Foundation
import TouchFlowCore
import Network

/// A `ByteStream` over `NWConnection` with explicit buffering, half-close support and
/// continuation-safe reads. This is the socket type used throughout TouchFlowNet; it is
/// preferred over `NWByteStream` because the proxy needs half-close (write shutdown) and
/// pushback while still exposing the same `ByteStream` contract.
public final class NetSocket: ByteStream, WriteHalfClosable, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()

    private var pending = Data()
    private var readers: [(max: Int, cont: CheckedContinuation<Data?, Error>)] = []
    private var receiveInFlight = false
    private var eof = false
    private var failure: Error?
    private var isClosed = false
    private var readCount = 0
    private var writeCount = 0
    private var writeShutdown = false

    public let remoteDescription: String

    public init(connection: NWConnection, description: String? = nil) {
        self.connection = connection
        self.queue = DispatchQueue(label: "com.touchflow.net.socket")
        self.remoteDescription = description ?? "\(connection.endpoint)"
    }

    public var bytesRead: Int { lock.withLock { readCount } }
    public var bytesWritten: Int { lock.withLock { writeCount } }

    /// The resolved peer as `ip:port` once the connection is ready, if Network
    /// exposes it. Used by probes to report where traffic actually landed.
    public var peerAddress: String? {
        guard let endpoint = connection.currentPath?.remoteEndpoint else { return nil }
        if case let .hostPort(host, port) = endpoint {
            return "\(host):\(port)"
        }
        return "\(endpoint)"
    }

    /// Starts the connection and waits until it is ready (or fails).
    public func start(timeout: TimeInterval = 12) async throws {
        let connection = self.connection
        let queue = self.queue
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceBox()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume() }
                case .failed(let err):
                    if once.claim() { cont.resume(throwing: TouchFlowError.connectionFailed("\(self.remoteDescription): \(err)")) }
                case .cancelled:
                    if once.claim() { cont.resume(throwing: TouchFlowError.connectionFailed("\(self.remoteDescription): cancelled")) }
                case .waiting(let err):
                    TFLog.shared.debug("socket", "waiting \(self.remoteDescription): \(err)")
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.claim() {
                    connection.cancel()
                    cont.resume(throwing: TouchFlowError.timeout)
                }
            }
        }
    }

    // MARK: - Reading

    public func read(maxLength: Int) async throws -> Data? {
        if maxLength <= 0 { return Data() }
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let failure {
                lock.unlock()
                cont.resume(throwing: failure)
                return
            }
            if !pending.isEmpty {
                let n = min(maxLength, pending.count)
                let chunk = pending.prefix(n)
                pending.removeFirst(n)
                readCount += n
                lock.unlock()
                cont.resume(returning: Data(chunk))
                return
            }
            if eof || isClosed {
                lock.unlock()
                cont.resume(returning: nil)
                return
            }
            readers.append((maxLength, cont))
            let startReceive = !receiveInFlight
            if startReceive { receiveInFlight = true }
            lock.unlock()
            if startReceive { receiveOnce() }
        }
    }

    private func receiveOnce() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var toResume: [(CheckedContinuation<Data?, Error>, Data?, Error?)] = []
            self.lock.lock()
            if let error {
                self.failure = TouchFlowError.connectionFailed("read \(self.remoteDescription): \(error)")
            }
            if let data, !data.isEmpty {
                self.pending.append(data)
            }
            if isComplete || error != nil {
                self.eof = true
                TFLog.shared.debug("socket", "eof \(self.remoteDescription) isComplete=\(isComplete) error=\(error.map { "\($0)" } ?? "nil")")
            }
            while let first = self.readers.first {
                if !self.pending.isEmpty {
                    let n = min(first.max, self.pending.count)
                    let chunk = self.pending.prefix(n)
                    self.pending.removeFirst(n)
                    self.readCount += n
                    self.readers.removeFirst()
                    toResume.append((first.cont, Data(chunk), nil))
                } else if self.eof || self.isClosed {
                    self.readers.removeFirst()
                    toResume.append((first.cont, nil, self.failure))
                } else {
                    break
                }
            }
            let needMore = !self.readers.isEmpty && !self.eof && !self.isClosed && self.failure == nil
            if !needMore { self.receiveInFlight = false }
            self.lock.unlock()

            for (cont, chunk, err) in toResume {
                if let err { cont.resume(throwing: err) } else { cont.resume(returning: chunk) }
            }
            if needMore { self.receiveOnce() }
        }
    }

    /// Pushes bytes back so that the next read returns them first.
    public func unread(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        pending = data + pending
        lock.unlock()
    }

    // MARK: - Writing

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        let connection = self.connection
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: TouchFlowError.connectionFailed("write \(self.remoteDescription): \(error)"))
                } else {
                    self.lock.withLock { self.writeCount += data.count }
                    cont.resume()
                }
            })
        }
    }

    /// Half-close: signals end of stream on the write direction but keeps reading.
    public func closeWrite() {
        lock.lock()
        if writeShutdown || isClosed { lock.unlock(); return }
        writeShutdown = true
        lock.unlock()
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in })
    }

    public func close() {
        lock.lock()
        if isClosed { lock.unlock(); return }
        isClosed = true
        eof = true
        let waiters = readers
        readers.removeAll()
        let err = failure
        lock.unlock()
        TFLog.shared.debug("socket", "close \(remoteDescription) read=\(readCount) written=\(writeCount)")
        connection.cancel()
        for w in waiters {
            if let err { w.cont.resume(throwing: err) } else { w.cont.resume(returning: nil) }
        }
    }

    // MARK: - Factory helpers

    public static func connect(host: String, port: UInt16, timeout: TimeInterval = 12,
                               tls: NWProtocolTLS.Options? = nil) async throws -> NetSocket {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TouchFlowError.connectionFailed("bad port \(port)")
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = Int(timeout)
        let params: NWParameters
        if let tls {
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        params.allowLocalEndpointReuse = true
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        let socket = NetSocket(connection: conn, description: "\(host):\(port)")
        do {
            try await socket.start(timeout: timeout)
        } catch {
            socket.close()
            throw error
        }
        return socket
    }
}

/// Protocol for streams that can shut down only their write direction.
public protocol WriteHalfClosable: AnyObject {
    func closeWrite()
}

/// One-shot claim helper for continuation resume safety.
final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

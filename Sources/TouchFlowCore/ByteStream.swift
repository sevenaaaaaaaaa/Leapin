import Foundation
import Network

/// Network.framework based ByteStream.
public final class NWByteStream: ByteStream, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.touchflow.stream")
    private let lock = NSLock()
    private var pending: Data = Data()
    private var isClosed = false
    private var readCount = 0
    private var writeCount = 0

    public let remoteDescription: String

    public init(connection: NWConnection, description: String? = nil) {
        self.connection = connection
        self.remoteDescription = description ?? "\(connection.endpoint)"
    }

    public var bytesRead: Int { lock.withLock { readCount } }
    public var bytesWritten: Int { lock.withLock { writeCount } }

    public static func connect(host: String, port: UInt16, timeout: TimeInterval = 12) async throws -> NWByteStream {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TouchFlowError.connectionFailed("bad port \(port)")
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = Int(timeout)
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        let stream = NWByteStream(connection: conn, description: "\(host):\(port)")
        try await stream.start()
        return stream
    }

    public func start() async throws {
        let connection = self.connection
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumeLock = NSLock()
            var resumed = false
            connection.stateUpdateHandler = { state in
                resumeLock.lock(); defer { resumeLock.unlock() }
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true; cont.resume()
                case .failed(let err):
                    resumed = true; cont.resume(throwing: TouchFlowError.connectionFailed("\(err)"))
                case .cancelled:
                    resumed = true; cont.resume(throwing: TouchFlowError.connectionFailed("cancelled"))
                case .waiting(let err):
                    TFLog.shared.debug("stream", "waiting \(self.remoteDescription): \(err)")
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        let connection = self.connection
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: TouchFlowError.connectionFailed("write: \(error)")) }
                else { cont.resume() }
            })
        }
        lock.withLock { writeCount += data.count }
    }

    public func read(maxLength: Int) async throws -> Data? {
        lock.lock()
        if !pending.isEmpty {
            let chunk = pending.prefix(maxLength)
            pending.removeFirst(chunk.count)
            lock.unlock()
            return Data(chunk)
        }
        let closed = isClosed
        lock.unlock()
        if closed { return nil }

        let connection = self.connection
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: TouchFlowError.connectionFailed("read: \(error)"))
                    return
                }
                if let data, !data.isEmpty {
                    self.lock.withLock { self.readCount += data.count }
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    /// Pushes bytes back so the next read returns them first (used by protocol sniffing).
    public func unread(_ data: Data) {
        lock.withLock { pending = data + pending }
    }

    public func close() {
        lock.withLock { isClosed = true }
        connection.cancel()
    }
}

extension NSLock {
    @discardableResult
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

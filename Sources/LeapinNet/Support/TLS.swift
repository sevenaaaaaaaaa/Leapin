import Foundation
import LeapinCore
import Network
import Security

/// Builders for `NWProtocolTLS.Options` used by outbound TLS (trojan, DoT, HTTPS origin)
/// and by the MITM TLS terminator.
public enum TLSFactory {
    /// Client-side TLS options. `customVerify` is only used by tests and by callers that
    /// want to pin the Leapin CA; it replaces default platform trust evaluation.
    public static func clientOptions(serverName: String?,
                                     alpn: [String] = ["http/1.1"],
                                     minimumVersion: tls_protocol_version_t = .TLSv12,
                                     customVerify: ((SecTrust) -> Bool)? = nil) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, minimumVersion)
        for proto in alpn {
            sec_protocol_options_add_tls_application_protocol(sec, proto)
        }
        if let serverName, !serverName.isEmpty {
            sec_protocol_options_set_tls_server_name(sec, serverName)
        }
        if let customVerify {
            sec_protocol_options_set_verify_block(sec, { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                complete(customVerify(trust))
            }, DispatchQueue.global(qos: .userInitiated))
        }
        return options
    }

    /// Server-side TLS options presenting `identity` (a leaf certificate + key).
    public static func serverOptions(identity: sec_identity_t?,
                                     alpn: [String] = ["http/1.1"],
                                     minimumVersion: tls_protocol_version_t = .TLSv12) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, minimumVersion)
        for proto in alpn {
            sec_protocol_options_add_tls_application_protocol(sec, proto)
        }
        if let identity {
            sec_protocol_options_set_local_identity(sec, identity)
        }
        return options
    }

    public static func tcpParameters(tls: NWProtocolTLS.Options?, timeout: TimeInterval = 12) -> NWParameters {
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
        return params
    }
}

/// A single-use loopback TLS server. Network.framework cannot upgrade an accepted plain
/// TCP connection to TLS in place, so MITM works like this:
///
///   client --plain TCP--> proxy --plain TCP--> loopback TLS listener --> TLS terminator
///
/// The proxy relays the client's raw (encrypted) bytes into the loopback listener and reads
/// decrypted bytes back from the accepted connection. The listener binds an ephemeral port
/// and rejects non-loopback peers.
public final class LocalTLSServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var waiter: CheckedContinuation<NetSocket, Error>?
    private var queuedSocket: NetSocket?
    private var queuedError: Error?
    private var closed = false
    private var portStorage: UInt16 = 0

    /// The ephemeral port the listener actually bound. Valid once `start` returns.
    public var port: UInt16 { lock.withLock { portStorage } }

    private init(listener: NWListener) {
        self.listener = listener
    }

    /// Starts the listener on an ephemeral loopback port and waits until it is ready.
    ///
    /// `NWListener.port` is only populated after the listener reaches `.ready`, so the
    /// port has to be read from the state handler rather than right after construction.
    public static func start(identity: sec_identity_t?, alpn: [String] = ["http/1.1"]) async throws -> LocalTLSServer {
        let params = TLSFactory.tcpParameters(tls: TLSFactory.serverOptions(identity: identity, alpn: alpn))
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: .any)
        } catch {
            throw LeapinError.connectionFailed("loopback TLS listener: \(error)")
        }
        let server = LocalTLSServer(listener: listener)
        try await server.activate()
        return server
    }

    private func activate() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let peer = "\(connection.endpoint)"
            if !peer.contains("127.0.0.1") && !peer.contains("::1") {
                LPLog.shared.warn("mitm", "rejecting non-loopback loopback-bridge peer \(peer)")
                connection.cancel()
                return
            }
            let socket = NetSocket(connection: connection, description: "tls-terminator")
            self.lock.lock()
            if let waiter = self.waiter {
                self.waiter = nil
                self.lock.unlock()
                waiter.resume(returning: socket)
            } else if self.closed {
                self.lock.unlock()
                socket.close()
            } else {
                self.queuedSocket = socket
                self.lock.unlock()
            }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceBox()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self, once.claim() else { return }
                    guard let bound = self.listener.port?.rawValue, bound != 0 else {
                        cont.resume(throwing: LeapinError.connectionFailed("loopback TLS listener has no port"))
                        return
                    }
                    self.lock.withLock { self.portStorage = bound }
                    cont.resume()
                case .failed(let err):
                    guard once.claim() else { return }
                    LPLog.shared.error("mitm", "loopback TLS listener failed: \(err)")
                    cont.resume(throwing: LeapinError.connectionFailed("loopback TLS listener: \(err)"))
                case .cancelled:
                    guard once.claim() else { return }
                    cont.resume(throwing: LeapinError.connectionFailed("loopback TLS listener cancelled"))
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "com.leapin.net.loopback-tls"))
        }
    }

    /// Waits for the single expected connection (the proxy's own dialer) and starts it.
    ///
    /// `NWListener` hands over connections that are not yet started, so the accepted
    /// `NWConnection` must be started here; otherwise the TLS handshake never advances
    /// (the peer sits in `preparing` until its own timeout fires).
    public func accept(timeout: TimeInterval = 10) async throws -> NetSocket {
        let socket: NetSocket = try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let queued = queuedSocket {
                queuedSocket = nil
                lock.unlock()
                cont.resume(returning: queued)
                return
            }
            if closed {
                lock.unlock()
                cont.resume(throwing: LeapinError.connectionFailed("loopback TLS listener closed"))
                return
            }
            waiter = cont
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let pending = self.waiter
                self.waiter = nil
                self.lock.unlock()
                pending?.resume(throwing: LeapinError.timeout)
            }
        }
        do {
            try await socket.start(timeout: timeout)
        } catch {
            socket.close()
            throw error
        }
        return socket
    }

    public func close() {
        lock.lock()
        closed = true
        let pending = waiter
        waiter = nil
        let queued = queuedSocket
        queuedSocket = nil
        lock.unlock()
        listener.cancel()
        pending?.resume(throwing: LeapinError.connectionFailed("loopback TLS listener closed"))
        queued?.close()
    }
}

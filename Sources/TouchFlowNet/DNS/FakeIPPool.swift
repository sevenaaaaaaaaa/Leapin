import Foundation
import Network
import TouchFlowCore

/// Sequential fake-IP allocator over an IPv4 CIDR (default 198.18.0.0/15).
///
/// The pool is deliberately tiny and deterministic: first allocation is the first
/// usable address of the range, then it walks forward. Once exhausted it wraps and
/// recycles the oldest entries, logging a warning.
public final class FakeIPPool: @unchecked Sendable {
    private let lock = NSLock()
    private let range: IPv4CIDR
    private var nameToIP: [String: String] = [:]
    private var ipToName: [String: String] = [:]
    private var allocations: [String] = []
    private var cursor: UInt32 = 0

    /// Number of addresses that will ever be handed out (kept below `addressCount`
    /// so the network/broadcast style edges are never used for /15-style ranges).
    private let capacity: UInt32

    public init(range: String) {
        // 198.18.0.0/15 is the RFC 2544 benchmarking range reserved for fake IPs.
        let defaultRange = IPv4CIDR(network: 0xC6_1200_00, prefix: 15)
        if let parsed = IPv4CIDR(range) {
            self.range = parsed
        } else {
            TFLog.shared.warn("dns", "invalid fake-ip range \(range), falling back to 198.18.0.0/15")
            self.range = defaultRange
        }
        let total = self.range.addressCount
        self.capacity = total > 2 ? total - 2 : max(total, 1)
    }

    public var cidr: String { "\(addressText(range.firstAddress))/\(range.prefix)" }

    /// Returns a stable fake IPv4 address for `host`, allocating one on first use.
    public func ip(for host: String) -> String {
        let key = host.lowercased()
        return lock.withLock { () -> String in
            if let existing = nameToIP[key] { return existing }
            if cursor >= capacity {
                // Recycle the oldest mapping rather than failing.
                if let oldest = allocations.first {
                    allocations.removeFirst()
                    if let recycled = nameToIP.removeValue(forKey: oldest) {
                        ipToName.removeValue(forKey: recycled)
                        return install(key: key, ip: recycled)
                    }
                }
                cursor = 0
            }
            let value = range.firstAddress &+ 1 &+ cursor
            cursor += 1
            return install(key: key, ip: addressText(value))
        }
    }

    /// Reverse lookup for a fake address; nil when the address is not from this pool.
    public func host(for ip: String) -> String? {
        lock.withLock { ipToName[ip] }
    }

    /// True when `ip` sits inside the configured range (even if unallocated).
    public func contains(ip: String) -> Bool {
        range.contains(ipv4: ip)
    }

    public var allocatedCount: Int { lock.withLock { nameToIP.count } }

    public func reset() {
        lock.withLock {
            nameToIP.removeAll()
            ipToName.removeAll()
            allocations.removeAll()
            cursor = 0
        }
    }

    private func install(key: String, ip: String) -> String {
        nameToIP[key] = ip
        ipToName[ip] = key
        allocations.append(key)
        return ip
    }

    private func addressText(_ value: UInt32) -> String {
        let a = UInt8((value >> 24) & 0xFF)
        let b = UInt8((value >> 16) & 0xFF)
        let c = UInt8((value >> 8) & 0xFF)
        let d = UInt8(value & 0xFF)
        return "\(a).\(b).\(c).\(d)"
    }
}

// MARK: - DNS server

/// Minimal DNS proxy listening on UDP + TCP at 127.0.0.1:port.
public final class DNSServer: @unchecked Sendable {
    public let port: UInt16
    private let resolver: DNSResolver
    private let blocker: DomainBlocking?
    private let fakeIP: FakeIPPool?
    private let queue = DispatchQueue(label: "com.touchflow.dns.server", attributes: .concurrent)
    private let lock = NSLock()
    private var udpListener: NWListener?
    private var tcpListener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var running = false

    public init(port: UInt16, resolver: DNSResolver, blocker: DomainBlocking?, fakeIP: FakeIPPool?) {
        self.port = port
        self.resolver = resolver
        self.blocker = blocker
        self.fakeIP = fakeIP
    }

    public var isRunning: Bool { lock.withLock { running } }

    public func start() throws {
        // Port 0 is rejected deliberately: `port` is a stored `let`, so an
        // OS-assigned port could never be reported back to the caller.
        guard port != 0, let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TouchFlowError.invalidConfiguration("invalid DNS listen port \(port)")
        }
        let alreadyRunning = lock.withLock { running }
        guard !alreadyRunning else { return }

        do {
            let udpParams = NWParameters(dtls: nil, udp: NWProtocolUDP.Options())
            // Loopback only: a resolver reachable from the LAN would be an open resolver.
            udpParams.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
            let udp = try NWListener(using: udpParams)
            udp.newConnectionHandler = { [weak self] connection in
                self?.handleUDP(connection)
            }
            udp.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    TFLog.shared.error("dns", "udp listener failed on :\(self.port): \(error.localizedDescription)")
                }
            }
            udp.start(queue: queue)

            let tcpParams = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
            tcpParams.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
            let tcp = try NWListener(using: tcpParams)
            tcp.newConnectionHandler = { [weak self] connection in
                self?.handleTCP(connection)
            }
            tcp.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    TFLog.shared.error("dns", "tcp listener failed on :\(self.port): \(error.localizedDescription)")
                }
            }
            tcp.start(queue: queue)

            lock.withLock {
                udpListener = udp
                tcpListener = tcp
                running = true
            }
            TFLog.shared.info("dns", "DNS server listening on 127.0.0.1:\(port) (udp+tcp)")
        } catch {
            if (error as NSError).code == Int(EADDRINUSE) {
                throw TouchFlowError.connectionFailed("DNS port \(port) already in use")
            }
            throw TouchFlowError.connectionFailed("DNS server failed to start on port \(port): \(error.localizedDescription)")
        }
    }

    public func stop() {
        let state = lock.withLock { () -> (NWListener?, NWListener?, [NWConnection]) in
            let result = (udpListener, tcpListener, Array(connections.values))
            udpListener = nil
            tcpListener = nil
            connections.removeAll()
            running = false
            return result
        }
        state.0?.cancel()
        state.1?.cancel()
        for connection in state.2 { connection.cancel() }
        TFLog.shared.info("dns", "DNS server stopped")
    }

    // MARK: Transports

    private func handleUDP(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let error {
                TFLog.shared.debug("dns", "udp receive error: \(error.localizedDescription)")
                connection.cancel()
                return
            }
            guard let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            Task {
                let reply = await self.answer(raw: data)
                if let reply {
                    connection.send(content: reply, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                } else {
                    connection.cancel()
                }
            }
        }
    }

    private func handleTCP(_ connection: NWConnection) {
        connection.start(queue: queue)
        lock.withLock { connections[ObjectIdentifier(connection)] = connection }
        Task { [weak self] in
            guard let self else {
                connection.cancel()
                return
            }
            let stream = BufferedStream(NetSocket(connection: connection, description: "dns-tcp-client"))
            do {
                while true {
                    let lengthData = try await stream.readExactly(2)
                    let bytes = Array(lengthData)
                    let length = Int(bytes[0]) << 8 | Int(bytes[1])
                    guard length > 0, length <= 65535 else { break }
                    let payload = try await stream.readExactly(length)
                    guard let reply = await self.answer(raw: payload) else { break }
                    var framed = Data([UInt8(reply.count >> 8), UInt8(reply.count & 0xFF)])
                    framed.append(reply)
                    try await stream.write(framed)
                }
            } catch {
                TFLog.shared.debug("dns", "tcp client closed: \(error.localizedDescription)")
            }
            self.lock.withLock { self.connections.removeValue(forKey: ObjectIdentifier(connection)) }
            connection.cancel()
        }
    }

    /// Decodes, answers (fake-IP / hosts / blocker / upstream) and re-encodes.
    public func answer(raw: Data) async -> Data? {
        do {
            let message = try DNSMessage.decode(raw)
            if message.isResponse { return nil }

            if let pool = fakeIP, resolver.config.mode == .fakeIP,
               let question = message.questions.first,
               question.type == .a || question.type == .aaaa {
                let name = question.name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let blocked = blocker?.verdict(for: name, thirdParty: false).blocked ?? false
                if !name.isEmpty, !blocked, !NetAddress.isIPLiteral(name) {
                    let fake = pool.ip(for: name)
                    let records = DNSResolver.records(name: question.name, type: .a, addresses: [fake], ttl: 60)
                    return DNSMessage.reply(to: message, rcode: .noError, answers: records).encode()
                }
            }
            let response = await resolver.respond(to: message)
            return response.encode()
        } catch {
            TFLog.shared.warn("dns", "failed to decode incoming query: \(error.localizedDescription)")
            return nil
        }
    }
}

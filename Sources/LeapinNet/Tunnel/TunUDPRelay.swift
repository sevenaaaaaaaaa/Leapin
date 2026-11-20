import Foundation
import Darwin
import LeapinCore

/// UDP half of the tunnel: each flow becomes one connected datagram socket.
///
/// The engine's SOCKS5 side speaks TCP only, so UDP goes out DIRECT for now - which
/// matches today's router, where everything is DIRECT anyway. When rules arrive, this
/// is the place that has to ask them first (or speak SOCKS5 UDP ASSOCIATE).
public final class TunUDPRelay: @unchecked Sendable {
    private struct Key: Hashable {
        let sourceAddress: UInt32
        let sourcePort: UInt16
        let destinationAddress: UInt32
        let destinationPort: UInt16
    }

    private final class Flow {
        let key: Key
        let fd: Int32
        var lastUsed = Date()
        var closed = false

        init(key: Key, fd: Int32) {
            self.key = key
            self.fd = fd
        }
    }

    public var emit: (@Sendable (Data) -> Void)?
    private let lock = NSLock()
    private var flows: [Key: Flow] = [:]
    private let queue = DispatchQueue(label: "com.leapin.tunnel.udp", attributes: .concurrent)
    private var sweeper: DispatchSourceTimer?
    public static let idleTimeout: TimeInterval = 120

    public init() {}

    public var activeFlows: Int { lock.withLock { flows.count } }

    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.sweep() }
        timer.resume()
        sweeper = timer
    }

    public func stop() {
        sweeper?.cancel()
        sweeper = nil
        let all = lock.withLock { () -> [Flow] in
            let values = Array(flows.values)
            flows.removeAll()
            return values
        }
        for flow in all {
            flow.closed = true
            close(flow.fd)
        }
    }

    // MARK: - Inbound

    public func handle(packet: Data) {
        guard let parsed = IPv4Packet(packet), parsed.protocolNumber == 17,
              let datagram = UDPDatagram(parsed.payload) else { return }

        let key = Key(sourceAddress: parsed.sourceAddress,
                      sourcePort: datagram.sourcePort,
                      destinationAddress: parsed.destinationAddress,
                      destinationPort: datagram.destinationPort)

        if let flow = lock.withLock({ flows[key] }) {
            flow.lastUsed = Date()
            _ = datagram.payload.withUnsafeBytes { raw in
                send(flow.fd, raw.baseAddress, raw.count, 0)
            }
            return
        }
        open(key: key, datagram: datagram, destination: parsed.destinationAddress)
    }

    private func open(key: Key, datagram: UDPDatagram, destination: UInt32) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = datagram.destinationPort.bigEndian
        address.sin_addr.s_addr = destination.bigEndian

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return
        }

        let flow = Flow(key: key, fd: fd)
        lock.withLock { flows[key] = flow }
        _ = datagram.payload.withUnsafeBytes { raw in
            send(fd, raw.baseAddress, raw.count, 0)
        }

        queue.async { [weak self] in
            self?.readLoop(flow)
        }
    }

    private func readLoop(_ flow: Flow) {
        var buffer = [UInt8](repeating: 0, count: 65_535)
        while !flow.closed {
            let read = buffer.withUnsafeMutableBytes { raw -> Int in
                recv(flow.fd, raw.baseAddress, raw.count, 0)
            }
            if read <= 0 {
                break
            }
            flow.lastUsed = Date()
            emit?(packet(for: flow.key, payload: Data(bytes: buffer, count: read)))
        }
        remove(flow)
    }

    private func sweep() {
        let cutoff = Date().addingTimeInterval(-Self.idleTimeout)
        let expired = lock.withLock { () -> [Flow] in
            let stale = flows.values.filter { $0.lastUsed < cutoff }
            for flow in stale { flows.removeValue(forKey: flow.key) }
            return stale
        }
        for flow in expired {
            flow.closed = true
            close(flow.fd)
        }
    }

    private func remove(_ flow: Flow) {
        lock.withLock { flows.removeValue(forKey: flow.key) }
    }

    // MARK: - Packet building

    private func packet(for key: Key, payload: Data) -> Data {
        let total = 20 + 8 + payload.count
        var packet = Data(capacity: total)
        packet.append(contentsOf: [0x45, 0x00,
                                   UInt8(total >> 8 & 0xFF), UInt8(total & 0xFF),
                                   0x00, 0x00, 0x40, 0x00, 64, 17, 0x00, 0x00])
        packet.append(contentsOf: IPv4Packet.bytes(of: key.destinationAddress))
        packet.append(contentsOf: IPv4Packet.bytes(of: key.sourceAddress))
        packet.append(contentsOf: [UInt8(key.destinationPort >> 8), UInt8(key.destinationPort & 0xFF),
                                   UInt8(key.sourcePort >> 8), UInt8(key.sourcePort & 0xFF),
                                   UInt8((8 + payload.count) >> 8), UInt8((8 + payload.count) & 0xFF),
                                   0x00, 0x00])
        packet.append(payload)
        let checksum = IPv4Packet.checksum(packet)
        packet[10] = UInt8(checksum >> 8 & 0xFF)
        packet[11] = UInt8(checksum & 0xFF)
        return packet
    }
}

struct UDPDatagram {
    let sourcePort: UInt16
    let destinationPort: UInt16
    let payload: Data

    init?(_ data: Data) {
        guard data.count >= 8 else { return nil }
        let base = data.startIndex
        sourcePort = UInt16(data[base]) << 8 | UInt16(data[base + 1])
        destinationPort = UInt16(data[base + 2]) << 8 | UInt16(data[base + 3])
        let length = Int(data[base + 4]) << 8 | Int(data[base + 5])
        guard length >= 8, data.count >= length else { return nil }
        payload = data.subdata(in: (base + 8)..<(base + length))
    }
}

import Foundation
import LeapinCore

/// Minimal TCP termination for a TUN interface: instead of routing packets, each
/// flow is ended locally and its bytes are carried by a proxy stream.
///
/// The interface is lossless and ordered, so this stays deliberately simple: no
/// retransmission, no congestion control, one fixed MSS, and an ack for every segment
/// received. That is enough to make a real client talk through the proxy, which is
/// the whole point of the tunnel.
public final class TunTCPRelay: @unchecked Sendable {
    /// Opens the upstream for one flow. Production passes a SOCKS5 dialer at the
    /// local engine; tests pass a plain socket.
    public typealias Connector = @Sendable (String, UInt16) async throws -> ByteStream

    private struct Key: Hashable {
        let sourceAddress: UInt32
        let sourcePort: UInt16
        let destinationAddress: UInt32
        let destinationPort: UInt16
    }

    private final class Flow {
        let key: Key
        var ourSequence: UInt32
        var theirSequence: UInt32
        var stream: ByteStream?
        var pending: Data = Data()
        var closed = false

        init(key: Key, ourSequence: UInt32, theirSequence: UInt32) {
            self.key = key
            self.ourSequence = ourSequence
            self.theirSequence = theirSequence
        }
    }

    private let connector: Connector
    /// Packets the relay wants written back to the TUN. Set by the owner.
    public var emit: (@Sendable (Data) -> Void)?
    private let lock = NSLock()
    private var flows: [Key: Flow] = [:]
    /// Address the tunnel hands out; replies are sourced from it.
    public var localAddress: UInt32
    public static let mss = 1400

    public init(localAddress: UInt32 = 0x0A700001, connector: @escaping Connector) {
        self.localAddress = localAddress
        self.connector = connector
    }

    public var activeFlows: Int { lock.withLock { flows.count } }

    // MARK: - Inbound packets

    /// Handles one IPv4 packet from the TUN. Replies are handed to emit, which the
    /// tunnel owner writes back.
    public func handle(packet: Data) {
        guard let parsed = IPv4Packet(packet), parsed.protocolNumber == 6 else { return }
        guard let segment = TCPSegment(parsed.payload) else { return }

        let key = Key(sourceAddress: parsed.sourceAddress,
                      sourcePort: segment.sourcePort,
                      destinationAddress: parsed.destinationAddress,
                      destinationPort: segment.destinationPort)

        if segment.isSYN, !segment.isACK {
            openFlow(key: key, segment: segment)
            return
        }

        guard let flow = lock.withLock({ flows[key] }) else {
            // Unknown flow: tell the client to stop waiting instead of black-holing it.
            if !segment.isRST {
                send(makeSegment(flowLike: key, sequence: segment.acknowledgement,
                                 acknowledgement: segment.sequence &+ UInt32(segment.payload.count),
                                 flags: TCPSegment.flagRST, payload: Data()))
            }
            return
        }

        if !segment.payload.isEmpty {
            flow.theirSequence = segment.sequence &+ UInt32(segment.payload.count)
            acknowledge(flow, segment: segment)
            if let stream = flow.stream {
                let payload = segment.payload
                Task { try? await stream.write(payload) }
            } else {
                // The client can send before the upstream finished connecting; those
                // bytes are carried once the stream exists instead of being dropped.
                lock.withLock { flow.pending.append(segment.payload) }
            }
        }

        if segment.isFIN {
            flow.theirSequence = flow.theirSequence &+ 1
            acknowledge(flow, segment: segment, extra: 1)
            close(flow, sendFIN: true)
        }
    }

    // MARK: - Flow lifecycle

    private func openFlow(key: Key, segment: TCPSegment) {
        let initial = UInt32.random(in: 1...UInt32.max / 2)
        let flow = Flow(key: key, ourSequence: initial, theirSequence: segment.sequence &+ 1)
        lock.withLock { flows[key] = flow }

        // SYN-ACK first: the client starts sending immediately after it.
        send(makeSegment(for: flow,
                         sequence: initial,
                         acknowledgement: flow.theirSequence,
                         flags: TCPSegment.flagSYN | TCPSegment.flagACK,
                         payload: Data()))
        flow.ourSequence = initial &+ 1

        let host = IPv4Packet.string(from: key.destinationAddress)
        let port = key.destinationPort
        Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.connector(host, port)
                let early = self.lock.withLock { () -> Data in
                    let buffered = flow.pending
                    flow.pending = Data()
                    return buffered
                }
                flow.stream = stream
                if !early.isEmpty { try? await stream.write(early) }
                self.readLoop(flow: flow, stream: stream)
            } catch {
                self.close(flow, sendFIN: false, reset: true)
            }
        }
    }

    private func readLoop(flow: Flow, stream: ByteStream) {
        Task { [weak self] in
            guard let self else { return }
            while true {
                let chunk: Data?
                do {
                    chunk = try await stream.read(maxLength: Self.mss)
                } catch {
                    chunk = nil
                }
                guard let chunk, !chunk.isEmpty else {
                    self.close(flow, sendFIN: true)
                    return
                }
                self.sendData(flow, chunk)
            }
        }
    }

    private func sendData(_ flow: Flow, _ data: Data) {
        var offset = 0
        while offset < data.count {
            let size = min(Self.mss, data.count - offset)
            let slice = data.subdata(in: offset..<(offset + size))
            send(makeSegment(for: flow,
                             sequence: flow.ourSequence,
                             acknowledgement: flow.theirSequence,
                             flags: TCPSegment.flagACK | TCPSegment.flagPSH,
                             payload: slice))
            flow.ourSequence = flow.ourSequence &+ UInt32(size)
            offset += size
        }
    }

    private func acknowledge(_ flow: Flow, segment: TCPSegment, extra: Int = 0) {
        send(makeSegment(for: flow,
                         sequence: flow.ourSequence,
                         acknowledgement: flow.theirSequence &+ UInt32(extra),
                         flags: TCPSegment.flagACK,
                         payload: Data()))
    }

    private func close(_ flow: Flow, sendFIN: Bool, reset: Bool = false) {
        let removed = lock.withLock { flows.removeValue(forKey: flow.key) != nil }
        guard removed else { return }
        if reset {
            send(makeSegment(for: flow, sequence: flow.ourSequence,
                             acknowledgement: flow.theirSequence,
                             flags: TCPSegment.flagRST, payload: Data()))
        } else if sendFIN {
            send(makeSegment(for: flow, sequence: flow.ourSequence,
                             acknowledgement: flow.theirSequence,
                             flags: TCPSegment.flagFIN | TCPSegment.flagACK, payload: Data()))
            flow.ourSequence = flow.ourSequence &+ 1
        }
        try? flow.stream?.close()
    }

    // MARK: - Packet building

    private func send(_ packet: Data) {
        emit?(packet)
    }

    private func makeSegment(for flow: Flow, sequence: UInt32, acknowledgement: UInt32,
                             flags: UInt8, payload: Data) -> Data {
        makeSegment(flowLike: flow.key, sequence: sequence, acknowledgement: acknowledgement,
                    flags: flags, payload: payload)
    }

    private func makeSegment(flowLike key: Key, sequence: UInt32, acknowledgement: UInt32,
                             flags: UInt8, payload: Data) -> Data {
        // Reply direction is the reverse of the flow's.
        var tcp = Data()
        tcp.append(contentsOf: [
            UInt8(key.destinationPort >> 8), UInt8(key.destinationPort & 0xFF),
            UInt8(key.sourcePort >> 8), UInt8(key.sourcePort & 0xFF),
        ])
        tcp.append(contentsOf: [UInt8(sequence >> 24 & 0xFF), UInt8(sequence >> 16 & 0xFF),
                                UInt8(sequence >> 8 & 0xFF), UInt8(sequence & 0xFF)])
        tcp.append(contentsOf: [UInt8(acknowledgement >> 24 & 0xFF), UInt8(acknowledgement >> 16 & 0xFF),
                                UInt8(acknowledgement >> 8 & 0xFF), UInt8(acknowledgement & 0xFF)])
        tcp.append(contentsOf: [0x50, flags, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00])
        tcp.append(payload)

        let checksum = TCPSegment.checksum(source: key.destinationAddress,
                                           destination: key.sourceAddress,
                                           segment: tcp)
        tcp[16] = UInt8(checksum >> 8 & 0xFF)
        tcp[17] = UInt8(checksum & 0xFF)

        var ip = Data()
        let total = 20 + tcp.count
        ip.append(contentsOf: [0x45, 0x00,
                               UInt8(total >> 8 & 0xFF), UInt8(total & 0xFF),
                               0x00, 0x00, 0x40, 0x00, 64, 6, 0x00, 0x00])
        ip.append(contentsOf: IPv4Packet.bytes(of: key.destinationAddress))
        ip.append(contentsOf: IPv4Packet.bytes(of: key.sourceAddress))
        let headerChecksum = IPv4Packet.checksum(ip)
        ip[10] = UInt8(headerChecksum >> 8 & 0xFF)
        ip[11] = UInt8(headerChecksum & 0xFF)
        return ip + tcp
    }
}

// MARK: - Parsing

struct IPv4Packet {
    let sourceAddress: UInt32
    let destinationAddress: UInt32
    let protocolNumber: UInt8
    let payload: Data

    init?(_ data: Data) {
        guard data.count >= 20 else { return nil }
        let version = data[data.startIndex] >> 4
        guard version == 4 else { return nil }
        let headerLength = Int(data[data.startIndex] & 0x0F) * 4
        guard headerLength >= 20, data.count >= headerLength else { return nil }
        let totalLength = Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3])
        guard totalLength >= headerLength, data.count >= totalLength else { return nil }
        sourceAddress = Self.value(from: data, at: 12)
        destinationAddress = Self.value(from: data, at: 16)
        protocolNumber = data[data.startIndex + 9]
        payload = data.subdata(in: (data.startIndex + headerLength)..<(data.startIndex + totalLength))
    }

    static func value(from data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16
            | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    }

    static func bytes(of value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    static func string(from value: UInt32) -> String {
        bytes(of: value).map(String.init).joined(separator: ".")
    }

    static func checksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        var index = data.startIndex
        while index + 1 < data.endIndex {
            sum += UInt32(data[index]) << 8 | UInt32(data[index + 1])
            index += 2
        }
        if index < data.endIndex { sum += UInt32(data[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return UInt16(~sum & 0xFFFF)
    }
}

struct TCPSegment {
    static let flagFIN: UInt8 = 0x01
    static let flagSYN: UInt8 = 0x02
    static let flagRST: UInt8 = 0x04
    static let flagPSH: UInt8 = 0x08
    static let flagACK: UInt8 = 0x10

    let sourcePort: UInt16
    let destinationPort: UInt16
    let sequence: UInt32
    let acknowledgement: UInt32
    let flags: UInt8
    let payload: Data

    init?(_ data: Data) {
        guard data.count >= 20 else { return nil }
        let base = data.startIndex
        sourcePort = UInt16(data[base]) << 8 | UInt16(data[base + 1])
        destinationPort = UInt16(data[base + 2]) << 8 | UInt16(data[base + 3])
        sequence = UInt32(data[base + 4]) << 24 | UInt32(data[base + 5]) << 16
            | UInt32(data[base + 6]) << 8 | UInt32(data[base + 7])
        acknowledgement = UInt32(data[base + 8]) << 24 | UInt32(data[base + 9]) << 16
            | UInt32(data[base + 10]) << 8 | UInt32(data[base + 11])
        let headerLength = Int(data[base + 12] >> 4) * 4
        flags = data[base + 13]
        guard headerLength >= 20, data.count >= headerLength else { return nil }
        payload = data.subdata(in: (base + headerLength)..<data.endIndex)
    }

    var isSYN: Bool { flags & Self.flagSYN != 0 }
    var isACK: Bool { flags & Self.flagACK != 0 }
    var isFIN: Bool { flags & Self.flagFIN != 0 }
    var isRST: Bool { flags & Self.flagRST != 0 }

    static func checksum(source: UInt32, destination: UInt32, segment: Data) -> UInt16 {
        var pseudo = Data()
        pseudo.append(contentsOf: IPv4Packet.bytes(of: source))
        pseudo.append(contentsOf: IPv4Packet.bytes(of: destination))
        pseudo.append(contentsOf: [0, 6, UInt8(segment.count >> 8 & 0xFF), UInt8(segment.count & 0xFF)])
        return IPv4Packet.checksum(pseudo + segment)
    }
}

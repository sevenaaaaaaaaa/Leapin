import XCTest
@testable import LeapinCore
@testable import LeapinNet

/// tun2socks, tested at the packet level: the relay must answer a handshake, carry
/// bytes both ways and finish the connection, without a device or an extension.
final class TunTCPRelayTests: XCTestCase {

    private func ipPacket(source: UInt32, destination: UInt32,
                          sourcePort: UInt16, destinationPort: UInt16,
                          sequence: UInt32, acknowledgement: UInt32,
                          flags: UInt8, payload: Data) -> Data {
        var tcp = Data()
        tcp.append(contentsOf: [UInt8(sourcePort >> 8), UInt8(sourcePort & 0xFF),
                                UInt8(destinationPort >> 8), UInt8(destinationPort & 0xFF)])
        tcp.append(contentsOf: [UInt8(sequence >> 24 & 0xFF), UInt8(sequence >> 16 & 0xFF),
                                UInt8(sequence >> 8 & 0xFF), UInt8(sequence & 0xFF)])
        tcp.append(contentsOf: [UInt8(acknowledgement >> 24 & 0xFF), UInt8(acknowledgement >> 16 & 0xFF),
                                UInt8(acknowledgement >> 8 & 0xFF), UInt8(acknowledgement & 0xFF)])
        tcp.append(contentsOf: [0x50, flags, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00])
        tcp.append(payload)
        let checksum = TCPSegment.checksum(source: source, destination: destination, segment: tcp)
        tcp[16] = UInt8(checksum >> 8 & 0xFF)
        tcp[17] = UInt8(checksum & 0xFF)

        var ip = Data()
        let total = 20 + tcp.count
        ip.append(contentsOf: [0x45, 0x00, UInt8(total >> 8 & 0xFF), UInt8(total & 0xFF),
                               0x00, 0x00, 0x40, 0x00, 64, 6, 0x00, 0x00])
        ip.append(contentsOf: IPv4Packet.bytes(of: source))
        ip.append(contentsOf: IPv4Packet.bytes(of: destination))
        let headerChecksum = IPv4Packet.checksum(ip)
        ip[10] = UInt8(headerChecksum >> 8 & 0xFF)
        ip[11] = UInt8(headerChecksum & 0xFF)
        return ip + tcp
    }

    func testHandshakeCarriesBytesBothWaysAndCloses() async throws {
        let echo = try await EchoServer.start()
        defer { echo.stop() }

        let clientAddress: UInt32 = 0x0A070002   // 10.7.0.2
        let relayAddress: UInt32 = 0x0A070001    // 10.7.0.1 (the tunnel side)
        let anyHost: UInt32 = 0x01010101         // the relay dials the echo server, not this

        let relay = TunTCPRelay(localAddress: relayAddress) { _, _ in
            try await NetSocket.connect(host: "127.0.0.1", port: echo.port, timeout: 3)
        }
        let inbox = Inbox()
        relay.emit = { inbox.append($0) }

        let clientISN: UInt32 = 1000
        let clientPort: UInt16 = 51000
        relay.handle(packet: ipPacket(source: clientAddress, destination: anyHost,
                                      sourcePort: clientPort, destinationPort: 443,
                                      sequence: clientISN, acknowledgement: 0,
                                      flags: TCPSegment.flagSYN, payload: Data()))

        guard let synAckPacket = await inbox.next(timeout: 3),
              let synAckIP = IPv4Packet(synAckPacket),
              let synAck = TCPSegment(synAckIP.payload) else {
            return XCTFail("no SYN-ACK")
        }
        XCTAssertTrue(synAck.isSYN && synAck.isACK, "expected SYN-ACK")
        XCTAssertEqual(synAck.acknowledgement, clientISN &+ 1)
        let ourISN = synAck.sequence

        let payload = Data("hello tunnel".utf8)
        relay.handle(packet: ipPacket(source: clientAddress, destination: anyHost,
                                      sourcePort: clientPort, destinationPort: 443,
                                      sequence: clientISN &+ 1, acknowledgement: ourISN &+ 1,
                                      flags: TCPSegment.flagACK | TCPSegment.flagPSH,
                                      payload: payload))

        // The echo server sends the same bytes back; the relay must deliver them.
        var echoed = Data()
        let deadline = Date().addingTimeInterval(4)
        while echoed.count < payload.count, Date() < deadline {
            guard let packet = await inbox.next(timeout: 1),
                  let ip = IPv4Packet(packet),
                  let segment = TCPSegment(ip.payload) else { continue }
            if segment.isACK, !segment.payload.isEmpty {
                XCTAssertEqual(segment.acknowledgement, clientISN &+ 1 &+ UInt32(payload.count),
                               "the relay must acknowledge the bytes it consumed")
                echoed.append(segment.payload)
            }
        }
        XCTAssertEqual(echoed, payload, "echoed bytes must come back through the relay")

        relay.handle(packet: ipPacket(source: clientAddress, destination: anyHost,
                                      sourcePort: clientPort, destinationPort: 443,
                                      sequence: clientISN &+ 1 &+ UInt32(payload.count),
                                      acknowledgement: ourISN &+ 1 &+ UInt32(echoed.count),
                                      flags: TCPSegment.flagFIN | TCPSegment.flagACK,
                                      payload: Data()))
        XCTAssertEqual(relay.activeFlows, 0, "the flow must be gone after FIN")
    }

    /// A packet for a flow the relay does not know must be refused, not dropped.
    func testUnknownFlowIsReset() async throws {
        let relay = TunTCPRelay { _, _ in throw LeapinError.timeout }
        let inbox = Inbox()
        relay.emit = { inbox.append($0) }

        relay.handle(packet: ipPacket(source: 0x0A070002, destination: 0x01010101,
                                      sourcePort: 40000, destinationPort: 80,
                                      sequence: 7, acknowledgement: 0,
                                      flags: TCPSegment.flagACK, payload: Data("x".utf8)))
        guard let packet = await inbox.next(timeout: 2),
              let ip = IPv4Packet(packet),
              let segment = TCPSegment(ip.payload) else {
            return XCTFail("no reset")
        }
        XCTAssertTrue(segment.isRST, "an unknown flow must be reset")
    }
}

/// Collects packets the relay emits, asynchronously, and hands them out one by one.
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []
    private var waiters: [(UUID, CheckedContinuation<Data?, Never>)] = []

    func append(_ packet: Data) {
        lock.lock()
        if !waiters.isEmpty {
            let (_, waiter) = waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: packet)
            return
        }
        packets.append(packet)
        lock.unlock()
    }

    func next(timeout: TimeInterval) async -> Data? {
        lock.lock()
        if !packets.isEmpty {
            let packet = packets.removeFirst()
            lock.unlock()
            return packet
        }
        let id = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            waiters.append((id, continuation))
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if let index = self.waiters.firstIndex(where: { $0.0 == id }) {
                    let (_, waiter) = self.waiters.remove(at: index)
                    self.lock.unlock()
                    waiter.resume(returning: nil)
                } else {
                    self.lock.unlock()
                }
            }
        }
    }
}

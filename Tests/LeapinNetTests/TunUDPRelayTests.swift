import XCTest
@testable import LeapinCore
@testable import LeapinNet
import Darwin

/// UDP half of the tunnel: a datagram in must reach the destination and the answer
/// must come back as a well-formed packet with the ports swapped.
final class TunUDPRelayTests: XCTestCase {

    private func makeEchoServer() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        return (fd, actual.sin_port.bigEndian)
    }

    private func clientPacket(source: UInt32, destination: UInt32,
                              sourcePort: UInt16, destinationPort: UInt16,
                              payload: Data) -> Data {
        let total = 20 + 8 + payload.count
        var packet = Data()
        packet.append(contentsOf: [0x45, 0x00, UInt8(total >> 8 & 0xFF), UInt8(total & 0xFF),
                                   0x00, 0x00, 0x40, 0x00, 64, 17, 0x00, 0x00])
        packet.append(contentsOf: IPv4Packet.bytes(of: source))
        packet.append(contentsOf: IPv4Packet.bytes(of: destination))
        packet.append(contentsOf: [UInt8(sourcePort >> 8), UInt8(sourcePort & 0xFF),
                                   UInt8(destinationPort >> 8), UInt8(destinationPort & 0xFF),
                                   UInt8((8 + payload.count) >> 8), UInt8((8 + payload.count) & 0xFF),
                                   0x00, 0x00])
        packet.append(payload)
        let checksum = IPv4Packet.checksum(packet)
        packet[10] = UInt8(checksum >> 8 & 0xFF)
        packet[11] = UInt8(checksum & 0xFF)
        return packet
    }

    func testDatagramRoundTrip() async throws {
        let server = try makeEchoServer()
        defer { close(server.fd) }

        let echo = Thread {
            var buffer = [UInt8](repeating: 0, count: 2048)
            while true {
                var peer = sockaddr_storage()
                var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let read = buffer.withUnsafeMutableBytes { raw in
                    withUnsafeMutablePointer(to: &peer) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                            recvfrom(server.fd, raw.baseAddress, raw.count, 0, sockaddrPointer, &peerLength)
                        }
                    }
                }
                if read <= 0 { return }
                // Echo back to whoever asked: an unconnected socket cannot send().
                _ = buffer.withUnsafeBytes { raw in
                    withUnsafePointer(to: &peer) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                            sendto(server.fd, raw.baseAddress, read, 0, sockaddrPointer, peerLength)
                        }
                    }
                }
            }
        }
        echo.start()

        let relay = TunUDPRelay()
        let inbox = Inbox()
        relay.emit = { inbox.append($0) }
        relay.start()
        defer { relay.stop() }

        let payload = Data("pong over udp".utf8)
        relay.handle(packet: clientPacket(source: 0x0A070002, destination: 0x7F000001,
                                          sourcePort: 5555, destinationPort: server.port,
                                          payload: payload))
        XCTAssertEqual(relay.activeFlows, 1)

        guard let reply = await inbox.next(timeout: 3),
              let ip = IPv4Packet(reply),
              let datagram = UDPDatagram(ip.payload) else {
            return XCTFail("no reply datagram")
        }
        XCTAssertEqual(datagram.payload, payload, "the echoed bytes must come back")
        XCTAssertEqual(datagram.sourcePort, server.port, "reply comes from the destination")
        XCTAssertEqual(datagram.destinationPort, 5555, "and goes back to the client's port")
        XCTAssertEqual(ip.protocolNumber, 17)
    }
}

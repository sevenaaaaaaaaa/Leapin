import Foundation
import LeapinCore

/// Minimal SOCKS5 client: the tunnel speaks SOCKS5 to the engine on loopback, so the
/// engine keeps owning rules, DNS and outbounds instead of the tunnel dialing itself.
public enum Socks5 {
    public static func connect(via proxyPort: UInt16, host: String, port: UInt16,
                               timeout: TimeInterval = 8) async throws -> NetSocket {
        let socket = try await NetSocket.connect(host: "127.0.0.1", port: proxyPort, timeout: timeout)
        let stream = BufferedStream(socket)
        do {
            try await socket.write(Data([0x05, 0x01, 0x00]))
            let greeting = try await stream.readExactly(2)
            guard greeting[greeting.startIndex] == 0x05, greeting[greeting.startIndex + 1] == 0x00 else {
                throw LeapinError.protocolError("socks5: proxy refused the greeting")
            }

            var request = Data([0x05, 0x01, 0x00, 0x03, UInt8(min(host.utf8.count, 255))])
            request.append(contentsOf: Data(host.utf8).prefix(255))
            request.append(contentsOf: [UInt8(port >> 8 & 0xFF), UInt8(port & 0xFF)])
            try await socket.write(request)

            let head = try await stream.readExactly(4)
            guard head[head.startIndex] == 0x05 else {
                throw LeapinError.protocolError("socks5: bad reply version")
            }
            guard head[head.startIndex + 1] == 0x00 else {
                throw LeapinError.connectionFailed("socks5: connect rejected (\(head[head.startIndex + 1]))")
            }
            let addressType = head[head.startIndex + 3]
            switch addressType {
            case 0x01: _ = try await stream.readExactly(4 + 2)
            case 0x04: _ = try await stream.readExactly(16 + 2)
            case 0x03:
                let length = try await stream.readExactly(1)
                _ = try await stream.readExactly(Int(length[length.startIndex]) + 2)
            default:
                throw LeapinError.protocolError("socks5: unknown address type \(addressType)")
            }
            // Anything the proxy buffered past the reply belongs to the tunnel.
            let leftover = stream.drainBuffer()
            if !leftover.isEmpty { socket.unread(leftover) }
            return socket
        } catch {
            socket.close()
            throw error
        }
    }
}

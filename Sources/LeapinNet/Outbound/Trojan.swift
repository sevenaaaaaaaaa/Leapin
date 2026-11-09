import Foundation
import LeapinCore

/// Trojan wire format (trojan-gfw): hex(SHA224(password)) CRLF CMD ATYP ADDR PORT CRLF
public enum TrojanProtocol {
    public static let connectCommand: UInt8 = 0x01
    public static let udpAssociateCommand: UInt8 = 0x03

    public static let defaultPort: UInt16 = 443

    /// Lowercase hex of SHA-224(password), the trojan handshake token.
    public static func passwordHash(_ password: String) -> String {
        SHA224.hexDigest(Data(password.utf8))
    }

    /// Builds the request head for a CONNECT (or UDP associate) request.
    public static func requestHead(password: String,
                                   host: String,
                                   port: UInt16,
                                   command: UInt8 = TrojanProtocol.connectCommand) throws -> Data {
        guard let address = SOCKS5.encodeAddress(host: host, port: port) else {
            throw LeapinError.invalidConfiguration("trojan: cannot encode target \(host):\(port)")
        }
        var out = Data(passwordHash(password).utf8)
        out.append(Data([0x0D, 0x0A]))
        out.append(command)
        out.append(address)
        out.append(Data([0x0D, 0x0A]))
        return out
    }
}

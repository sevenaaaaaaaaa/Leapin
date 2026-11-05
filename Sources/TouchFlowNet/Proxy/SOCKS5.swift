import Foundation
import TouchFlowCore

/// SOCKS5 wire helpers (RFC 1928) shared by the proxy front-end and the outbound dialer.
public enum SOCKS5 {
    public static let version: UInt8 = 0x05

    public enum Command: UInt8 {
        case connect = 0x01
        case bind = 0x02
        case udpAssociate = 0x03
    }

    public enum Reply: UInt8 {
        case succeeded = 0x00
        case generalFailure = 0x01
        case notAllowed = 0x02
        case networkUnreachable = 0x03
        case hostUnreachable = 0x04
        case connectionRefused = 0x05
        case ttlExpired = 0x06
        case commandNotSupported = 0x07
        case addressNotSupported = 0x08
    }

    public enum AddressType: UInt8 {
        case ipv4 = 0x01
        case domain = 0x03
        case ipv6 = 0x04
    }

    public enum Method: UInt8 {
        case noAuth = 0x00
        case gssapi = 0x01
        case userPass = 0x02
        case noneAcceptable = 0xFF
    }

    public static let authVersion: UInt8 = 0x01

    /// Encodes a host/port as a SOCKS5 address field (ATYP + ADDR + PORT).
    public static func encodeAddress(host: String, port: UInt16) -> Data? {
        var out = Data()
        if let v4 = NetAddress.ipv4Bytes(host) {
            out.append(AddressType.ipv4.rawValue)
            out.append(v4)
        } else if let v6 = NetAddress.ipv6Bytes(host) {
            out.append(AddressType.ipv6.rawValue)
            out.append(v6)
        } else {
            let bytes = Array(utf8: host)
            guard !bytes.isEmpty, bytes.count <= 255 else { return nil }
            out.append(AddressType.domain.rawValue)
            out.append(UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(UInt8(port >> 8))
        out.append(UInt8(port & 0xFF))
        return out
    }

    public static func decodeAddress(_ stream: BufferedStream) async throws -> (host: String, port: UInt16) {
        guard let atypByte = try await stream.readByte() else {
            throw TouchFlowError.protocolError("socks5: unexpected EOF reading address type")
        }
        let host: String
        switch AddressType(rawValue: atypByte) {
        case .ipv4:
            let raw = try await stream.readExactly(4)
            guard let text = NetAddress.string(fromIPv4: raw) else {
                throw TouchFlowError.protocolError("socks5: bad IPv4 address")
            }
            host = text
        case .ipv6:
            let raw = try await stream.readExactly(16)
            guard let text = NetAddress.string(fromIPv6: raw) else {
                throw TouchFlowError.protocolError("socks5: bad IPv6 address")
            }
            host = text
        case .domain:
            guard let length = try await stream.readByte() else {
                throw TouchFlowError.protocolError("socks5: unexpected EOF reading domain length")
            }
            let raw = try await stream.readExactly(Int(length))
            host = String(decoding: raw, as: UTF8.self)
        case nil:
            throw TouchFlowError.protocolError("socks5: unknown address type \(atypByte)")
        }
        let portRaw = Array(try await stream.readExactly(2))
        guard portRaw.count == 2 else {
            throw TouchFlowError.protocolError("socks5: unexpected EOF reading port")
        }
        let port = UInt16(portRaw[0]) << 8 | UInt16(portRaw[1])
        return (host, port)
    }

    /// Encodes a full CONNECT request (VER CMD RSV ATYP ADDR PORT).
    public static func requestHeader(host: String, port: UInt16, command: Command = .connect) -> Data? {
        guard let address = encodeAddress(host: host, port: port) else { return nil }
        var out = Data([version, command.rawValue, 0x00])
        out.append(address)
        return out
    }

    public static func describe(replyCode: UInt8) -> String {
        switch Reply(rawValue: replyCode) {
        case .succeeded: return "succeeded"
        case .generalFailure: return "general failure"
        case .notAllowed: return "connection not allowed"
        case .networkUnreachable: return "network unreachable"
        case .hostUnreachable: return "host unreachable"
        case .connectionRefused: return "connection refused"
        case .ttlExpired: return "TTL expired"
        case .commandNotSupported: return "command not supported"
        case .addressNotSupported: return "address type not supported"
        case nil: return "unknown reply 0x\(String(replyCode, radix: 16))"
        }
    }

    /// Encodes a server reply (VER REP RSV ATYP BND.ADDR BND.PORT).
    public static func encodeReply(_ reply: Reply, boundAddress: Data? = nil) -> Data {
        var out = Data([version, reply.rawValue, 0x00])
        if let boundAddress, !boundAddress.isEmpty {
            out.append(boundAddress)
        } else {
            out.append(AddressType.ipv4.rawValue)
            out.append(contentsOf: [0, 0, 0, 0])
            out.append(contentsOf: [0, 0])
        }
        return out
    }

    /// Encodes a username/password sub-negotiation request (RFC 1929).
    public static func encodeUserPassAuth(username: String, password: String) -> Data? {
        let user = Array(utf8: username)
        let pass = Array(utf8: password)
        guard user.count <= 255, pass.count <= 255 else { return nil }
        var out = Data([authVersion, UInt8(user.count)])
        out.append(contentsOf: user)
        out.append(UInt8(pass.count))
        out.append(contentsOf: pass)
        return out
    }
}

extension UInt16 {
    var networkBytes: [UInt8] { [UInt8(self >> 8), UInt8(self & 0xFF)] }
}

extension Array where Element == UInt8 {
    init(utf8 text: String) {
        self = Array(text.utf8)
    }

    var data: Data { Data(self) }
}

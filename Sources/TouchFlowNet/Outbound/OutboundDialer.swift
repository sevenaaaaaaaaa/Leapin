import Foundation
import Network
import TouchFlowCore

/// Opens outbound ByteStreams for every supported proxy protocol.
public struct OutboundDialer: Sendable {
    private let resolver: NameResolving
    private let connectTimeout: TimeInterval

    public init(resolver: NameResolving) {
        self.resolver = resolver
        self.connectTimeout = 10
    }

    public func connect(via outbound: OutboundConfig, host: String, port: UInt16) async throws -> ByteStream {
        switch outbound.type {
        case .direct:
            return try await openTCP(host: host, port: port, tls: nil, label: "direct")

        case .reject:
            throw TouchFlowError.blocked("outbound \(outbound.name) rejects \(host):\(port)")

        case .http:
            return try await connectHTTP(outbound: outbound, host: host, port: port)

        case .socks5:
            return try await connectSOCKS5(outbound: outbound, host: host, port: port)

        case .shadowsocks:
            return try await connectShadowsocks(outbound: outbound, host: host, port: port)

        case .trojan:
            return try await connectTrojan(outbound: outbound, host: host, port: port)

        case .vmess, .vless, .hysteria, .hysteria2, .tuic, .wireguard, .snell:
            // Imported verbatim so profiles round-trip; dialing is not implemented yet.
            throw TouchFlowError.invalidConfiguration(
                "outbound \(outbound.name): protocol '\(outbound.rawType ?? outbound.type.rawValue)' is not dialable yet")

        case .unsupported:
            throw TouchFlowError.invalidConfiguration(
                "outbound \(outbound.name): unknown protocol '\(outbound.rawType ?? "?")'")
        }
    }

    // MARK: - direct

    private func openTCP(host: String, port: UInt16, tls: NWProtocolTLS.Options?, label: String) async throws -> NetSocket {
        let candidates = try await resolveCandidates(host)
        var lastError: Error = TouchFlowError.connectionFailed("\(label): no address for \(host)")
        for address in candidates {
            do {
                let socket = try await NetSocket.connect(host: address, port: port, timeout: connectTimeout, tls: tls)
                return socket
            } catch {
                lastError = error
                TFLog.shared.debug("outbound", "\(label): connect \(address):\(port) failed: \(error.localizedDescription)")
            }
        }
        throw lastError
    }

    private func resolveCandidates(_ host: String) async throws -> [String] {
        if NetAddress.isIPLiteral(host) { return [host] }
        let addresses = try await resolver.resolve(host)
        guard !addresses.isEmpty else {
            throw TouchFlowError.connectionFailed("resolve \(host) returned no address")
        }
        return addresses
    }

    private func resolveServerHost(_ outbound: OutboundConfig) async throws -> [String] {
        guard !outbound.host.isEmpty else {
            throw TouchFlowError.invalidConfiguration("outbound \(outbound.name) has no server host")
        }
        guard outbound.port != 0 else {
            throw TouchFlowError.invalidConfiguration("outbound \(outbound.name) has no server port")
        }
        return try await resolveCandidates(outbound.host)
    }

    private func openServerConnection(_ outbound: OutboundConfig, tls: NWProtocolTLS.Options?) async throws -> NetSocket {
        let candidates = try await resolveServerHost(outbound)
        var lastError: Error = TouchFlowError.connectionFailed("\(outbound.name): cannot connect to \(outbound.host):\(outbound.port)")
        for address in candidates {
            do {
                return try await NetSocket.connect(host: address, port: outbound.port, timeout: connectTimeout, tls: tls)
            } catch {
                lastError = error
                TFLog.shared.debug("outbound", "\(outbound.name): \(address):\(outbound.port) failed: \(error.localizedDescription)")
            }
        }
        throw lastError
    }

    // MARK: - HTTP CONNECT

    private func connectHTTP(outbound: OutboundConfig, host: String, port: UInt16) async throws -> ByteStream {
        let tls: NWProtocolTLS.Options?
        if outbound.tls {
            tls = TLSFactory.clientOptions(serverName: outbound.sni ?? outbound.host)
        } else {
            tls = nil
        }
        let socket = try await openServerConnection(outbound, tls: tls)
        do {
            let stream = BufferedStream(socket)
            var head = "CONNECT \(host):\(port) HTTP/1.1\r\n"
            head += "Host: \(host):\(port)\r\n"
            if let username = outbound.username, !username.isEmpty {
                let password = outbound.password ?? ""
                let token = Data("\(username):\(password)".utf8).base64EncodedString()
                head += "Proxy-Authorization: Basic \(token)\r\n"
            }
            head += "Proxy-Connection: keep-alive\r\n\r\n"
            try await stream.write(Data(head.utf8))

            guard let response = try await HTTPCodec.readResponseHead(stream) else {
                throw TouchFlowError.connectionFailed("http proxy \(outbound.host): closed before CONNECT reply")
            }
            guard response.status == 200 else {
                throw TouchFlowError.connectionFailed(
                    "http proxy \(outbound.host) refused CONNECT \(host):\(port): HTTP \(response.status) \(response.reason)")
            }
            // Anything already buffered belongs to the tunnel.
            let leftover = stream.drainBuffer()
            if !leftover.isEmpty { socket.unread(leftover) }
            return socket
        } catch {
            socket.close()
            throw error
        }
    }

    // MARK: - SOCKS5

    private func connectSOCKS5(outbound: OutboundConfig, host: String, port: UInt16) async throws -> ByteStream {
        let socket = try await openServerConnection(outbound, tls: nil)
        do {
            let stream = BufferedStream(socket)
            let useAuth = !(outbound.username ?? "").isEmpty
            let methods: [UInt8] = useAuth ? [SOCKS5.Method.noAuth.rawValue, SOCKS5.Method.userPass.rawValue] : [SOCKS5.Method.noAuth.rawValue]
            var greeting = Data([SOCKS5.version, UInt8(methods.count)])
            greeting.append(contentsOf: methods)
            try await stream.write(greeting)

            guard let reply = try await stream.readExactly(2).nilIfEmpty else {
                throw TouchFlowError.connectionFailed("socks5 \(outbound.host): closed during method negotiation")
            }
            let replyBytes = Array(reply)
            guard replyBytes[0] == SOCKS5.version else {
                throw TouchFlowError.connectionFailed("socks5 \(outbound.host): bad version \(replyBytes[0])")
            }
            switch replyBytes[1] {
            case SOCKS5.Method.noAuth.rawValue:
                break
            case SOCKS5.Method.userPass.rawValue:
                guard outbound.username != nil else {
                    throw TouchFlowError.connectionFailed("socks5 \(outbound.host): server requires authentication")
                }
                guard let auth = SOCKS5.encodeUserPassAuth(username: outbound.username ?? "", password: outbound.password ?? "") else {
                    throw TouchFlowError.invalidConfiguration("socks5 username/password too long")
                }
                try await stream.write(auth)
                guard let authReply = try await stream.readExactly(2).nilIfEmpty else {
                    throw TouchFlowError.connectionFailed("socks5 \(outbound.host): closed during authentication")
                }
                let authBytes = Array(authReply)
                guard authBytes[1] == 0x00 else {
                    throw TouchFlowError.connectionFailed("socks5 \(outbound.host): authentication rejected")
                }
            default:
                throw TouchFlowError.connectionFailed("socks5 \(outbound.host): no acceptable auth method")
            }

            guard let request = SOCKS5.requestHeader(host: host, port: port) else {
                throw TouchFlowError.invalidConfiguration("socks5: cannot encode target \(host):\(port)")
            }
            try await stream.write(request)
            guard let head = try await stream.readExactly(4).nilIfEmpty else {
                throw TouchFlowError.connectionFailed("socks5 \(outbound.host): closed during CONNECT reply")
            }
            let headBytes = Array(head)
            guard headBytes[0] == SOCKS5.version else {
                throw TouchFlowError.connectionFailed("socks5 \(outbound.host): bad reply version \(headBytes[0])")
            }
            guard headBytes[1] == 0x00 else {
                throw TouchFlowError.connectionFailed(
                    "socks5 \(outbound.host): CONNECT failed with code \(headBytes[1]) \(SOCKS5.describe(replyCode: headBytes[1]))")
            }
            // Consume the bound address so the tunnel starts clean.
            let atyp = headBytes[3]
            switch atyp {
            case SOCKS5.AddressType.ipv4.rawValue:
                _ = try await stream.readExactly(4 + 2)
            case SOCKS5.AddressType.ipv6.rawValue:
                _ = try await stream.readExactly(16 + 2)
            case SOCKS5.AddressType.domain.rawValue:
                let lengthData = try await stream.readExactly(1)
                let length = Int(Array(lengthData).first ?? 0)
                _ = try await stream.readExactly(length + 2)
            default:
                throw TouchFlowError.protocolError("socks5 \(outbound.host): unknown bound address type \(atyp)")
            }
            let leftover = stream.drainBuffer()
            if !leftover.isEmpty { socket.unread(leftover) }
            return socket
        } catch {
            socket.close()
            throw error
        }
    }

    // MARK: - Shadowsocks

    private func connectShadowsocks(outbound: OutboundConfig, host: String, port: UInt16) async throws -> ByteStream {
        guard let cipherName = outbound.cipher, let cipher = ShadowsocksCipher(cipherName) else {
            throw TouchFlowError.unsupported("shadowsocks cipher \(outbound.cipher ?? "nil") is not supported (aes-256-gcm, chacha20-ietf-poly1305)")
        }
        guard let password = outbound.password, !password.isEmpty else {
            throw TouchFlowError.invalidConfiguration("shadowsocks outbound \(outbound.name) has no password")
        }
        let socket = try await openServerConnection(outbound, tls: nil)
        let stream = ShadowsocksStream(base: socket, password: password, cipher: cipher)
        do {
            guard let address = SOCKS5.encodeAddress(host: host, port: port) else {
                throw TouchFlowError.invalidConfiguration("shadowsocks: cannot encode target \(host):\(port)")
            }
            try await stream.write(address)
            return stream
        } catch {
            stream.close()
            throw error
        }
    }

    // MARK: - Trojan

    private func connectTrojan(outbound: OutboundConfig, host: String, port: UInt16) async throws -> ByteStream {
        guard let password = outbound.password, !password.isEmpty else {
            throw TouchFlowError.invalidConfiguration("trojan outbound \(outbound.name) has no password")
        }
        let serverName = outbound.sni ?? outbound.host
        let options = TLSFactory.clientOptions(serverName: serverName)
        let socket = try await openServerConnection(outbound, tls: options)
        do {
            let head = try TrojanProtocol.requestHead(password: password, host: host, port: port)
            try await socket.write(head)
            return socket
        } catch {
            socket.close()
            throw error
        }
    }
}

private extension Data {
    var nilIfEmpty: Data? { isEmpty ? nil : self }
}

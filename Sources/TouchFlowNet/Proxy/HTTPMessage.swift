import Foundation
import TouchFlowCore

// MARK: - Headers

/// Ordered, case-insensitive HTTP header collection.
public struct HTTPHeaders: Sendable, Equatable {
    public private(set) var items: [(name: String, value: String)]

    public init() {
        self.items = []
    }

    public init(_ items: [(String, String)]) {
        self.items = items.map { (name: $0.0, value: $0.1) }
    }

    public var isEmpty: Bool { items.isEmpty }

    public static func == (lhs: HTTPHeaders, rhs: HTTPHeaders) -> Bool {
        guard lhs.items.count == rhs.items.count else { return false }
        for index in lhs.items.indices {
            if lhs.items[index].name != rhs.items[index].name { return false }
            if lhs.items[index].value != rhs.items[index].value { return false }
        }
        return true
    }

    public func first(_ name: String) -> String? {
        let key = name.lowercased()
        for item in items where item.name.lowercased() == key { return item.value }
        return nil
    }

    public func all(_ name: String) -> [String] {
        let key = name.lowercased()
        return items.filter { $0.name.lowercased() == key }.map(\.value)
    }

    public func contains(_ name: String) -> Bool { first(name) != nil }

    public mutating func add(_ name: String, _ value: String) {
        items.append((name: name, value: value))
    }

    public mutating func set(_ name: String, _ value: String) {
        remove(name)
        items.append((name: name, value: value))
    }

    public mutating func remove(_ name: String) {
        let key = name.lowercased()
        items.removeAll { $0.name.lowercased() == key }
    }

    public var dictionary: [String: String] {
        var out: [String: String] = [:]
        for item in items { out[item.name] = item.value }
        return out
    }

    public func serialized() -> Data {
        var text = ""
        for item in items {
            text += "\(item.name): \(item.value)\r\n"
        }
        return Data(text.utf8)
    }
}

// MARK: - Message heads

public struct HTTPRequestHead: Sendable, Equatable {
    public var method: String
    public var target: String
    public var version: String
    public var headers: HTTPHeaders

    public init(method: String, target: String, version: String = "HTTP/1.1", headers: HTTPHeaders = HTTPHeaders()) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
    }

    public var isConnect: Bool { method.uppercased() == "CONNECT" }

    /// Host and port from an `absolute-form` or `authority-form` target.
    public func targetAuthority(defaultPort: UInt16 = 80) -> (host: String, port: UInt16)? {
        var text = target
        if let schemeRange = text.range(of: "://") {
            text = String(text[schemeRange.upperBound...])
            if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
            if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
            return NetAddress.parseAuthority(text, defaultPort: defaultPort)
        }
        if isConnect {
            return NetAddress.parseAuthority(text, defaultPort: defaultPort)
        }
        return nil
    }

    public func serialized() -> Data {
        var head = "\(method) \(target) \(version)\r\n"
        for item in headers.items { head += "\(item.name): \(item.value)\r\n" }
        head += "\r\n"
        return Data(head.utf8)
    }
}

public struct HTTPResponseHead: Sendable, Equatable {
    public var version: String
    public var status: Int
    public var reason: String
    public var headers: HTTPHeaders

    public init(version: String = "HTTP/1.1", status: Int, reason: String? = nil, headers: HTTPHeaders = HTTPHeaders()) {
        self.version = version
        self.status = status
        self.reason = reason ?? HTTPStatusText.reason(for: status)
        self.headers = headers
    }

    public var serialized: Data {
        get {
            var head = "\(version) \(status) \(reason)\r\n"
            for item in headers.items { head += "\(item.name): \(item.value)\r\n" }
            head += "\r\n"
            return Data(head.utf8)
        }
    }
}

public enum HTTPStatusText {
    public static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 407: return "Proxy Authentication Required"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 421: return "Misdirected Request"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 504: return "Gateway Timeout"
        default: return "Status \(status)"
        }
    }
}

// MARK: - Body framing

public enum HTTPBodyFraming: Sendable, Equatable {
    case none
    case contentLength(Int)
    case chunked
}

// MARK: - Codec

/// Minimal HTTP/1.1 codec. Deliberately strict: no header folding, no h2.
public enum HTTPCodec {
    /// Hard cap for any single buffered body (32 MB).
    public static let bodyLimit = 32 * 1024 * 1024
    public static let headerLimit = 128 * 1024

    private static let headTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

    // MARK: Reading

    public static func readRequestHead(_ stream: BufferedStream) async throws -> HTTPRequestHead? {
        guard let raw = try await stream.readUntil(headTerminator, limit: headerLimit) else { return nil }
        if raw.count < 4 {
            throw TouchFlowError.protocolError("truncated HTTP request head (\(raw.count) bytes)")
        }
        let text = String(decoding: raw.dropLast(4), as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            throw TouchFlowError.protocolError("empty HTTP request head")
        }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3 else {
            throw TouchFlowError.protocolError("malformed request line: \(requestLine)")
        }
        let method = parts[0]
        let target = parts[1]
        let version = parts[2]
        guard version.hasPrefix("HTTP/") else {
            throw TouchFlowError.protocolError("unsupported request version: \(version)")
        }
        let headers = try parseHeaders(lines)
        return HTTPRequestHead(method: method, target: target, version: version, headers: headers)
    }

    public static func readResponseHead(_ stream: BufferedStream) async throws -> HTTPResponseHead? {
        guard let raw = try await stream.readUntil(headTerminator, limit: headerLimit) else { return nil }
        if raw.count < 4 {
            throw TouchFlowError.protocolError("truncated HTTP response head (\(raw.count) bytes)")
        }
        let text = String(decoding: raw.dropLast(4), as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            throw TouchFlowError.protocolError("empty HTTP response head")
        }
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/") else {
            throw TouchFlowError.protocolError("malformed status line: \(statusLine)")
        }
        guard let status = Int(parts[1]) else {
            throw TouchFlowError.protocolError("malformed status code: \(parts[1])")
        }
        let reason = parts.count >= 3 ? parts[2] : HTTPStatusText.reason(for: status)
        let headers = try parseHeaders(lines)
        return HTTPResponseHead(version: parts[0], status: status, reason: reason, headers: headers)
    }

    private static func parseHeaders(_ lines: [String]) throws -> HTTPHeaders {
        var headers = HTTPHeaders()
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else {
                throw TouchFlowError.protocolError("malformed header line: \(line)")
            }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                throw TouchFlowError.protocolError("empty header name")
            }
            headers.add(name, value)
        }
        return headers
    }

    // MARK: Framing

    public static func framing(for headers: HTTPHeaders, isRequest: Bool) throws -> HTTPBodyFraming {
        let transfer = headers.all("Transfer-Encoding").joined(separator: ",").lowercased()
        if transfer.contains("chunked") { return .chunked }
        if !transfer.isEmpty && !transfer.contains("identity") {
            throw TouchFlowError.unsupported("transfer-encoding: \(transfer)")
        }
        if let raw = headers.first("Content-Length") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let length = Int(trimmed), length >= 0 else {
                throw TouchFlowError.protocolError("invalid content-length: \(raw)")
            }
            if length > bodyLimit {
                throw TouchFlowError.protocolError("content-length \(length) exceeds limit \(bodyLimit)")
            }
            return length == 0 ? .none : .contentLength(length)
        }
        return .none
    }

    public static func readBody(_ stream: BufferedStream, framing: HTTPBodyFraming) async throws -> Data {
        switch framing {
        case .none:
            return Data()
        case .contentLength(let length):
            return try await stream.readExactly(length)
        case .chunked:
            var body = Data()
            while true {
                guard let line = try await stream.readLine(limit: 1024) else {
                    throw TouchFlowError.protocolError("unexpected EOF in chunk header")
                }
                let lineText = String(decoding: line, as: UTF8.self)
                let sizeText = lineText.split(separator: ";").first.map(String.init) ?? ""
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
                    throw TouchFlowError.protocolError("invalid chunk size: \(lineText)")
                }
                if size == 0 {
                    // Trailer section: consume until blank line.
                    while let trailer = try await stream.readLine(limit: headerLimit) {
                        if trailer.isEmpty { break }
                    }
                    break
                }
                if body.count + size > bodyLimit {
                    throw TouchFlowError.protocolError("chunked body exceeds limit \(bodyLimit)")
                }
                body.append(try await stream.readExactly(size))
                guard let crlf = try await stream.readExactly(2).first, crlf == 0x0D else {
                    throw TouchFlowError.protocolError("missing CRLF after chunk")
                }
            }
            return body
        }
    }

    /// Serializes a fixed-length body with its framing headers applied.
    public static func serialize(body: Data, headers: inout HTTPHeaders) -> Data {
        headers.remove("Transfer-Encoding")
        headers.set("Content-Length", String(body.count))
        return body
    }

    public static func encodeChunked(_ body: Data) -> Data {
        guard !body.isEmpty else { return Data("0\r\n\r\n".utf8) }
        var out = Data()
        out.append(Data(String(body.count, radix: 16).utf8))
        out.append(Data([0x0D, 0x0A]))
        out.append(body)
        out.append(Data([0x0D, 0x0A]))
        out.append(Data("0\r\n\r\n".utf8))
        return out
    }

    // MARK: Hop-by-hop

    public static let hopByHopHeaders: Set<String> = [
        "connection", "proxy-connection", "keep-alive", "proxy-authenticate",
        "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade"
    ]

    public static func stripHopByHop(_ headers: HTTPHeaders) -> HTTPHeaders {
        var out = HTTPHeaders()
        let extra = headers.all("Connection")
            .joined(separator: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        for item in headers.items {
            let lower = item.name.lowercased()
            if hopByHopHeaders.contains(lower) { continue }
            if extra.contains(lower) { continue }
            out.add(item.name, item.value)
        }
        return out
    }

    /// Rewrites an absolute-form request target into origin-form for upstream servers.
    public static func originFormTarget(_ target: String) -> String {
        guard let schemeRange = target.range(of: "://") else { return target }
        let rest = target[schemeRange.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return "/" }
        return String(rest[slash...])
    }
}

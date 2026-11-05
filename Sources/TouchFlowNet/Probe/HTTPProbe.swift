import Foundation
import Network
import TouchFlowCore

/// Direct HTTP probe: opens its own socket (never the system proxy, never the
/// running engine) so "the site is down" can be separated from "the proxy is
/// misconfigured". One GET, up to three redirects, byte-accurate accounting.
public enum HTTPProbe {
    public static func probe(_ urlString: String, timeoutMs: Int = 8000) async -> HTTPProbeResult {
        let started = Date()
        var result = HTTPProbeResult(url: urlString)
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var current = URL(string: trimmed),
              let scheme = current.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = current.host, !host.isEmpty else {
            result.error = "无效 URL（需要 http/https 与主机名）"
            result.elapsedMs = elapsedMs(since: started)
            return result
        }
        let budget = max(300, timeoutMs)
        var redirects = 0
        while true {
            let hop = await performOnce(current, timeoutMs: budget)
            if let address = hop.remoteAddress { result.remoteAddress = address }
            if let error = hop.error {
                result.error = error
                result.elapsedMs = elapsedMs(since: started)
                result.redirects = redirects
                return result
            }
            result.statusCode = hop.status
            result.httpVersion = hop.version
            result.headerBytes = hop.headerBytes
            result.bodyBytes = hop.bodyBytes
            result.headers = hop.headers
            result.tls = current.scheme?.lowercased() == "https"
            result.redirects = redirects
            let status = hop.status ?? 0
            if [301, 302, 303, 307, 308].contains(status),
               redirects < 3,
               let location = hop.location,
               let next = URL(string: location, relativeTo: current)?.absoluteURL {
                redirects += 1
                current = next
                continue
            }
            result.elapsedMs = elapsedMs(since: started)
            return result
        }
    }

    // MARK: - One hop

    struct Hop {
        var status: Int?
        var version: String?
        var headers: [String: String] = [:]
        var headerBytes = 0
        var bodyBytes = 0
        var location: String?
        var remoteAddress: String?
        var error: String?
    }

    /// Small shared handle so a timeout can tear the socket down while the
    /// exchange task is parked in a read continuation.
    final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var socket: NetSocket?
        private var cancelled = false
        func attach(_ socket: NetSocket) {
            lock.lock()
            self.socket = socket
            let shouldClose = cancelled
            lock.unlock()
            if shouldClose { socket.close() }
        }
        func cancel() {
            lock.lock()
            cancelled = true
            let socket = self.socket
            lock.unlock()
            socket?.close()
        }
        func isCancelled() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
    }

    private static func performOnce(_ url: URL, timeoutMs: Int) async -> Hop {
        let handle = Handle()
        return await withTaskGroup(of: Hop.self) { group in
            group.addTask { await exchange(url, timeoutMs: timeoutMs, handle: handle) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(200, timeoutMs)) * 1_000_000)
                guard !handle.isCancelled() else { return Hop() }
                handle.cancel()
                var hop = Hop()
                hop.error = "超时 \(timeoutMs) ms"
                return hop
            }
            let first = await group.next() ?? Hop()
            group.cancelAll()
            handle.cancel()
            return first
        }
    }

    private static func exchange(_ url: URL, timeoutMs: Int, handle: Handle) async -> Hop {
        var hop = Hop()
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host else {
            hop.error = "无效 URL"
            return hop
        }
        let tls = scheme == "https"
        let port = UInt16(clamping: url.port ?? (tls ? 443 : 80))
        let target = (url.path.isEmpty ? "/" : url.path) + (url.query.map { "?" + $0 } ?? "")
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        let request = "GET \(target) HTTP/1.1\r\n"
            + "Host: \(hostHeader)\r\n"
            + "User-Agent: tfctl-probe/3\r\n"
            + "Accept: */*\r\n"
            + "Connection: close\r\n\r\n"
        do {
            let tlsOptions: NWProtocolTLS.Options? = tls ? NWProtocolTLS.Options() : nil
            let socket = try await NetSocket.connect(host: host, port: port, timeout: TimeInterval(timeoutMs) / 1000, tls: tlsOptions)
            handle.attach(socket)
            defer { socket.close() }
            try await socket.write(Data(request.utf8))
            hop.remoteAddress = socket.peerAddress ?? socket.remoteDescription

            var raw = Data()
            var headerEnd: Int?
            let maxHeader = 64 * 1024
            while headerEnd == nil {
                guard let chunk = try await socket.read(maxLength: 16 * 1024), !chunk.isEmpty else { break }
                raw.append(chunk)
                if let range = raw.range(of: Data("\r\n\r\n".utf8)) {
                    headerEnd = raw.distance(from: raw.startIndex, to: range.upperBound)
                }
                if raw.count > maxHeader { break }
            }
            guard let end = headerEnd else {
                hop.error = raw.isEmpty ? "连接已关闭但未收到响应" : "响应头不完整（>64KB）"
                return hop
            }
            let head = raw.prefix(end)
            hop.headerBytes = head.count
            var body = Data(raw.dropFirst(end))
            let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
            if let statusLine = lines.first {
                let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                if parts.count >= 2 {
                    hop.version = String(parts[0])
                    hop.status = Int(parts[1])
                }
            }
            for line in lines.dropFirst() {
                guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if hop.headers[key] == nil { hop.headers[key] = value }
            }
            hop.location = hop.headers["location"]

            let status = hop.status ?? 0
            let contentLength = hop.headers["content-length"].flatMap { Int($0) }
            let declaresChunked = hop.headers["transfer-encoding"]?.lowercased().contains("chunked") == true
            let bodyless = [204, 304].contains(status) || (contentLength == 0)
            let cap = 2 * 1024 * 1024
            if !bodyless {
                while body.count < cap {
                    if let expected = contentLength, !declaresChunked, body.count >= expected { break }
                    guard let chunk = try await socket.read(maxLength: 32 * 1024), !chunk.isEmpty else { break }
                    body.append(chunk)
                }
            }
            hop.bodyBytes = body.count
            return hop
        } catch {
            hop.error = Self.describe(error)
            return hop
        }
    }

    private static func describe(_ error: Error) -> String {
        if let tf = error as? TouchFlowError {
            switch tf {
            case .timeout: return "连接超时"
            case .connectionFailed(let message): return "连接失败：\(message)"
            case .protocolError(let message): return "协议错误：\(message)"
            default: return tf.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private static func elapsedMs(since start: Date) -> Double {
        (Date().timeIntervalSince(start) * 1000).rounded(toPlaces: 1)
    }
}

extension Double {
    /// Rounded to a fixed number of decimal places for stable CLI/JSON output.
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

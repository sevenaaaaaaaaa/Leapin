import Foundation
import TouchFlowCore

/// Exports captured requests as a standard HAR 1.2 document.
public enum HARExporter {
    /// Bodies larger than this are truncated in the export.
    public static let maxBodyBytes = 1_048_576

    /// Up to this size bodies go through `Redactor`'s regex rules; larger bodies
    /// use the linear scanner below (see `redactBodyText`).
    static let redactionBodyLimit = 262_144

    public static func export(_ requests: [CapturedRequest], redact: Bool = true) throws -> Data {
        var entries: [[String: Any]] = []
        entries.reserveCapacity(requests.count)

        for request in requests {
            var entry: [String: Any] = [
                "startedDateTime": iso8601(request.timestamp),
                "time": max(0, request.durationMs),
                "request": requestObject(request, redact: redact),
                "response": responseObject(request, redact: redact),
                "cache": [String: Any](),
                "timings": [
                    "blocked": -1,
                    "dns": -1,
                    "connect": -1,
                    "ssl": -1,
                    "send": 0,
                    "wait": max(0, request.durationMs),
                    "receive": 0,
                ],
            ]
            if request.blocked {
                entry["comment"] = "blocked by TouchFlow policy"
            }
            entries.append(entry)
        }

        let har: [String: Any] = [
            "log": [
                "version": "1.2",
                "creator": [
                    "name": "TouchFlow",
                    "version": "0.1.0",
                ],
                "browser": [
                    "name": "TouchFlow MITM",
                    "version": "0.1.0",
                ],
                "pages": [Any](),
                "entries": entries,
            ],
        ]

        do {
            return try JSONSerialization.data(withJSONObject: har,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw TouchFlowError.invalidConfiguration("HAR export failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Building blocks

    private static func requestObject(_ request: CapturedRequest, redact: Bool) -> [String: Any] {
        let url = redact ? Redactor.redact(request.url) : request.url
        var object: [String: Any] = [
            "method": request.method,
            "url": url,
            "httpVersion": "HTTP/1.1",
            "cookies": [Any](),
            "headers": headerArray(request.requestHeaders, redact: redact),
            // Must use the redacted URL: query parameters are where tokens live.
            "queryString": queryString(from: url),
            "headersSize": -1,
            "bodySize": request.requestBody?.count ?? 0,
        ]
        if let body = request.requestBody, !body.isEmpty {
            object["postData"] = [
                "mimeType": request.requestHeaders.first { $0.key.lowercased() == "content-type" }?.value ?? "application/octet-stream",
                "text": bodyText(body, redact: redact),
            ]
        }
        return object
    }

    private static func responseObject(_ request: CapturedRequest, redact: Bool) -> [String: Any] {
        let headers = headerArray(request.responseHeaders, redact: redact)
        let body = request.responseBody ?? Data()
        var content: [String: Any] = [
            "size": body.count,
            "mimeType": request.mimeType
                ?? request.responseHeaders.first { $0.key.lowercased() == "content-type" }?.value
                ?? "application/octet-stream",
        ]
        if !body.isEmpty {
            let (text, truncated) = bodyText(body, redact: redact)
            content["text"] = text
            if truncated {
                content["comment"] = "body truncated to \(maxBodyBytes) bytes"
            }
        }
        return [
            "status": request.statusCode ?? (request.blocked ? 403 : 0),
            "statusText": request.blocked ? "Blocked" : HTTPStatusText.reason(for: request.statusCode ?? 0),
            "httpVersion": "HTTP/1.1",
            "cookies": [Any](),
            "headers": headers,
            "content": content,
            "redirectURL": "",
            "headersSize": -1,
            "bodySize": body.count,
        ]
    }

    private static func headerArray(_ headers: [String: String], redact: Bool) -> [[String: String]] {
        let sensitive: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie"]
        return headers.keys.sorted().map { name in
            var value = headers[name] ?? ""
            if redact, sensitive.contains(name.lowercased()) {
                // Route through Redactor so the redaction marker stays consistent.
                value = Redactor.redact("\(name): \(value)")
                    .replacingOccurrences(of: "\(name): ", with: "")
            } else if redact {
                value = Redactor.redact(value)
            }
            return ["name": name, "value": value]
        }
    }

    private static func queryString(from url: String) -> [[String: String]] {
        guard let components = URLComponents(string: url), let items = components.queryItems else {
            return []
        }
        return items.map { ["name": $0.name, "value": $0.value ?? ""] }
    }

    /// Returns the (possibly truncated) body text plus whether truncation happened.
    private static func bodyText(_ data: Data, redact: Bool) -> (String, Bool) {
        let truncated = data.count > maxBodyBytes
        let slice = truncated ? data.prefix(maxBodyBytes) : data[...]
        var text = String(decoding: slice, as: UTF8.self)
        if redact {
            text = redactBodyText(text)
        }
        return (text, truncated)
    }

    /// `Redactor` is regex based and its credential-URL rule backtracks
    /// quadratically on long unbroken tokens (minified JS, base64 blobs), which
    /// would stall the export for minutes on a body-sized input. Small bodies
    /// keep using `Redactor`; large ones go through an equivalent linear scan.
    static func redactBodyText(_ text: String) -> String {
        if text.utf8.count <= redactionBodyLimit { return Redactor.redact(text) }
        return maskSecretsLinearly(text)
    }

    /// Header names whose value runs to the end of the line.
    private static let lineSecretKeys = ["authorization:", "proxy-authorization:", "cookie:", "set-cookie:"]
    /// `key=value` pairs whose value ends at a typical delimiter.
    private static let pairSecretKeys = ["password=", "passwd=", "pwd=", "token=", "secret=", "apikey=", "api_key="]

    /// Byte-level, single-pass masking of the same secret classes `Redactor`
    /// handles, with no backtracking.
    static func maskSecretsLinearly(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return text }
        var lowered = bytes
        for index in lowered.indices where lowered[index] >= 65 && lowered[index] <= 90 {
            lowered[index] = lowered[index] &+ 32
        }
        var masked = [Bool](repeating: false, count: bytes.count)

        func maskValue(from start: Int, terminators: Set<UInt8>) {
            var begin = start
            while begin < bytes.count, bytes[begin] == 0x20 || bytes[begin] == 0x09 { begin += 1 }
            var end = begin
            while end < bytes.count, !terminators.contains(bytes[end]) { end += 1 }
            // Never cut a multi-byte scalar in half.
            while end < bytes.count, end > begin, (bytes[end] & 0xC0) == 0x80 { end += 1 }
            guard end > begin else { return }
            for index in begin..<end { masked[index] = true }
        }

        let lineTerminators: Set<UInt8> = [0x0D, 0x0A]
        let pairTerminators: Set<UInt8> = [0x26, 0x20, 0x09, 0x0D, 0x0A, 0x22, 0x27, 0x3B, 0x2C, 0x3E, 0x3C]

        for key in lineSecretKeys {
            let needle = Array(key.utf8)
            var cursor = 0
            while cursor + needle.count <= lowered.count {
                if let hit = findFirst(needle, in: lowered, from: cursor) {
                    maskValue(from: hit + needle.count, terminators: lineTerminators)
                    cursor = hit + needle.count
                } else {
                    break
                }
            }
        }
        for key in pairSecretKeys {
            let needle = Array(key.utf8)
            var cursor = 0
            while cursor + needle.count <= lowered.count {
                if let hit = findFirst(needle, in: lowered, from: cursor) {
                    maskValue(from: hit + needle.count, terminators: pairTerminators)
                    cursor = hit + needle.count
                } else {
                    break
                }
            }
        }

        guard masked.contains(true) else { return text }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        let replacement = Array("<redacted>".utf8)
        var index = 0
        while index < bytes.count {
            if masked[index] {
                while index < bytes.count, masked[index] { index += 1 }
                out.append(contentsOf: replacement)
            } else {
                out.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func findFirst(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, start <= haystack.count - needle.count else { return nil }
        var index = start
        let limit = haystack.count - needle.count
        while index <= limit {
            if haystack[index] == needle[0] {
                var matched = true
                var offset = 1
                while offset < needle.count {
                    if haystack[index + offset] != needle[offset] {
                        matched = false
                        break
                    }
                    offset += 1
                }
                if matched { return index }
            }
            index += 1
        }
        return nil
    }

    private static func bodyText(_ data: Data, redact: Bool) -> String {
        bodyText(data, redact: redact).0
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

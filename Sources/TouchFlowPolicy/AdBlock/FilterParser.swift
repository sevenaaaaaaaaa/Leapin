import Foundation

/// A single network-level filter rule. `domain == nil` marks a keyword rule whose literal
/// payload is kept in `raw`.
public struct FilterRule: Sendable, Hashable {
    public var raw: String
    public var domain: String?
    public var isException: Bool
    public var thirdPartyOnly: Bool

    public init(raw: String, domain: String? = nil, isException: Bool = false, thirdPartyOnly: Bool = false) {
        self.raw = raw
        self.domain = domain
        self.isException = isException
        self.thirdPartyOnly = thirdPartyOnly
    }

    /// True for `||domain^` style rules (matches the domain and every subdomain).
    public var isSuffixRule: Bool {
        let trimmed = raw.hasPrefix("@@") ? String(raw.dropFirst(2)) : raw
        return trimmed.hasPrefix("||")
    }
}

/// A cosmetic (element hiding) rule such as `example.com##.ad`.
public struct CosmeticRule: Sendable, Hashable {
    public var domain: String
    public var selector: String
    public var isException: Bool

    public init(domain: String, selector: String, isException: Bool = false) {
        self.domain = domain
        self.selector = selector
        self.isException = isException
    }
}

/// Parses the ABP subset TouchFlow supports plus classic hosts-file lines.
public enum FilterParser {

    public static func parse(_ text: String)
        -> (block: [FilterRule], allow: [FilterRule], cosmetic: [CosmeticRule]) {
        var block: [FilterRule] = []
        var allow: [FilterRule] = []
        var cosmetic: [CosmeticRule] = []
        block.reserveCapacity(1 << 10)

        // Byte-level line scanning: 100k-line lists must load well under a second.
        let bytes = Array(text.utf8)
        for raw in bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            var start = raw.startIndex
            var end = raw.endIndex
            while start < end, FilterParser.isBlank(raw[start]) { start += 1 }
            while end > start, FilterParser.isBlank(raw[end - 1]) { end -= 1 }
            guard start < end else { continue }
            let line = raw[start..<end]
            let first = line[line.startIndex]

            // Fast path: the dominant `||host^` / `||host` form, no `$options`.
            if first == UInt8(ascii: "|"), line.count > 3,
               line[line.startIndex + 1] == UInt8(ascii: "|"),
               let fast = fastSuffixRule(line) {
                block.append(fast)
                continue
            }
            if first == UInt8(ascii: "!") || first == UInt8(ascii: "[")
                || first == UInt8(ascii: "/") {
                continue
            }

            let text = String(decoding: line, as: UTF8.self)
            // Cosmetic rules must be checked before `#` comments.
            if let cosmeticRule = parseCosmetic(text) {
                cosmetic.append(cosmeticRule)
                continue
            }
            if first == UInt8(ascii: "#") { continue }

            if let hostsRule = parseHosts(text) {
                if hostsRule.isException { allow.append(hostsRule) } else { block.append(hostsRule) }
                continue
            }
            if let networkRule = parseNetwork(text) {
                if networkRule.isException { allow.append(networkRule) } else { block.append(networkRule) }
            }
        }
        return (block, allow, cosmetic)
    }

    static func isBlank(_ unit: UInt8) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0D || unit == 0x0B || unit == 0x0C
    }

    /// Allocation-light fast path for `||domain^` and `||domain` (no `$options`, no
    /// path, no wildcard). Anything unusual falls back to `parseNetwork`.
    static func fastSuffixRule(_ line: ArraySlice<UInt8>) -> FilterRule? {
        var index = line.startIndex + 2
        let end = line.endIndex
        guard index < end else { return nil }

        var hostBytes: [UInt8] = []
        hostBytes.reserveCapacity(end - index)
        var dots = 0
        var lastWasDot = false

        while index < end {
            let unit = line[index]
            switch unit {
            case 0x61...0x7A, 0x30...0x39, 0x2D:
                hostBytes.append(unit)
                lastWasDot = false
            case 0x41...0x5A:
                hostBytes.append(unit + 32)
                lastWasDot = false
            case 0x2E:
                if lastWasDot || hostBytes.isEmpty { return nil }
                hostBytes.append(unit)
                dots += 1
                lastWasDot = true
            case 0x5E:
                guard index == end - 1 else { return nil }
                index = end
                continue
            default:
                return nil
            }
            index += 1
        }

        guard dots > 0, !lastWasDot, hostBytes.count <= 253 else { return nil }
        let host = String(decoding: hostBytes, as: UTF8.self)
        return FilterRule(raw: String(decoding: line, as: UTF8.self), domain: host,
                          isException: false, thirdPartyOnly: false)
    }

    // MARK: - Pieces

    static func parseCosmetic(_ line: String) -> CosmeticRule? {
        let exceptionMarker = "#@#"
        let marker = "##"
        if let range = line.range(of: exceptionMarker) {
            let domain = normalizeDomainList(String(line[..<range.lowerBound]))
            let selector = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !selector.isEmpty else { return nil }
            return CosmeticRule(domain: domain.isEmpty ? "*" : domain, selector: selector, isException: true)
        }
        if let range = line.range(of: marker) {
            guard !line.contains("#?#"), !line.contains("#$#") else { return nil }
            let domain = normalizeDomainList(String(line[..<range.lowerBound]))
            let selector = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !selector.isEmpty else { return nil }
            return CosmeticRule(domain: domain.isEmpty ? "*" : domain, selector: selector, isException: false)
        }
        return nil
    }

    /// `0.0.0.0 domain` / `127.0.0.1 domain` / `::1 domain`.
    static func parseHosts(_ line: String) -> FilterRule? {
        var body = line
        if let hash = body.firstIndex(of: "#") { body = String(body[..<hash]) }
        let fields = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count >= 2 else { return nil }
        let address = fields[0]
        guard IPParse.ipv4(address) != nil || IPParse.ipv6(address) != nil else { return nil }
        let domains = fields.dropFirst().filter { $0 != "localhost" && !$0.isEmpty }
        guard let first = domains.first else { return nil }
        let domain = HostNormalizer.normalize(first)
        guard !domain.isEmpty, domain.contains(".") || domain == "localhost" else { return nil }
        return FilterRule(raw: line, domain: domain, isException: false, thirdPartyOnly: false)
    }

    static func parseNetwork(_ line: String) -> FilterRule? {
        var body = line
        var isException = false
        if body.hasPrefix("@@") {
            isException = true
            body = String(body.dropFirst(2))
        }
        var thirdPartyOnly = false
        var pattern = body
        if let dollar = body.lastIndex(of: "$") {
            let options = String(body[body.index(after: dollar)...]).lowercased()
            let parts = options.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let looksLikeOptions = parts.allSatisfy { part in
                ["third-party", "3p", "~third-party", "~3p", "document", "script", "image",
                 "stylesheet", "xmlhttprequest", "xhr", "subdocument", "popup", "all",
                 "domain", "important", "match-case", "~document"].contains(part)
                    || part.hasPrefix("domain=") || part.hasPrefix("~")
            }
            if looksLikeOptions {
                thirdPartyOnly = parts.contains("third-party") || parts.contains("3p")
                pattern = String(body[..<dollar])
            }
        }
        pattern = pattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return nil }
        if pattern == "*" || pattern == "||" { return nil }
        if pattern.hasPrefix("#") || pattern.hasPrefix("!") { return nil }

        let domain = extractDomain(pattern)
        return FilterRule(raw: line, domain: domain, isException: isException, thirdPartyOnly: thirdPartyOnly)
    }

    /// Best-effort host extraction: `||domain^`, `|http://host/path`, plain host, URL.
    static func extractDomain(_ pattern: String) -> String? {
        var body = pattern
        if body.hasPrefix("||") {
            body = String(body.dropFirst(2))
            if let cut = body.firstIndex(where: { $0 == "^" || $0 == "/" || $0 == "|" }) {
                body = String(body[..<cut])
            }
            let host = HostNormalizer.normalize(body)
            return isBareHost(host) ? host : nil
        }
        if body.hasPrefix("|") { body = String(body.dropFirst()) }
        if body.contains("://") {
            if let host = URLComponents(string: body)?.host {
                let normalized = HostNormalizer.normalize(host)
                return normalized.isEmpty ? nil : normalized
            }
            return nil
        }
        // `example.com^` / `example.com` / `*.example.com`
        var candidate = body
        if let cut = candidate.firstIndex(where: { $0 == "^" || $0 == "/" }) {
            candidate = String(candidate[..<cut])
        }
        candidate = candidate.replacingOccurrences(of: "*.", with: "")
        let host = HostNormalizer.normalize(candidate)
        return isBareHost(host) ? host : nil
    }

    static func isBareHost(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains("*"), !text.contains(" "), !text.contains("^") else { return false }
        guard text.contains(".") || text == "localhost" else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_:")
        return text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// `a.com,b.com` (ABP cosmetic domain list) -> first domain; `~a.com` -> skipped.
    static func normalizeDomainList(_ text: String) -> String {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let positive = parts.first { !$0.isEmpty && !$0.hasPrefix("~") } ?? ""
        return HostNormalizer.normalize(positive)
    }
}

import Foundation

/// One rewrite directive, parsed from a single config line.
///
/// The syntax mirrors what people already know from other network tools, so a
/// rule can be copied in without translation:
///
/// ```
/// http-request  ^https?://api\.example\.com/v1/   header-add      X-Debug 1
/// http-request  ^https?://api\.example\.com/v1/   header-del      X-Trace
/// http-request  ^https?://old\.example\.com/      redirect        https://new.example.com 302
/// http-request  ^https?://api\.example\.com/mock  mock            200 application/json {"ok":true}
/// http-response ^https?://api\.example\.com/user  body-replace    "\"vip\":false"  "\"vip\":true"
/// http-response ^https?://api\.example\.com/      header-replace  Cache-Control no-store
/// ```
public struct RewriteRule: Sendable, Hashable, Identifiable {
    public enum Phase: String, Sendable, CaseIterable {
        case request = "http-request"
        case response = "http-response"
    }

    public enum Action: String, Sendable, CaseIterable {
        case headerAdd = "header-add"
        case headerDel = "header-del"
        case headerReplace = "header-replace"
        case bodyReplace = "body-replace"
        case redirect
        case mock
    }

    public var phase: Phase
    /// Regular expression matched against the absolute URL.
    public var pattern: String
    public var action: Action

    public var headerName: String?
    public var headerValue: String?
    public var search: String?
    public var replacement: String?
    public var target: String?
    public var status: Int?
    public var contentType: String?
    public var mockBody: String?
    /// The line as the user wrote it — kept for diagnostics and the UI list.
    public var raw: String

    public var id: String { raw }

    public init(phase: Phase, pattern: String, action: Action, headerName: String? = nil,
                headerValue: String? = nil, search: String? = nil, replacement: String? = nil,
                target: String? = nil, status: Int? = nil, contentType: String? = nil,
                mockBody: String? = nil, raw: String) {
        self.phase = phase
        self.pattern = pattern
        self.action = action
        self.headerName = headerName
        self.headerValue = headerValue
        self.search = search
        self.replacement = replacement
        self.target = target
        self.status = status
        self.contentType = contentType
        self.mockBody = mockBody
        self.raw = raw
    }

    /// Human summary for the rules list.
    public var summary: String {
        switch action {
        case .headerAdd: return "添加头 \(headerName ?? "")"
        case .headerDel: return "删除头 \(headerName ?? "")"
        case .headerReplace: return "改头 \(headerName ?? "")"
        case .bodyReplace: return "替换正文"
        case .redirect: return "重定向 → \(target ?? "")"
        case .mock: return "Mock \(status ?? 200)"
        }
    }
}

/// Ordered, case-insensitive header bag the rewrite engine works on.
///
/// The proxy layer has its own `HTTPHeaders`; this type keeps `LeapinCore` free of
/// a dependency on the network module and keeps the engine unit-testable.
public struct RewriteHeaders: Sendable {
    public private(set) var items: [(name: String, value: String)]

    public init(_ items: [(String, String)] = []) {
        self.items = items.map { (name: $0.0, value: $0.1) }
    }

    public func first(_ name: String) -> String? {
        let key = name.lowercased()
        for item in items where item.name.lowercased() == key { return item.value }
        return nil
    }

    /// Replace when present, append otherwise.
    public mutating func set(_ name: String, _ value: String) {
        let key = name.lowercased()
        if let index = items.firstIndex(where: { $0.name.lowercased() == key }) {
            items[index].value = value
        } else {
            items.append((name: name, value: value))
        }
    }

    /// Append without touching an existing header of the same name.
    public mutating func add(_ name: String, _ value: String) {
        items.append((name: name, value: value))
    }

    public mutating func remove(_ name: String) {
        let key = name.lowercased()
        items.removeAll { $0.name.lowercased() == key }
    }
}

/// Result of applying request-phase rules.
public enum RequestRewrite: Sendable {
    /// Continue upstream with (possibly) changed headers, body and URL.
    case proceed(headers: RewriteHeaders, body: Data, url: String?)
    /// Answer locally without dialing the origin (Mock).
    case respond(status: Int, contentType: String, body: Data)
    /// Answer with a redirect.
    case redirect(url: String, status: Int)
}

/// Compiled rewrite rules. Building one validates every line once so the hot path
/// only runs regex matches.
public final class RewriteEngine: @unchecked Sendable {
    public struct Issue: Sendable, Hashable, Error {
        public var line: String
        public var reason: String
    }

    private struct Compiled: @unchecked Sendable {
        let rule: RewriteRule
        let regex: NSRegularExpression
    }

    private let requestRules: [Compiled]
    private let responseRules: [Compiled]
    public let issues: [Issue]
    public let ruleCount: Int

    public var isEmpty: Bool { ruleCount == 0 }

    public init(lines: [String]) {
        var request: [Compiled] = []
        var response: [Compiled] = []
        var found: [Issue] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            switch Self.parse(line) {
            case .success(let rule):
                guard let regex = try? NSRegularExpression(pattern: rule.pattern) else {
                    found.append(Issue(line: line, reason: "正则表达式无效"))
                    continue
                }
                let compiled = Compiled(rule: rule, regex: regex)
                if rule.phase == .request { request.append(compiled) } else { response.append(compiled) }
            case .failure(let issue):
                found.append(issue)
            }
        }
        self.requestRules = request
        self.responseRules = response
        self.issues = found
        self.ruleCount = request.count + response.count
    }

    // MARK: - Apply

    /// Request phase: header edits, redirects and Mock short-circuits.
    public func applyToRequest(url: String, headers: RewriteHeaders, body: Data) -> RequestRewrite {
        var headers = headers
        var body = body
        var newURL: String?

        for compiled in requestRules {
            guard matches(compiled, url: url) else { continue }
            let rule = compiled.rule
            switch rule.action {
            case .headerAdd:
                if let name = rule.headerName, let value = rule.headerValue { headers.add(name, value) }
            case .headerDel:
                if let name = rule.headerName { headers.remove(name) }
            case .headerReplace:
                if let name = rule.headerName, let value = rule.headerValue { headers.set(name, value) }
            case .bodyReplace:
                body = Self.replace(rule: rule, in: body)
            case .redirect:
                if let target = rule.target {
                    return .redirect(url: target, status: rule.status ?? 302)
                }
            case .mock:
                return .respond(status: rule.status ?? 200,
                                contentType: rule.contentType ?? "application/json",
                                body: Data((rule.mockBody ?? "").utf8))
            }
        }
        _ = newURL
        return .proceed(headers: headers, body: body, url: nil)
    }

    /// Response phase: header edits and body replacement. Mock here overrides the
    /// origin response, which is how "fake this endpoint" works for POST APIs.
    public func applyToResponse(url: String, headers: RewriteHeaders, body: Data) -> (headers: RewriteHeaders, body: Data, mocked: Bool) {
        var headers = headers
        var body = body
        var mocked = false

        for compiled in responseRules {
            guard matches(compiled, url: url) else { continue }
            let rule = compiled.rule
            switch rule.action {
            case .headerAdd:
                if let name = rule.headerName, let value = rule.headerValue { headers.add(name, value) }
            case .headerDel:
                if let name = rule.headerName { headers.remove(name) }
            case .headerReplace:
                if let name = rule.headerName, let value = rule.headerValue { headers.set(name, value) }
            case .bodyReplace:
                body = Self.replace(rule: rule, in: body)
            case .mock:
                body = Data((rule.mockBody ?? "").utf8)
                headers.set("Content-Type", rule.contentType ?? "application/json")
                headers.remove("Content-Encoding")
                headers.set("Content-Length", String(body.count))
                mocked = true
            case .redirect:
                break // redirect is a request-phase action
            }
        }
        return (headers, body, mocked)
    }

    // MARK: - Helpers

    private func matches(_ compiled: Compiled, url: String) -> Bool {
        let range = NSRange(url.startIndex..<url.endIndex, in: url)
        return compiled.regex.firstMatch(in: url, range: range) != nil
    }

    private static func replace(rule: RewriteRule, in body: Data) -> Data {
        guard let needle = rule.search, let replacement = rule.replacement,
              let text = String(data: body, encoding: .utf8) else { return body }
        let updated = text.replacingOccurrences(of: needle, with: replacement)
        return updated == text ? body : Data(updated.utf8)
    }

    // MARK: - Parsing

    public static func parse(_ line: String) -> Result<RewriteRule, Issue> {
        let tokens = tokenize(line)
        guard tokens.count >= 3 else {
            return .failure(Issue(line: line, reason: "至少需要「阶段 匹配 动作」三段"))
        }
        guard let phase = RewriteRule.Phase(rawValue: tokens[0]) else {
            return .failure(Issue(line: line, reason: "阶段必须是 http-request 或 http-response"))
        }
        guard let action = RewriteRule.Action(rawValue: tokens[2]) else {
            return .failure(Issue(line: line, reason: "未知动作 \(tokens[2])"))
        }
        let pattern = tokens[1]
        let rest = Array(tokens.dropFirst(3))

        func invalid(_ reason: String) -> Result<RewriteRule, Issue> {
            .failure(Issue(line: line, reason: reason))
        }

        switch action {
        case .headerAdd, .headerReplace:
            guard rest.count >= 2 else { return invalid("\(action.rawValue) 需要「头名 值」") }
            return .success(RewriteRule(phase: phase, pattern: pattern, action: action,
                                        headerName: rest[0],
                                        headerValue: rest.dropFirst().joined(separator: " "),
                                        raw: line))
        case .headerDel:
            guard let name = rest.first else { return invalid("header-del 需要头名") }
            return .success(RewriteRule(phase: phase, pattern: pattern, action: action,
                                        headerName: name, raw: line))
        case .bodyReplace:
            guard rest.count >= 2 else { return invalid("body-replace 需要「被替换文本 替换为」") }
            return .success(RewriteRule(phase: phase, pattern: pattern, action: action,
                                        search: rest[0],
                                        replacement: rest.dropFirst().joined(separator: " "),
                                        raw: line))
        case .redirect:
            guard let target = rest.first else { return invalid("redirect 需要目标 URL") }
            let status = rest.count >= 2 ? Int(rest[1]) ?? 302 : 302
            return .success(RewriteRule(phase: phase, pattern: pattern, action: action,
                                        target: target, status: status, raw: line))
        case .mock:
            guard rest.count >= 2, let status = Int(rest[0]) else {
                return invalid("mock 需要「状态码 内容类型 正文」，例如 200 application/json {}")
            }
            let contentType = rest[1]
            let body = rest.dropFirst(2).joined(separator: " ")
            return .success(RewriteRule(phase: phase, pattern: pattern, action: action,
                                        status: status, contentType: contentType,
                                        mockBody: body, raw: line))
        }
    }

    /// Splits on whitespace. A double quote only opens a quoted token when it is the
    /// first character of that token, so JSON bodies like `{"ok":true}` keep their
    /// quotes while `"a b"` still groups a phrase. Backslash escapes inside quotes.
    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var escaping = false

        for character in line {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" && inQuotes {
                escaping = true
                continue
            }
            if character == "\"" {
                if inQuotes { inQuotes = false }
                else if current.isEmpty { inQuotes = true }
                else { current.append(character) }   // literal, e.g. inside JSON
                continue
            }
            if character == " " || character == "\t" {
                if inQuotes {
                    current.append(character)
                } else if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

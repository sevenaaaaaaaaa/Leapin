import Foundation
import TouchFlowCore

public enum RuleParseError: Error, LocalizedError, Equatable, Sendable {
    case empty
    case unknownType(String)
    case missingValue(String)
    case missingPolicy(String)
    case invalidValue(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "Empty rule"
        case .unknownType(let t): return "Unknown rule type: \(t)"
        case .missingValue(let line): return "Missing rule value: \(line)"
        case .missingPolicy(let line): return "Missing rule policy: \(line)"
        case .invalidValue(let v): return "Invalid rule value: \(v)"
        }
    }
}

/// Parser for the Surge / Clash rule line dialect used by TouchFlow profiles.
public enum RuleParser {

    // MARK: - Parse

    public static func parse(line: String) throws -> Rule {
        var text = stripComment(line).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw RuleParseError.empty }
        while text.hasPrefix("- ") {
            text = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        if text == "-" || text.isEmpty { throw RuleParseError.empty }
        // YAML list items are often quoted as a whole: `- "IP-CIDR,10.0.0.0/8,PROXY,no-resolve"`.
        text = unquote(text)

        let tokens = splitTopLevel(text).map(unquote)
        guard var typeToken = tokens.first, !typeToken.isEmpty else { throw RuleParseError.empty }
        var negate = false
        if typeToken.hasPrefix("!") {
            negate = true
            typeToken = String(typeToken.dropFirst())
        }
        guard let kind = resolveKind(typeToken) else { throw RuleParseError.unknownType(typeToken) }

        if kind == .match {
            guard tokens.count >= 2, !tokens[1].isEmpty else { throw RuleParseError.missingPolicy(text) }
            let modifiers = tokens.count > 2 ? tokens[2...].map(normalizeModifier) : []
            return Rule(kind: .match, value: "", policy: tokens[1],
                        modifiers: Array(modifiers), negate: negate, raw: text)
        }

        guard tokens.count >= 2, !tokens[1].isEmpty else { throw RuleParseError.missingValue(text) }
        let rawValue = tokens[1]
        // Rules inside rule-set files are policy-less: "DOMAIN-SUFFIX,ads.com".
        let policy = tokens.count >= 3 ? tokens[2] : ""
        let modifiers = tokens.count > 3 ? tokens[3...].map(normalizeModifier) : []
        return try makeRule(kind: kind, rawValue: rawValue, policy: policy,
                            modifiers: Array(modifiers), negate: negate, raw: text)
    }

    /// Non-throwing convenience used by UI importers.
    public static func parseRule(_ line: String) -> Rule? {
        try? parse(line: line)
    }

    public static func parseRules(_ text: String) -> (rules: [Rule], errors: [String]) {
        var rules: [Rule] = []
        var errors: [String] = []
        var number = 0
        for rawLine in text.components(separatedBy: .newlines) {
            number += 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") { continue }
            if trimmed == "rules:" { continue }
            do {
                let rule = try parse(line: rawLine)
                rules.append(rule)
            } catch RuleParseError.empty {
                continue
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                errors.append("line \(number): \(message)")
            }
        }
        return (rules, errors)
    }

    // MARK: - Export

    public static func exportSurge(_ rules: [Rule]) -> String {
        rules.map { exportLine($0, matchToken: "FINAL") }.joined(separator: "\n")
    }

    public static func exportClash(_ rules: [Rule]) -> String {
        rules.map { exportLine($0, matchToken: "MATCH") }.joined(separator: "\n")
    }

    static func exportLine(_ rule: Rule, matchToken: String) -> String {
        if rule.kind == .match { return "\(matchToken),\(rule.policy)" }
        var token = typeToken(for: rule.kind)
        if rule.negate { token = "!" + token }
        var fields = [token, rule.value, rule.policy]
        fields.append(contentsOf: rule.modifiers)
        if fields.last?.isEmpty == true { fields.removeLast() }
        return fields.joined(separator: ",")
    }

    // MARK: - Internals

    static func typeToken(for kind: RuleKind) -> String {
        switch kind {
        case .and: return "AND"
        case .or: return "OR"
        case .not: return "NOT"
        case .match: return "MATCH"
        case .srcIPCIDR: return "SRC-IP-CIDR"
        case .domainSuffix: return "DOMAIN-SUFFIX"
        case .domainKeyword: return "DOMAIN-KEYWORD"
        case .domainRegex: return "DOMAIN-REGEX"
        case .ipCIDR: return "IP-CIDR"
        case .ipCIDR6: return "IP-CIDR6"
        case .processName: return "PROCESS-NAME"
        case .geoIP: return "GEOIP"
        case .ruleSet: return "RULE-SET"
        case .domain: return "DOMAIN"
        }
    }

    static func resolveKind(_ token: String) -> RuleKind? {
        let lowered = token.lowercased().replacingOccurrences(of: "_", with: "-")
        switch lowered {
        case "src-ip-cidr": return .srcIPCIDR
        case "domain-wildcard": return .domainSuffix
        default: break
        }
        return RuleKind.parse(token)
    }

    static func makeRule(kind: RuleKind, rawValue: String, policy: String,
                         modifiers: [String], negate: Bool, raw: String) throws -> Rule {
        switch kind {
        case .match:
            return Rule(kind: .match, value: "", policy: policy, modifiers: modifiers, negate: negate, raw: raw)

        case .and, .or, .not:
            let operands = try parseOperands(rawValue)
            guard !operands.isEmpty else { throw RuleParseError.invalidValue(rawValue) }
            let expression = "(" + operands.map { "(\(typeToken(for: $0.kind)),\($0.value))" }.joined(separator: ",") + ")"
            return Rule(kind: kind, value: expression, policy: policy,
                        modifiers: modifiers, negate: negate, raw: raw)

        case .domain, .domainSuffix, .domainKeyword:
            var value = HostNormalizer.normalize(rawValue)
            if kind == .domainSuffix {
                while value.hasPrefix(".") { value.removeFirst() }
            }
            guard !value.isEmpty, !value.contains(" "), value != "*" else {
                throw RuleParseError.invalidValue(rawValue)
            }
            return Rule(kind: kind, value: value, policy: policy, modifiers: modifiers, negate: negate, raw: raw)

        case .domainRegex:
            guard (try? NSRegularExpression(pattern: rawValue)) != nil else {
                throw RuleParseError.invalidValue(rawValue)
            }
            return Rule(kind: kind, value: rawValue, policy: policy, modifiers: modifiers, negate: negate, raw: raw)

        case .ipCIDR, .ipCIDR6, .srcIPCIDR:
            guard let cidr = CIDR(rawValue) else { throw RuleParseError.invalidValue(rawValue) }
            if kind == .ipCIDR && !cidr.isIPv4 { throw RuleParseError.invalidValue(rawValue) }
            if kind == .ipCIDR6 && cidr.isIPv4 { throw RuleParseError.invalidValue(rawValue) }
            return Rule(kind: kind, value: cidr.description, policy: policy,
                        modifiers: modifiers, negate: negate, raw: raw)

        case .geoIP:
            let value = rawValue.trimmingCharacters(in: .whitespaces).uppercased()
            guard !value.isEmpty else { throw RuleParseError.invalidValue(rawValue) }
            return Rule(kind: kind, value: value, policy: policy, modifiers: modifiers, negate: negate, raw: raw)

        case .processName, .ruleSet:
            let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            guard !value.isEmpty else { throw RuleParseError.invalidValue(rawValue) }
            return Rule(kind: kind, value: value, policy: policy, modifiers: modifiers, negate: negate, raw: raw)
        }
    }

    /// Parses a logical expression such as `((DOMAIN,a.com),(DOMAIN-SUFFIX,b.com))`.
    static func parseOperands(_ expression: String) throws -> [Rule] {
        var text = expression.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("("), text.hasSuffix(")") else {
            throw RuleParseError.invalidValue(expression)
        }
        text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return [] }
        var operands: [Rule] = []
        for part in splitTopLevel(text) {
            var piece = part.trimmingCharacters(in: .whitespaces)
            if piece.hasPrefix("(") && piece.hasSuffix(")") {
                piece = String(piece.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            if piece.isEmpty { continue }
            let fields = splitTopLevel(piece).map(unquote)
            guard var token = fields.first, !token.isEmpty else { continue }
            var negate = false
            if token.hasPrefix("!") { negate = true; token = String(token.dropFirst()) }
            guard let kind = resolveKind(token) else { throw RuleParseError.unknownType(token) }
            let value = fields.count > 1 ? fields[1] : ""
            if kind == .match {
                operands.append(Rule(kind: .match, value: "", policy: "", raw: piece))
                continue
            }
            guard !value.isEmpty else { throw RuleParseError.missingValue(piece) }
            operands.append(try makeRule(kind: kind, rawValue: value, policy: "",
                                         modifiers: [], negate: negate, raw: piece))
        }
        return operands
    }

    /// Removes one layer of surrounding quotes (`"…"` or `'…'`), if present.
    static func unquote(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, let first = value.first, let last = value.last else { return value }
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    /// Splits on commas that are not inside parentheses or quotes.
    static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for ch in text {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; current.append(ch); continue }
            if ch == "(" { depth += 1; current.append(ch); continue }
            if ch == ")" { depth -= 1; current.append(ch); continue }
            if ch == "," && depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(ch)
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts
    }

    /// Drops `#` comments (also `//` at line start), respecting quotes.
    static func stripComment(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { return "" }
        var out = ""
        var quote: Character?
        var previous: Character = " "
        for ch in line {
            if let q = quote {
                out.append(ch)
                if ch == q { quote = nil }
                previous = ch
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; out.append(ch); previous = ch; continue }
            if ch == "#" && (previous == " " || previous == "\t") { break }
            out.append(ch)
            previous = ch
        }
        return out
    }

    static func normalizeModifier(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

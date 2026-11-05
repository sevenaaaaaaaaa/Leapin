import Foundation

/// Minimal YAML subset — enough for Surge/Clash style profiles, no dependencies.
public indirect enum YAMLValue: Sendable, Equatable {
    case null
    case scalar(String)
    case array([YAMLValue])
    case map([String: YAMLValue])

    public subscript(_ key: String) -> YAMLValue? {
        if case .map(let m) = self { return m[key] }
        return nil
    }

    public var string: String? {
        switch self {
        case .scalar(let s): return s
        case .null: return nil
        default: return nil
        }
    }
    public var int: Int? { string.flatMap { Int($0) } }
    public var double: Double? { string.flatMap { Double($0) } }
    public var bool: Bool? {
        guard let s = string?.lowercased() else { return nil }
        if ["true", "yes", "on", "1"].contains(s) { return true }
        if ["false", "no", "off", "0"].contains(s) { return false }
        return nil
    }
    public var array: [YAMLValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
    public var map: [String: YAMLValue]? {
        if case .map(let m) = self { return m }
        return nil
    }
    public var stringArray: [String]? {
        if case .array(let a) = self { return a.compactMap { $0.string } }
        if let s = string, !s.isEmpty { return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        return nil
    }
}

public enum MiniYAMLError: Error, CustomStringConvertible {
    case parse(String, line: Int)
    public var description: String {
        switch self { case .parse(let m, let l): return "YAML parse error at line \(l): \(m)" }
    }
}

public enum MiniYAML {
    public static func parse(_ text: String) throws -> YAMLValue {
        var parser = Parser(text: text)
        return try parser.parseDocument()
    }

    public static func parseDictionary(_ text: String) throws -> [String: YAMLValue] {
        let v = try parse(text)
        return v.map ?? [:]
    }

    // MARK: - Parser

    private struct Line { var indent: Int; var text: String; var number: Int }

    private struct Parser {
        var lines: [Line] = []
        var index = 0

        init(text: String) {
            var number = 0
            for raw in text.components(separatedBy: .newlines) {
                number += 1
                var line = raw.replacingOccurrences(of: "\t", with: "  ")
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                let indent = line.prefix { $0 == " " }.count
                var body = String(line.dropFirst(indent))
                if body.hasPrefix("#") { continue }
                if body == "---" || body == "..." { continue }
                body = stripInlineComment(body)
                if body.isEmpty { continue }
                lines.append(Line(indent: indent, text: body, number: number))
            }
        }

        mutating func parseDocument() throws -> YAMLValue {
            guard !lines.isEmpty else { return .null }
            return try parseBlock(minIndent: lines[0].indent)
        }

        mutating func parseBlock(minIndent: Int) throws -> YAMLValue {
            guard index < lines.count else { return .null }
            let line = lines[index]
            if isSequenceEntry(line.text) {
                return try parseSequence(indent: line.indent)
            }
            return try parseMapping(indent: line.indent)
        }

        mutating func parseSequence(indent: Int) throws -> YAMLValue {
            var items: [YAMLValue] = []
            while index < lines.count {
                let line = lines[index]
                guard line.indent == indent, isSequenceEntry(line.text) else { break }
                var rest = String(line.text.dropFirst())
                if rest.hasPrefix(" ") { rest.removeFirst() }
                if rest.isEmpty {
                    index += 1
                    if index < lines.count, lines[index].indent > indent {
                        items.append(try parseBlock(minIndent: indent + 1))
                    } else {
                        items.append(.null)
                    }
                } else if let _ = keyValueSplit(rest) {
                    // Inline first mapping key: "- key: value" continues as a map at indent+2.
                    lines[index] = Line(indent: indent + 2, text: rest, number: line.number)
                    items.append(try parseMapping(indent: indent + 2))
                } else {
                    items.append(parseInline(rest))
                    index += 1
                }
            }
            return .array(items)
        }

        mutating func parseMapping(indent: Int) throws -> YAMLValue {
            var dict: [String: YAMLValue] = [:]
            while index < lines.count {
                let line = lines[index]
                guard line.indent == indent, !isSequenceEntry(line.text) else { break }
                guard let (key, value) = keyValueSplit(line.text) else {
                    throw MiniYAMLError.parse("expected key: value, got '\(line.text)'", line: line.number)
                }
                index += 1
                if value.isEmpty {
                    if index < lines.count, lines[index].indent > indent {
                        dict[key] = try parseBlock(minIndent: indent + 1)
                    } else if index < lines.count, lines[index].indent == indent, isSequenceEntry(lines[index].text) {
                        dict[key] = try parseSequence(indent: indent)
                    } else {
                        dict[key] = .null
                    }
                } else if value.hasPrefix("|") || value.hasPrefix(">") {
                    dict[key] = .scalar(parseBlockScalar(parentIndent: indent, folded: value.hasPrefix(">")))
                } else {
                    dict[key] = parseInline(value)
                }
            }
            return .map(dict)
        }

        mutating func parseBlockScalar(parentIndent: Int, folded: Bool) -> String {
            var chunks: [String] = []
            var blockIndent: Int?
            while index < lines.count, lines[index].indent > parentIndent {
                let line = lines[index]
                let ind = blockIndent ?? line.indent
                blockIndent = ind
                var text = line.text
                if line.indent > ind { text = String(repeating: " ", count: line.indent - ind) + text }
                chunks.append(text)
                index += 1
            }
            return chunks.joined(separator: folded ? " " : "\n")
        }

        func isSequenceEntry(_ text: String) -> Bool {
            text == "-" || text.hasPrefix("- ")
        }

        func parseInline(_ raw: String) -> YAMLValue {
            let text = raw.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return .null }
            if text.hasPrefix("[") && text.hasSuffix("]") {
                let inner = String(text.dropFirst().dropLast())
                return .array(splitFlow(inner).map { parseInline($0) })
            }
            if text.hasPrefix("{") && text.hasSuffix("}") {
                var dict: [String: YAMLValue] = [:]
                for part in splitFlow(String(text.dropFirst().dropLast())) {
                    if let (k, v) = keyValueSplit(part) { dict[k] = parseInline(v) }
                }
                return .map(dict)
            }
            if text.hasPrefix("\"") && text.hasSuffix("\"") && text.count >= 2 {
                return .scalar(unescape(String(text.dropFirst().dropLast())))
            }
            if text.hasPrefix("'") && text.hasSuffix("'") && text.count >= 2 {
                return .scalar(String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"))
            }
            if ["null", "~"].contains(text.lowercased()) { return .null }
            return .scalar(text)
        }

        func keyValueSplit(_ text: String) -> (String, String)? {
            var inSingle = false, inDouble = false
            var i = text.startIndex
            while i < text.endIndex {
                let c = text[i]
                if c == "'" && !inDouble { inSingle.toggle() }
                else if c == "\"" && !inSingle { inDouble.toggle() }
                else if c == ":" && !inSingle && !inDouble {
                    let next = text.index(after: i)
                    if next == text.endIndex || text[next] == " " {
                        var key = String(text[..<i]).trimmingCharacters(in: .whitespaces)
                        if key.hasPrefix("\"") && key.hasSuffix("\"") && key.count >= 2 { key = String(key.dropFirst().dropLast()) }
                        if key.hasPrefix("'") && key.hasSuffix("'") && key.count >= 2 { key = String(key.dropFirst().dropLast()) }
                        let value = next == text.endIndex ? "" : String(text[text.index(after: next)...]).trimmingCharacters(in: .whitespaces)
                        return (key, value)
                    }
                }
                i = text.index(after: i)
            }
            return nil
        }

        func splitFlow(_ s: String) -> [String] {
            var parts: [String] = [], current = "", depth = 0
            var inSingle = false, inDouble = false
            for c in s {
                if c == "'" && !inDouble { inSingle.toggle() }
                else if c == "\"" && !inSingle { inDouble.toggle() }
                if !inSingle && !inDouble {
                    if c == "[" || c == "{" { depth += 1 }
                    if c == "]" || c == "}" { depth -= 1 }
                    if c == "," && depth == 0 { parts.append(current); current = ""; continue }
                }
                current.append(c)
            }
            if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
            return parts
        }

        func stripInlineComment(_ text: String) -> String {
            var inSingle = false, inDouble = false
            var result = ""
            var previous: Character = " "
            for c in text {
                if c == "'" && !inDouble { inSingle.toggle() }
                else if c == "\"" && !inSingle { inDouble.toggle() }
                if c == "#" && !inSingle && !inDouble && previous == " " {
                    break
                }
                result.append(c)
                previous = c
            }
            return result.trimmingCharacters(in: .whitespaces)
        }

        func unescape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
    }
}

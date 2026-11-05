import Foundation
import TouchFlowCore

/// Parses hand-written / OCR'd app lists in plain text, CSV, Markdown or JSON form.
///
/// Accepted shapes:
/// ```
/// 微信 weixin.qq.com
/// 淘宝, taobao.com, tmall.com
/// | 应用 | 域名 |
/// | --- | --- |
/// | 抖音 | douyin.com |
/// ["微信", {"name": "GitHub", "domains": ["github.com"]}]
/// ```
/// Entries without a domain are matched against the catalogue; when nothing matches
/// the app is kept with an empty domain list and `source == "user"`.
public enum AppListParser {
    public static func parse(text: String) -> [LearnedApp] {
        parse(text: text, catalog: AppCatalog.builtin)
    }

    public static func parse(text: String, catalog: [LearnedApp]) -> [LearnedApp] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        let entries = jsonEntries(in: trimmed) ?? lineEntries(in: trimmed)
        var result: [LearnedApp] = []
        var index: [String: Int] = [:]

        for entry in entries {
            let cleaned = cleanName(entry.name)
            guard cleaned.isEmpty == false else { continue }
            var app: LearnedApp
            if let matched = match(cleaned, bundleID: entry.bundleID, catalog: catalog) {
                app = matched
                if entry.domains.isEmpty == false {
                    app.domains = merge(app.domains, entry.domains)
                    app.source = "user"
                }
            } else {
                app = LearnedApp(name: cleaned,
                                 bundleID: entry.bundleID,
                                 domains: merge([], entry.domains),
                                 source: "user")
            }

            let key = app.name.lowercased()
            if let existing = index[key] {
                result[existing].domains = merge(result[existing].domains, app.domains)
            } else {
                index[key] = result.count
                result.append(app)
            }
        }
        return result
    }

    // MARK: - Line based input

    struct RawEntry {
        var name: String
        var domains: [String] = []
        var bundleID: String?
    }

    static func lineEntries(in text: String) -> [RawEntry] {
        var entries: [RawEntry] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") || line.hasPrefix("//") { continue }
            if isTableSeparator(line) { continue }

            line = stripDecorations(line)
            guard line.isEmpty == false else { continue }

            let cells = splitCells(line)
            var names: [String] = []
            var domains: [String] = []
            for cell in cells {
                var nameParts: [String] = []
                for token in cell.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
                    if let domain = normalizeDomain(token) {
                        if domains.contains(domain) == false { domains.append(domain) }
                    } else {
                        nameParts.append(token)
                    }
                }
                let name = cleanName(nameParts.joined(separator: " "))
                if name.isEmpty == false { names.append(name) }
            }
            if names.isEmpty, let first = domains.first {
                names = [first] // domain-only line: use the host as the label
            }
            for name in names where isHeaderWord(name) == false {
                entries.append(RawEntry(name: name, domains: domains))
            }
        }
        return entries
    }

    static func splitCells(_ line: String) -> [String] {
        var normalized = line
        normalized = normalized.replacingOccurrences(of: "\t", with: ",")
        normalized = normalized.replacingOccurrences(of: ";", with: ",")
        normalized = normalized.replacingOccurrences(of: "|", with: ",")
        return normalized.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let allowed = Set("|-: \t")
        return line.isEmpty == false && line.unicodeScalars.allSatisfy { allowed.contains(Character($0)) }
    }

    static func stripDecorations(_ line: String) -> String {
        var text = line
        let listMarkers = ["- ", "* ", "+ ", "• "]
        for marker in listMarkers where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count))
        }
        // "1. 微信" / "1) 微信"
        var digits = 0
        for character in text {
            if character.isNumber { digits += 1 } else { break }
        }
        if digits > 0, digits < 4 {
            let afterDigits = text.index(text.startIndex, offsetBy: digits)
            let rest = text[afterDigits...]
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") || rest.hasPrefix("、") {
                text = String(rest.dropFirst(rest.hasPrefix("、") ? 1 : 2))
            }
        }
        text = text.trimmingCharacters(in: .whitespaces)
        for wrapper in ["**", "__", "`"] {
            while text.hasPrefix(wrapper) && text.hasSuffix(wrapper) && text.count > wrapper.count * 2 {
                text = String(text.dropFirst(wrapper.count).dropLast(wrapper.count))
            }
        }
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "`", with: "")
        if text.hasPrefix("|") { text = String(text.dropFirst()) }
        if text.hasSuffix("|") { text = String(text.dropLast()) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static let headerWords: Set<String> = [
        "app", "apps", "application", "name", "appname", "应用", "应用名", "名称", "软件",
        "domain", "domains", "host", "hosts", "域名", "网址", "服务",
    ]

    static func isHeaderWord(_ name: String) -> Bool {
        headerWords.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    // MARK: - JSON input

    static func jsonEntries(in text: String) -> [RawEntry]? {
        guard text.hasPrefix("[") || text.hasPrefix("{") else { return nil }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }

        var items: [Any] = []
        if let array = object as? [Any] {
            items = array
        } else if let dictionary = object as? [String: Any] {
            for key in ["apps", "items", "data", "list"] {
                if let array = dictionary[key] as? [Any] {
                    items = array
                    break
                }
            }
        }
        guard items.isEmpty == false else { return nil }

        var entries: [RawEntry] = []
        for item in items {
            if let name = item as? String {
                entries.append(RawEntry(name: name))
                continue
            }
            guard let dictionary = item as? [String: Any] else { continue }
            let name = firstString(in: dictionary, keys: ["name", "app", "appName", "title", "名称", "应用"])
            let bundleID = firstString(in: dictionary, keys: ["bundleID", "bundleId", "bundle_id", "bundle", "包名"])
            let domains = domainStrings(in: dictionary,
                                        keys: ["domains", "domain", "hosts", "host", "域名", "网址"])
            if let name, name.isEmpty == false {
                entries.append(RawEntry(name: name, domains: domains, bundleID: bundleID))
            } else if let first = domains.first {
                entries.append(RawEntry(name: first, domains: domains, bundleID: bundleID))
            }
        }
        return entries.isEmpty ? nil : entries
    }

    static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, value.isEmpty == false { return value }
        }
        return nil
    }

    static func domainStrings(in dictionary: [String: Any], keys: [String]) -> [String] {
        for key in keys {
            if let value = dictionary[key] as? String, let domain = normalizeDomain(value) {
                return [domain]
            }
            if let values = dictionary[key] as? [Any] {
                var result: [String] = []
                for value in values {
                    if let string = value as? String, let domain = normalizeDomain(string),
                       result.contains(domain) == false {
                        result.append(domain)
                    }
                }
                if result.isEmpty == false { return result }
            }
        }
        return []
    }

    // MARK: - Normalisation

    /// Returns a lowercase host when `token` looks like a domain, otherwise nil.
    static func normalizeDomain(_ token: String) -> String? {
        var value = token.trimmingCharacters(in: .whitespaces)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`,;:()[]{}<>。，、"))
        if value.isEmpty { return nil }
        if value.contains("://"), let url = URL(string: value), let host = url.host {
            value = host
        }
        if value.hasPrefix("www.") { value = String(value.dropFirst(4)) }
        while value.hasSuffix("/") || value.hasSuffix(".") { value.removeLast() }
        guard value.contains("."), value.count >= 4 else { return nil }
        let allowed = "abcdefghijklmnopqrstuvwxyz0123456789.-_"
        guard value.lowercased().unicodeScalars.allSatisfy({ allowed.unicodeScalars.contains($0) }) else { return nil }
        guard value.contains("@") == false, value.contains(" ") == false else { return nil }
        let labels = value.split(separator: ".")
        guard labels.count >= 2 else { return nil }
        guard let tld = labels.last, tld.count >= 2, tld.allSatisfy({ $0.isLetter }) else { return nil }
        // Reject bare IP addresses.
        if labels.allSatisfy({ $0.allSatisfy { $0.isNumber } }) { return nil }
        return value.lowercased()
    }

    static func cleanName(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespaces)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*,;|:()[]{}<>—–-·。，、"))
        value = value.replacingOccurrences(of: "  ", with: " ")
        if value.isEmpty { return "" }
        if normalizeDomain(value) != nil { return "" }
        if value.allSatisfy({ $0.isNumber || $0 == "." }) { return "" }
        return value
    }

    static func merge(_ lhs: [String], _ rhs: [String]) -> [String] {
        var result = lhs
        for domain in rhs where result.contains(domain) == false {
            result.append(domain)
        }
        return result
    }

    static func normalizeName(_ value: String) -> String {
        let lowered = value.lowercased()
        let stripped = lowered.unicodeScalars.filter { character in
            CharacterSet.alphanumerics.contains(character)
        }
        return String(String.UnicodeScalarView(stripped))
    }

    static func match(_ name: String, bundleID: String?, catalog: [LearnedApp]) -> LearnedApp? {
        if let bundleID, bundleID.isEmpty == false {
            for app in catalog where app.bundleID?.lowercased() == bundleID.lowercased() {
                return app
            }
        }
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        for app in catalog where app.name.lowercased() == key { return app }

        if let target = AppCatalog.aliases[key] {
            for app in catalog where app.name == target { return app }
        }
        let compact = normalizeName(name)
        guard compact.isEmpty == false else { return nil }
        if let target = AppCatalog.aliases[compact] {
            for app in catalog where app.name == target { return app }
        }
        for app in catalog {
            let other = normalizeName(app.name)
            guard other.count >= 2 else { continue }
            if other == compact { return app }
            if compact.contains(other) || other.contains(compact) { return app }
        }
        if let bundleID, bundleID.isEmpty == false {
            for app in catalog where app.bundleID?.lowercased().hasSuffix(bundleID.lowercased()) == true {
                return app
            }
        }
        return nil
    }
}

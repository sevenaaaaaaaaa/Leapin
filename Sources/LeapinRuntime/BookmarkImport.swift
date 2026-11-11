import Foundation
import LeapinCore

public struct BookmarkImportPreview: Identifiable, Sendable {
    public let id = UUID()
    public let source: String
    public let additions: [NetworkBookmark]
    public let duplicates: Int
    public let skipped: Int
    let baseline: [NetworkBookmark]
}

/// Reads exported bookmark files only. No browser profiles, web views or network
/// fetches are used while parsing HTML.
public enum BookmarkImporter {
    public static func preview(data: Data, source: String, existing: [NetworkBookmark]) throws -> BookmarkImportPreview {
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw LeapinError.invalidConfiguration("请选择 8 MB 内的 UTF-8 书签 HTML 或 JSON 文件")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = trimmed.hasPrefix("{") || trimmed.hasPrefix("[") ? try json(data) : try html(text)
        guard parsed.items.count + parsed.skipped <= 5000 else { throw LeapinError.invalidConfiguration("每批最多导入 5000 条书签，请分批导出") }
        guard !parsed.items.isEmpty || parsed.skipped > 0 else { throw LeapinError.invalidConfiguration("文件中没有可识别的书签") }
        var known = Set(existing.map { key($0.url) })
        var additions: [NetworkBookmark] = []
        var duplicates = 0
        for bookmark in parsed.items {
            if known.insert(key(bookmark.url)).inserted { additions.append(bookmark) }
            else { duplicates += 1 }
        }
        return BookmarkImportPreview(source: source, additions: additions, duplicates: duplicates,
                                     skipped: parsed.skipped, baseline: existing)
    }

    public static func key(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        if parts.path.isEmpty { parts.path = "/" }
        return parts.string ?? url.absoluteString
    }
    private static func bookmark(title: String, address: String, folder: [String]) -> NetworkBookmark? {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), SiteTarget(address) != nil else { return nil }
        let cleanTitle = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return NetworkBookmark(title: cleanTitle.isEmpty ? (url.host ?? "网站") : String(cleanTitle.prefix(200)),
                               url: url, folder: folder.isEmpty ? nil : folder.joined(separator: " / "))
    }
    private struct Parsed { var items: [NetworkBookmark] = []; var skipped = 0 }

    private static func json(_ data: Data) throws -> Parsed {
        let root = try JSONSerialization.jsonObject(with: data)
        var result = Parsed()
        var visited = 0
        func walk(_ value: Any, folders: [String], depth: Int) throws {
            visited += 1
            guard depth <= 64, visited <= 20_000, result.items.count + result.skipped <= 5000 else {
                throw LeapinError.invalidConfiguration("书签层级或数量过多，请分批导入（每批最多 5000 条）")
            }
            if let array = value as? [Any] { for item in array { try walk(item, folders: folders, depth: depth + 1) }; return }
            guard let object = value as? [String: Any] else { return }
            if let address = object["url"] as? String {
                if let item = bookmark(title: object["name"] as? String ?? object["title"] as? String ?? "", address: address, folder: folders) { result.items.append(item) }
                else { result.skipped += 1 }
            } else if let children = object["children"] as? [Any] {
                let name = object["name"] as? String ?? ""
                try walk(children, folders: name.isEmpty ? folders : folders + [String(name.prefix(120))], depth: depth + 1)
            } else if let roots = object["roots"] as? [String: Any] {
                for key in roots.keys.sorted() { try walk(roots[key]!, folders: [], depth: depth + 1) }
            }
        }
        try walk(root, folders: [], depth: 0)
        return result
    }

    private static func html(_ text: String) throws -> Parsed {
        let source = text as NSString
        let tokens = try NSRegularExpression(pattern: #"<!--[\s\S]*?-->|<(?:\"[^\"]*\"|'[^']*'|[^'\">])*>"#)
        let tagName = try NSRegularExpression(pattern: #"^<\s*(/?)\s*([a-zA-Z0-9]+)"#)
        let href = try NSRegularExpression(pattern: #"(?i)(?:^|\s)href\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#)
        var result = Parsed()
        var frames: [String?] = []
        var pendingFolder: String?
        var captured: String?
        var address: String?
        var content = ""
        var ignored: String?
        var previous = 0
        var count = 0
        var tooLarge = false
        tokens.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, stop in
            guard let match else { return }
            count += 1
            if count > 40_000 || result.items.count + result.skipped > 5000 || frames.count > 64 {
                tooLarge = true; stop.pointee = true; return
            }
            if captured != nil, ignored == nil, match.range.location > previous {
                content += source.substring(with: NSRange(location: previous, length: match.range.location - previous))
            }
            let tag = source.substring(with: match.range)
            previous = NSMaxRange(match.range)
            guard let name = tagName.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return }
            let raw = tag as NSString
            let closing = raw.substring(with: name.range(at: 1)) == "/"
            let kind = raw.substring(with: name.range(at: 2)).lowercased()
            if let skip = ignored {
                if closing && kind == skip { ignored = nil }
                return
            }
            if !closing && ["script", "style"].contains(kind) { ignored = kind; return }
            if !closing && kind == "dl" { frames.append(pendingFolder); pendingFolder = nil }
            else if closing && kind == "dl" { if !frames.isEmpty { frames.removeLast() } }
            else if !closing && ["h3", "a"].contains(kind) {
                captured = kind; content = ""; address = nil
                if kind == "a", let value = href.firstMatch(in: tag, range: NSRange(location: 0, length: raw.length)) {
                    for group in 1...3 where value.range(at: group).location != NSNotFound {
                        address = entities(raw.substring(with: value.range(at: group))); break
                    }
                }
            } else if closing && kind == captured {
                let title = entities(content)
                if kind == "h3" { pendingFolder = String(title.prefix(120)) }
                else if let address, let item = bookmark(title: title, address: address, folder: frames.compactMap { $0 }) { result.items.append(item) }
                else { result.skipped += 1 }
                captured = nil; address = nil; content = ""
            }
        }
        guard !tooLarge else { throw LeapinError.invalidConfiguration("书签文件过于复杂，请分批导入（每批最多 5000 条）") }
        return result
    }
    private static func entities(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|amp|quot|apos|lt|gt|nbsp);"#) else { return value }
        var result = value
        let original = value as NSString
        for match in regex.matches(in: value, range: NSRange(location: 0, length: original.length)).reversed() {
            let key = original.substring(with: match.range(at: 1))
            let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " "]
            var replacement = named[key]
            if key.hasPrefix("#x"), let number = UInt32(key.dropFirst(2), radix: 16), let scalar = UnicodeScalar(number) { replacement = String(scalar) }
            else if key.hasPrefix("#"), let number = UInt32(key.dropFirst()), let scalar = UnicodeScalar(number) { replacement = String(scalar) }
            if let replacement, let range = Range(match.range, in: result) { result.replaceSubrange(range, with: replacement) }
        }
        return result
    }
}

import Foundation
import Combine
import LeapinCore

public struct NetworkBookmark: Identifiable, Codable, Sendable, Hashable {
    public var id = UUID()
    public var title: String
    public var url: URL
    public var folder: String?
}

@MainActor
public final class NetworkBookmarks: ObservableObject {
    @Published public private(set) var items: [NetworkBookmark] = []
    private var imported: [NetworkBookmark] = []
    public var canUndoImport: Bool { imported.contains { item in items.contains(item) } }
    private let file: URL
    public init(root: URL) {
        file = root.appendingPathComponent("bookmarks.json")
        if let data = try? Data(contentsOf: file) { items = (try? JSONDecoder().decode([NetworkBookmark].self, from: data)) ?? [] }
    }
    public func add(title: String, address: String) throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let target = SiteTarget(text), let url = URL(string: text), target.host.count > 0 else {
            throw LeapinError.invalidConfiguration("请输入有效的网站地址，不支持含用户名或密码的链接")
        }
        guard !items.contains(where: { BookmarkImporter.key($0.url) == BookmarkImporter.key(url) }) else { return }
        var next = items
        next.insert(NetworkBookmark(title: title.isEmpty ? target.host : title, url: url, folder: nil), at: 0)
        try save(next)
    }
    public func remove(_ id: UUID) throws { try save(items.filter { $0.id != id }) }
    public func previewImport(data: Data, source: String) throws -> BookmarkImportPreview {
        try BookmarkImporter.preview(data: data, source: source, existing: items)
    }
    public func commitImport(_ preview: BookmarkImportPreview) throws {
        guard items == preview.baseline else { throw LeapinError.invalidConfiguration("书签已变化，请重新预览后再导入") }
        guard !preview.additions.isEmpty else { return }
        try save(preview.additions + items)
        imported = preview.additions
        objectWillChange.send()
    }
    public func undoImport() throws {
        let ids = Set(imported.map(\.id))
        guard items.filter({ ids.contains($0.id) }).allSatisfy({ imported.contains($0) }) else {
            throw LeapinError.invalidConfiguration("导入后的书签已编辑，无法安全撤销")
        }
        try save(items.filter { !ids.contains($0.id) })
        imported = []
        objectWillChange.send()
    }
    private func save(_ next: [NetworkBookmark]) throws {
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        items = next
    }
}

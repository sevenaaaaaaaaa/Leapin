import XCTest
@testable import LeapinRuntime

final class BookmarkImportTests: XCTestCase {
    private let html = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <DL><p><DT><H3>Work &amp; Tools</H3><DL><p>
    <DT><A HREF="https://EXAMPLE.com:443/?x=1&amp;y=2#part">A &lt;B&gt; &#x4E2D;</A>
    <DT><A HREF='https://example.com/?x=1&amp;y=2#part'>Duplicate</A>
    <DT><A HREF='javascript:alert(1)'>Script</A>
    <DT><A HREF='file:///private/file'>File</A>
    <DT><A HREF='https://name:secret@example.org'>Credentials</A>
    <SCRIPT><A HREF='https://ignored.example'>Ignored</A></SCRIPT>
    <!-- <A HREF='https://comment.example'>Comment</A> -->
    </DL><DT><A HREF='https://outside.example/a?value=>'>Outside <B>title</B></A></DL>
    """
    func testExportedHTMLFoldersEntitiesDedupAndUnsafeLinks() throws {
        let preview = try BookmarkImporter.preview(data: Data(html.utf8), source: "Browser.html", existing: [])
        XCTAssertEqual(preview.additions.count, 2)
        XCTAssertEqual(preview.duplicates, 1)
        XCTAssertEqual(preview.skipped, 3)
        XCTAssertEqual(preview.additions[0].folder, "Work & Tools")
        XCTAssertEqual(preview.additions[0].title, "A <B> 中")
        XCTAssertEqual(preview.additions[0].url.query, "x=1&y=2")
        XCTAssertEqual(preview.additions[0].url.fragment, "part")
        XCTAssertNil(preview.additions[1].folder)
        XCTAssertEqual(preview.additions[1].title, "Outside title")
    }
    func testChromiumJSONAndDistinctQueryAndFragmentsAreKept() throws {
        let text = #"{"roots":{"bookmark_bar":{"name":"Bookmarks","children":[{"name":"Dev","children":[{"type":"url","name":"Docs","url":"https://example.com?q=1#a"},{"url":"https://example.com?q=2#a"},{"url":"https://example.com?q=1#b"},{"url":"data:text/plain,test"}]}]}}}"#
        let preview = try BookmarkImporter.preview(data: Data(text.utf8), source: "Bookmarks", existing: [])
        XCTAssertEqual(preview.additions.count, 3)
        XCTAssertEqual(preview.additions.first?.folder, "Bookmarks / Dev")
        XCTAssertEqual(preview.skipped, 1)
    }
    func testMalformedOversizeAndOvercomplexFilesFailWithoutPartialImport() throws {
        for text in ["", "<html>no links</html>", "{broken", String(repeating: "a", count: 8 * 1024 * 1024 + 1), String(repeating: "<DL>", count: 70) + "<A HREF='https://example.com'>A</A>"] {
            XCTAssertThrowsError(try BookmarkImporter.preview(data: Data(text.utf8), source: "bad", existing: []))
        }
    }
    func testExactlyFiveThousandHTMLBookmarksAcceptedAndNextOneRejected() throws {
        let row = "<DT><A HREF='https://example.com'>A</A>"
        let accepted = "<DL>" + String(repeating: row, count: 5000) + "</DL>"
        let preview = try BookmarkImporter.preview(data: Data(accepted.utf8), source: "max.html", existing: [])
        XCTAssertEqual(preview.additions.count, 1)
        XCTAssertEqual(preview.duplicates, 4999)
        XCTAssertThrowsError(try BookmarkImporter.preview(data: Data((accepted + row).utf8), source: "over.html", existing: []))
    }
    func testExactlyFiveThousandJSONBookmarksAcceptedAndNextOneRejected() throws {
        let row = #"{"url":"https://example.com"}"#
        let accepted = "[" + Array(repeating: row, count: 5000).joined(separator: ",") + "]"
        XCTAssertEqual(try BookmarkImporter.preview(data: Data(accepted.utf8), source: "max.json", existing: []).duplicates, 4999)
        let over = "[" + Array(repeating: row, count: 5001).joined(separator: ",") + "]"
        XCTAssertThrowsError(try BookmarkImporter.preview(data: Data(over.utf8), source: "over.json", existing: []))
    }
    @MainActor
    func testPreviewDoesNotWriteStalePreviewRejectedAndUndoPreservesManualAdds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NetworkBookmarks(root: root)
        try store.add(title: "Original", address: "https://original.example")
        let original = store.items[0]
        let preview = try store.previewImport(data: Data(html.utf8), source: "browser")
        XCTAssertEqual(NetworkBookmarks(root: root).items, [original])
        try store.add(title: "Later", address: "https://later.example")
        XCTAssertThrowsError(try store.commitImport(preview))
        let fresh = try store.previewImport(data: Data(html.utf8), source: "browser")
        try store.commitImport(fresh)
        XCTAssertTrue(store.canUndoImport)
        try store.add(title: "After import", address: "https://after.example")
        try store.undoImport()
        XCTAssertEqual(store.items.count, 3)
        XCTAssertTrue(store.items.contains(original))
        XCTAssertTrue(store.items.contains(where: { $0.title == "After import" }))
        XCTAssertFalse(store.canUndoImport)
    }
    @MainActor
    func testOlderBookmarkFilesWithoutFolderStillLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let json = "[{\"id\":\"\(UUID().uuidString)\",\"title\":\"Old\",\"url\":\"https://example.com\"}]"
        try Data(json.utf8).write(to: root.appendingPathComponent("bookmarks.json"))
        XCTAssertEqual(NetworkBookmarks(root: root).items.first?.title, "Old")
    }
}

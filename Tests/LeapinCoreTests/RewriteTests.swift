import XCTest
@testable import LeapinCore

final class RewriteTests: XCTestCase {

    // MARK: - Parsing

    func testParsesHeaderAndBodyDirectives() throws {
        let engine = RewriteEngine(lines: [
            #"http-request ^https?://api\.example\.com/v1/ header-add X-Debug 1"#,
            #"http-request ^https?://api\.example\.com/v1/ header-del X-Trace"#,
            #"http-request ^https?://api\.example\.com/v1/ header-replace X-Mode fast"#,
            #"http-response ^https?://api\.example\.com/user body-replace "\"vip\":false" "\"vip\":true""#,
        ])
        XCTAssertTrue(engine.issues.isEmpty, "unexpected issues: \(engine.issues)")
        XCTAssertEqual(engine.ruleCount, 4)
    }

    func testRejectsUnknownPhaseAndAction() {
        let engine = RewriteEngine(lines: [
            "http-nope ^https?://x/ header-add A B",
            "http-request ^https?://x/ explode",
        ])
        XCTAssertEqual(engine.issues.count, 2)
        XCTAssertEqual(engine.ruleCount, 0)
    }

    func testRejectsInvalidRegex() {
        let engine = RewriteEngine(lines: [#"http-request ^https?://([ header-add A B"#])
        XCTAssertEqual(engine.issues.count, 1)
        XCTAssertEqual(engine.ruleCount, 0)
    }

    func testIgnoresCommentsAndBlankLines() {
        let engine = RewriteEngine(lines: ["", "   ", "# 注释", #"http-request ^https?://x/ header-del A"#])
        XCTAssertEqual(engine.ruleCount, 1)
        XCTAssertTrue(engine.issues.isEmpty)
    }

    // MARK: - Request phase

    func testHeaderAddDelReplaceApplyOnMatch() {
        let engine = RewriteEngine(lines: [
            #"http-request ^https?://api\.example\.com/ header-add X-Debug 1"#,
            #"http-request ^https?://api\.example\.com/ header-del X-Trace"#,
            #"http-request ^https?://api\.example\.com/ header-replace Accept application/json"#,
        ])
        let result = engine.applyToRequest(
            url: "https://api.example.com/v1/user",
            headers: RewriteHeaders([("X-Trace", "abc"), ("Accept", "*/*")]),
            body: Data())

        guard case .proceed(let headers, _, _) = result else {
            return XCTFail("expected proceed, got \(result)")
        }
        XCTAssertEqual(headers.first("X-Debug"), "1")
        XCTAssertNil(headers.first("X-Trace"))
        XCTAssertEqual(headers.first("Accept"), "application/json")
    }

    func testRulesOnlyApplyToMatchingURL() {
        let engine = RewriteEngine(lines: [#"http-request ^https?://api\.example\.com/ header-add X-Debug 1"#])
        let result = engine.applyToRequest(url: "https://other.example.com/",
                                           headers: RewriteHeaders(), body: Data())
        guard case .proceed(let headers, _, _) = result else {
            return XCTFail("expected proceed")
        }
        XCTAssertNil(headers.first("X-Debug"))
    }

    func testMockShortCircuitsBeforeUpstream() {
        let engine = RewriteEngine(lines: [
            #"http-request ^https?://api\.example\.com/mock mock 200 application/json {"ok":true}"#,
        ])
        let result = engine.applyToRequest(url: "https://api.example.com/mock",
                                           headers: RewriteHeaders(), body: Data())
        guard case .respond(let status, let contentType, let body) = result else {
            return XCTFail("expected mock response, got \(result)")
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(contentType, "application/json")
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"ok":true}"#)
    }

    func testRedirectCarriesStatus() {
        let engine = RewriteEngine(lines: [
            #"http-request ^https?://old\.example\.com/(.*) redirect https://new.example.com/$1 301"#,
        ])
        let result = engine.applyToRequest(url: "https://old.example.com/a",
                                           headers: RewriteHeaders(), body: Data())
        guard case .redirect(let target, let status) = result else {
            return XCTFail("expected redirect, got \(result)")
        }
        XCTAssertEqual(target, "https://new.example.com/$1")
        XCTAssertEqual(status, 301)
    }

    // MARK: - Response phase

    func testBodyReplaceRewritesText() {
        let engine = RewriteEngine(lines: [
            #"http-response ^https?://api\.example\.com/user body-replace "\"vip\":false" "\"vip\":true""#,
        ])
        let original = Data(#"{"name":"a","vip":false}"#.utf8)
        let outcome = engine.applyToResponse(url: "https://api.example.com/user",
                                             headers: RewriteHeaders([("Content-Type", "application/json")]),
                                             body: original)
        XCTAssertEqual(String(decoding: outcome.body, as: UTF8.self), #"{"name":"a","vip":true}"#)
        XCTAssertFalse(outcome.mocked)
    }

    func testResponseMockReplacesBodyAndFraming() {
        let engine = RewriteEngine(lines: [
            #"http-response ^https?://api\.example\.com/feature mock 200 application/json {"enabled":true}"#,
        ])
        let outcome = engine.applyToResponse(
            url: "https://api.example.com/feature",
            headers: RewriteHeaders([("Content-Type", "text/plain"), ("Content-Encoding", "gzip")]),
            body: Data("original".utf8))
        XCTAssertEqual(String(decoding: outcome.body, as: UTF8.self), #"{"enabled":true}"#)
        XCTAssertEqual(outcome.headers.first("Content-Type"), "application/json")
        XCTAssertNil(outcome.headers.first("Content-Encoding"))
        XCTAssertEqual(outcome.headers.first("Content-Length"), String(outcome.body.count))
        XCTAssertTrue(outcome.mocked)
    }

    func testBinaryBodyIsLeftAlone() {
        let engine = RewriteEngine(lines: [
            #"http-response ^https?://api\.example\.com/ body-replace a b"#,
        ])
        let binary = Data([0xFF, 0xFE, 0x00, 0x01])
        let outcome = engine.applyToResponse(url: "https://api.example.com/x",
                                             headers: RewriteHeaders(), body: binary)
        XCTAssertEqual(outcome.body, binary)
    }

    // MARK: - Tokenizer

    func testTokenizerKeepsQuotedSpaces() {
        let tokens = RewriteEngine.tokenize(#"http-response ^u$ body-replace "a b" "c d""#)
        XCTAssertEqual(tokens, ["http-response", "^u$", "body-replace", "a b", "c d"])
    }

    func testTokenizerKeepsEscapedQuotes() {
        let tokens = RewriteEngine.tokenize(#"r p body-replace "\"vip\"" "x""#)
        XCTAssertEqual(tokens[3], #""vip""#)
    }
}

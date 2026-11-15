import XCTest
@testable import LeapinScript
@testable import LeapinCore

private final class StubHost: ScriptHost, @unchecked Sendable {
    var notifications: [(String, String)] = []
    var httpReplies: [String: (Int, String)] = [:]

    func httpGet(url: String, timeoutMs: Int) -> (status: Int, body: String)? {
        httpReplies[url].map { (status: $0.0, body: $0.1) }
    }

    func notify(title: String, body: String) {
        notifications.append((title, body))
    }

    var environment: [String: String] { ["device": "test"] }
}

final class ScriptRuntimeTests: XCTestCase {

    private func request(_ url: String = "https://api.example.com/v1/user",
                         body: String = "hello") -> ScriptRequest {
        ScriptRequest(method: "GET", url: url,
                      headers: [(name: "Accept", value: "*/*")],
                      body: Data(body.utf8))
    }

    // MARK: - Request phase

    func testRequestScriptCanEditHeadersAndBody() {
        let script = ScriptSource(name: "add-header", phase: .request, code: """
        $request.headers["X-Debug"] = "1"
        $request.body = $request.body + "!"
        $done()
        """)
        let runtime = ScriptRuntime(scripts: [script])
        let result = runtime.runRequest(request(), host: StubHost())

        guard case .proceed(let headers, let body, _) = result.outcome else {
            return XCTFail("expected proceed, got \(result.outcome)")
        }
        XCTAssertEqual(headers.first("X-Debug"), "1")
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello!")
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testRequestScriptCanAnswerWithoutUpstream() {
        let script = ScriptSource(name: "mock", phase: .request, code: """
        $done({ status: 200, contentType: "application/json", body: "{\\"mocked\\":true}" })
        """)
        let runtime = ScriptRuntime(scripts: [script])
        let result = runtime.runRequest(request(), host: StubHost())

        guard case .respond(let status, let contentType, let body) = result.outcome else {
            return XCTFail("expected respond, got \(result.outcome)")
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(contentType, "application/json")
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"mocked":true}"#)
    }

    func testRequestScriptCanRedirect() {
        let script = ScriptSource(name: "redirect", phase: .request, code: """
        $done({ redirect: "https://new.example.com/", status: 301 })
        """)
        let runtime = ScriptRuntime(scripts: [script])
        let result = runtime.runRequest(request(), host: StubHost())
        guard case .redirect(let target, let status) = result.outcome else {
            return XCTFail("expected redirect, got \(result.outcome)")
        }
        XCTAssertEqual(target, "https://new.example.com/")
        XCTAssertEqual(status, 301)
    }

    // MARK: - Response phase

    func testResponseScriptRewritesBodyAndStatus() {
        let script = ScriptSource(name: "rewrite-body", phase: .response, code: """
        console.log("saw " + $response.status)
        $done({ status: 201, body: "replaced" })
        """)
        let runtime = ScriptRuntime(scripts: [script])
        let result = runtime.runResponse(url: "https://api.example.com/v1/user",
                                         status: 200,
                                         headers: [(name: "Content-Type", value: "text/plain")],
                                         body: Data("original".utf8),
                                         host: StubHost())
        XCTAssertEqual(result.status, 201)
        XCTAssertEqual(String(decoding: result.body, as: UTF8.self), "replaced")
        XCTAssertGreaterThan(result.logs.count, 0, "console.log should be captured")
    }

    func testResponseScriptWithoutPayloadKeepsBody() {
        let script = ScriptSource(name: "noop", phase: .response, code: "$done()")
        let runtime = ScriptRuntime(scripts: [script])
        let result = runtime.runResponse(url: "https://api.example.com/", status: 200,
                                         headers: [], body: Data("keep".utf8), host: StubHost())
        XCTAssertEqual(String(decoding: result.body, as: UTF8.self), "keep")
        XCTAssertEqual(result.status, 200)
    }

    // MARK: - Sandbox

    func testSandboxHidesHostCapabilities() {
        let script = ScriptSource(name: "probe", phase: .request, code: """
        const report = [typeof require, typeof process, typeof fetch, typeof $httpClient]
        $done({ status: 200, contentType: "application/json", body: JSON.stringify(report) })
        """)
        let runtime = ScriptRuntime(scripts: [script])
        let result = runtime.runRequest(request(), host: StubHost())
        guard case .respond(_, _, let body) = result.outcome else {
            return XCTFail("expected respond")
        }
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("undefined"), text)
        // $httpClient exists but the raw Node/Web APIs must not.
        XCTAssertFalse(text.contains(#""function","function","function""#), text)
    }

    func testEnvironmentCarriesPhase() {
        let script = ScriptSource(name: "env", phase: .request, code: """
        $done({ status: 200, contentType: "text/plain", body: $environment.phase })
        """)
        let runtime = ScriptRuntime(scripts: [script])
        let result = runtime.runRequest(request(), host: StubHost())
        guard case .respond(_, _, let body) = result.outcome else { return XCTFail("expected respond") }
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "http.request")
    }

    func testHTTPClientUsesHostAndRespectsBudget() {
        let host = StubHost()
        host.httpReplies["https://upstream.test/config"] = (200, "from-host")
        let script = ScriptSource(name: "fetch", phase: .request, code: """
        const reply = $httpClient.get("https://upstream.test/config")
        $done({ status: 200, contentType: "text/plain", body: reply ? reply.body : "none" })
        """)
        let runtime = ScriptRuntime(scripts: [script])
        let result = runtime.runRequest(request(), host: host)
        guard case .respond(_, _, let body) = result.outcome else { return XCTFail("expected respond") }
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "from-host")
    }

    // MARK: - Failure handling

    func testThrowingScriptIsDisabledAndOthersStillRun() {
        let bad = ScriptSource(name: "bad", phase: .request, code: "throw new Error('boom')")
        let good = ScriptSource(name: "good", phase: .request, code: """
        $request.headers["X-Ok"] = "1"
        $done()
        """)
        let runtime = ScriptRuntime(scripts: [bad, good])

        let first = runtime.runRequest(request(), host: StubHost())
        XCTAssertEqual(first.errors.count, 1)
        XCTAssertTrue(first.errors[0].reason.contains("boom"), first.errors[0].reason)
        XCTAssertNotNil(runtime.disabledReasons["bad"])

        // The failing script must not be retried on the next request.
        let second = runtime.runRequest(request(), host: StubHost())
        XCTAssertTrue(second.errors.isEmpty)
        guard case .proceed(let headers, _, _) = second.outcome else { return XCTFail("expected proceed") }
        XCTAssertEqual(headers.first("X-Ok"), "1", "a healthy script still applies")
    }

    func testOverBudgetScriptIsDisabled() {
        // Bounded work, but far over a 1 ms budget: this proves the deadline check
        // without leaving an uninterruptible infinite loop in the test process.
        let slow = ScriptSource(name: "slow", phase: .request, code: """
        let total = 0
        for (let i = 0; i < 3000000; i++) { total += i }
        $done()
        """)
        let runtime = ScriptRuntime(scripts: [slow], budget: .init(milliseconds: 1))
        _ = runtime.runRequest(request(), host: StubHost())
        XCTAssertNotNil(runtime.disabledReasons["slow"])
        XCTAssertTrue(runtime.disabledReasons["slow"]?.contains("超时") ?? false,
                      runtime.disabledReasons["slow"] ?? "")
    }

    // MARK: - Persistent store

    func testPersistentStoreRoundTrip() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("leapin-script-store-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = ScriptSource(name: "write", phase: .request, code: """
        $persistentStore.write("token", "abc123")
        $done()
        """)
        _ = ScriptRuntime(scripts: [writer], persistentStoreURL: url).runRequest(request(), host: StubHost())

        let reader = ScriptSource(name: "read", phase: .request, code: """
        $done({ status: 200, contentType: "text/plain", body: $persistentStore.read("token") || "" })
        """)
        let result = ScriptRuntime(scripts: [reader], persistentStoreURL: url)
            .runRequest(request(), host: StubHost())
        guard case .respond(_, _, let body) = result.outcome else { return XCTFail("expected respond") }
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "abc123")
    }

    // MARK: - Selection

    func testOnlyMatchingPhaseRuns() {
        let requestScript = ScriptSource(name: "req", phase: .request, code: "throw new Error('should not run')")
        let runtime = ScriptRuntime(scripts: [requestScript])
        let result = runtime.runResponse(url: "https://x/", status: 200, headers: [], body: Data(), host: StubHost())
        XCTAssertTrue(result.errors.isEmpty, "request script must not run in the response phase")
    }

    func testDisabledScriptIsSkipped() {
        let script = ScriptSource(name: "off", phase: .request, code: "throw new Error('x')", enabled: false)
        let runtime = ScriptRuntime(scripts: [script])
        let result = runtime.runRequest(request(), host: StubHost())
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(runtime.activeScripts.count, 0)
    }
}

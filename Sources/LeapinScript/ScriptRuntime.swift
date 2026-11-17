import Foundation
import JavaScriptCore
import LeapinCore

/// Runs user scripts in JavaScriptCore.
///
/// Model: the whole source is evaluated **per event** with the request or response
/// already injected as a global, and the script signals completion with `$done()`.
/// That is the mental model people already have for this kind of tool, and it means a
/// script cannot quietly keep state between events — persistence has to be explicit.
///
/// Sandbox: no filesystem, no process, no dynamic import; only the injected globals.
/// A script that throws or overruns its budget is disabled rather than retried on every
/// connection, so one bad line cannot degrade the whole proxy.
public final class ScriptRuntime: @unchecked Sendable {
    public struct Budget: Sendable {
        public var milliseconds: Int
        /// `$httpClient` calls one run may make.
        public var httpCalls: Int
        public init(milliseconds: Int = 50, httpCalls: Int = 1) {
            self.milliseconds = milliseconds
            self.httpCalls = httpCalls
        }
    }

    public struct ResponseResult: Sendable {
        public var status: Int
        public var headers: RewriteHeaders
        public var body: Data
        public var logs: [String]
        public var errors: [ScriptRunError]
    }

    private let lock = NSLock()
    private var sources: [ScriptSource]
    private var disabled: [String: String] = [:]
    private var store: [String: String] = [:]
    private let persistentURL: URL?
    public var budget: Budget
    /// Host services for `$httpClient` / `$notification`. Set once by the engine.
    public weak var host: ScriptHost?

    public init(scripts: [ScriptSource] = [], budget: Budget = Budget(), persistentStoreURL: URL? = nil) {
        self.sources = scripts
        self.budget = budget
        self.persistentURL = persistentStoreURL
        if let persistentStoreURL,
           let data = try? Data(contentsOf: persistentStoreURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            store = decoded
        }
    }

    public func update(_ scripts: [ScriptSource]) {
        lock.lock()
        sources = scripts
        disabled = disabled.filter { name, _ in scripts.contains { $0.name == name } }
        lock.unlock()
    }

    public var activeScripts: [ScriptSource] {
        lock.lock(); defer { lock.unlock() }
        return sources.filter { $0.enabled && disabled[$0.name] == nil }
    }

    /// Why a script stopped running, keyed by name. Surfaced in the editor.
    public var disabledReasons: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return disabled
    }

    // MARK: - Request phase

    public func runRequest(_ message: ScriptRequest, host: ScriptHost? = nil) -> ScriptRunResult {
        let host = host ?? self.host
        var logs: [String] = []
        var errors: [ScriptRunError] = []
        var headers = RewriteHeaders(message.headers)
        var body = message.body
        var current = ScriptRequest(method: message.method, url: message.url,
                                    headers: message.headers, body: message.body)

        for script in scripts(for: .request) {
            let state = RunState()
            state.logs = logs
            let started = Date()
            let out = execute(script, phase: .request, message: current, status: nil, host: host, state: state)
            logs = state.logs
            if let failure = failure(script: script, state: state, started: started) {
                record(script, failure)
                errors.append(ScriptRunError(script: script.name, reason: failure))
                continue
            }
            guard let out else { continue }
            switch out {
            case .proceed(let newHeaders, let newBody, let newURL):
                headers = newHeaders
                body = newBody
                current = ScriptRequest(method: message.method, url: newURL ?? current.url,
                                        headers: newHeaders.items.map { ($0.name, $0.value) },
                                        body: newBody)
            case .respond, .redirect:
                return ScriptRunResult(outcome: out, logs: logs, errors: errors)
            }
        }
        return ScriptRunResult(outcome: .proceed(headers: headers, body: body, url: nil),
                               logs: logs, errors: errors)
    }

    // MARK: - Response phase

    public func runResponse(url: String,
                            status: Int,
                            headers: [(name: String, value: String)],
                            body: Data,
                            host: ScriptHost? = nil) -> ResponseResult {
        let host = host ?? self.host
        var logs: [String] = []
        var errors: [ScriptRunError] = []
        var currentStatus = status
        var currentHeaders = RewriteHeaders(headers)
        var currentBody = body

        for script in scripts(for: .response) {
            let message = ScriptRequest(method: "RESPONSE", url: url,
                                        headers: currentHeaders.items.map { ($0.name, $0.value) },
                                        body: currentBody)
            let state = RunState()
            state.logs = logs
            let started = Date()
            let out = execute(script, phase: .response, message: message,
                              status: currentStatus, host: host, state: state)
            logs = state.logs
            if let failure = failure(script: script, state: state, started: started) {
                record(script, failure)
                errors.append(ScriptRunError(script: script.name, reason: failure))
                continue
            }
            if let out, case .proceed(let newHeaders, let newBody, _) = out {
                currentHeaders = newHeaders
                currentBody = newBody
                if let override = state.statusOverride { currentStatus = override }
            }
        }
        return ResponseResult(status: currentStatus, headers: currentHeaders, body: currentBody,
                              logs: logs, errors: errors)
    }

    // MARK: - Execution

    private func scripts(for phase: ScriptPhase) -> [ScriptSource] {
        lock.lock(); defer { lock.unlock() }
        return sources.filter { $0.enabled && $0.phase == phase && disabled[$0.name] == nil }
    }

    private func record(_ script: ScriptSource, _ reason: String) {
        lock.lock()
        disabled[script.name] = reason
        lock.unlock()
    }

    private func failure(script: ScriptSource, state: RunState, started: Date) -> String? {
        if let exception = state.exception {
            return "执行出错：\(exception)"
        }
        // The budget bounds the script's own evaluation, not the host's VM setup:
        // creating a JSContext and installing globals routinely costs tens of ms on a
        // loaded machine, and counting it disabled trivial scripts at random.
        let clockStart = state.evalStarted ?? started
        let elapsed = Int(Date().timeIntervalSince(clockStart) * 1000)
        if elapsed > budget.milliseconds {
            return "执行超时（\(elapsed) ms，上限 \(budget.milliseconds) ms）"
        }
        return nil
    }

    private func execute(_ script: ScriptSource,
                         phase: ScriptPhase,
                         message: ScriptRequest,
                         status: Int?,
                         host: ScriptHost?,
                         state: RunState) -> ScriptOutcome? {
        guard let context = JSContext() else {
            state.exception = "无法创建 JS 上下文"
            return nil
        }
        context.exceptionHandler = { _, exception in
            state.exception = exception?.toString() ?? "未知异常"
        }

        installGlobals(on: context, state: state, host: host, phase: phase)

        let key = phase == .request ? "$request" : "$response"
        context.setObject(messageObject(message, status: status), forKeyedSubscript: key as NSString)

        // The budget clock starts at the script's own evaluation; everything above is
        // host setup and would otherwise eat the whole 50ms on a busy machine.
        state.evalStarted = Date()
        context.evaluateScript(script.code, withSourceURL: URL(string: "leapin://\(script.name)"))

        if state.exception != nil { return nil }

        // `$done(payload)` overrides in-place edits of $request / $response.
        if let payload = state.donePayload {
            // In the response phase a payload may also change the status code; keep it
            // so the caller can write a different line back to the client.
            if phase == .response, let dict = payload as? [String: Any], let status = dict["status"] as? Int {
                state.statusOverride = status
            }
            return outcome(fromPayload: payload, phase: phase, fallback: message)
        }
        let object = context.objectForKeyedSubscript(key)
        if phase == .response, let dict = object?.toDictionary() as? [String: Any],
           let status = dict["status"] as? Int {
            state.statusOverride = status
        }
        return outcome(fromMessage: object, fallback: message)
    }

    private func messageObject(_ message: ScriptRequest, status: Int?) -> [String: Any] {
        var dict: [String: Any] = [
            "url": message.url,
            "method": message.method,
            "headers": Dictionary(message.headers.map { ($0.name, $0.value) },
                                  uniquingKeysWith: { _, last in last }),
            "body": String(decoding: message.body, as: UTF8.self),
        ]
        if let status { dict["status"] = status }
        return dict
    }

    /// Request phase: a payload with `status` answers locally.
    /// Response phase: a payload edits the response in place (status optional).
    private func outcome(fromPayload payload: Any, phase: ScriptPhase, fallback: ScriptRequest) -> ScriptOutcome? {
        guard let dict = payload as? [String: Any] else { return nil }
        if let target = dict["redirect"] as? String {
            return .redirect(url: target, status: (dict["status"] as? Int) ?? 302)
        }
        if phase == .request, let status = dict["status"] as? Int {
            let body = (dict["body"] as? String) ?? ""
            let contentType = (dict["contentType"] as? String) ?? "application/json"
            return .respond(status: status, contentType: contentType, body: Data(body.utf8))
        }
        let headers = dict["headers"] as? [String: String]
        let body = (dict["body"] as? String).map { Data($0.utf8) }
        return .proceed(headers: headers.map { Self.ordered($0) } ?? RewriteHeaders(fallback.headers),
                        body: body ?? fallback.body,
                        url: dict["url"] as? String)
    }

    private func outcome(fromMessage value: JSValue?, fallback: ScriptRequest) -> ScriptOutcome? {
        guard let value, value.isObject,
              let dict = value.toDictionary() as? [String: Any] else { return nil }
        let headers = (dict["headers"] as? [String: Any] ?? [:]).compactMap { key, raw in
            (raw as? String).map { (name: key, value: $0) }
        }
        let body = (dict["body"] as? String) ?? String(decoding: fallback.body, as: UTF8.self)
        return .proceed(headers: RewriteHeaders(headers), body: Data(body.utf8), url: dict["url"] as? String)
    }

    private static func ordered(_ dict: [String: String]) -> RewriteHeaders {
        RewriteHeaders(dict.keys.sorted().map { ($0, dict[$0] ?? "") })
    }

    private func installGlobals(on context: JSContext, state: RunState, host: ScriptHost?, phase: ScriptPhase) {
        let console = JSValue(newObjectIn: context)
        let logBlock: @convention(block) (JSValue?) -> Void = { value in
            let text = value?.toString() ?? ""
            if state.logs.count < 50 { state.logs.append(text) }
        }
        console?.setObject(logBlock, forKeyedSubscript: "log" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        let done: @convention(block) (JSValue?) -> Void = { value in
            state.doneCalled = true
            // No argument means "I edited $request / $response in place"; an argument is
            // an explicit payload. Conflating the two silently dropped every in-place edit.
            if let value, !value.isUndefined, !value.isNull {
                state.donePayload = value.toObject()
            }
        }
        context.setObject(done, forKeyedSubscript: "$done" as NSString)

        var environment = host?.environment ?? [:]
        environment["phase"] = phase.rawValue
        context.setObject(environment, forKeyedSubscript: "$environment" as NSString)

        let storeRead: @convention(block) (JSValue?) -> String? = { key in
            guard let key = key?.toString() else { return nil }
            return self.store[key]
        }
        let storeWrite: @convention(block) (JSValue?, JSValue?) -> Void = { key, value in
            guard let key = key?.toString() else { return }
            self.store[key] = value?.toString()
            self.persistStore()
        }
        let persistent = JSValue(newObjectIn: context)
        persistent?.setObject(storeRead, forKeyedSubscript: "read" as NSString)
        persistent?.setObject(storeWrite, forKeyedSubscript: "write" as NSString)
        context.setObject(persistent, forKeyedSubscript: "$persistentStore" as NSString)

        let notifyBlock: @convention(block) (JSValue?) -> Void = { payload in
            guard let dict = payload?.toDictionary() as? [String: Any] else { return }
            host?.notify(title: (dict["title"] as? String) ?? "Leapin",
                         body: (dict["body"] as? String) ?? "")
        }
        let notification = JSValue(newObjectIn: context)
        notification?.setObject(notifyBlock, forKeyedSubscript: "post" as NSString)
        context.setObject(notification, forKeyedSubscript: "$notification" as NSString)

        let getBlock: @convention(block) (JSValue?) -> [String: Any]? = { target in
            guard let host, let url = target?.toString(), state.httpUsed < self.budget.httpCalls else { return nil }
            state.httpUsed += 1
            guard let reply = host.httpGet(url: url, timeoutMs: 3000) else { return nil }
            return ["status": reply.status, "body": reply.body]
        }
        let client = JSValue(newObjectIn: context)
        client?.setObject(getBlock, forKeyedSubscript: "get" as NSString)
        context.setObject(client, forKeyedSubscript: "$httpClient" as NSString)
    }

    private func persistStore() {
        guard let persistentURL, let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: persistentURL, options: .atomic)
    }
}

/// Mutable box for one run, so the JS blocks can write back.
private final class RunState: @unchecked Sendable {
    var logs: [String] = []
    var doneCalled = false
    var donePayload: Any?
    var exception: String?
    /// Set just before the script's own evaluateScript runs; the budget is measured
    /// from here so VM setup never counts against the script.
    var evalStarted: Date?
    var httpUsed = 0
    var statusOverride: Int?
}

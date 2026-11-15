import Foundation
import LeapinCore
import LeapinScript

/// Host services the script sandbox may use.
///
/// Deliberately small: notifications and one synchronous HTTP GET. Everything else the
/// scripts might want lives on the other side of `$done`.
final class EngineScriptHost: ScriptHost, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: [String: String] = [:]

    init() {
        snapshot = [
            "app": "Leapin",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
        ]
    }

    /// Refreshed by the engine when it starts or the profile changes. Read from the
    /// script thread, so it is copied under a lock instead of reaching back into the
    /// main-actor engine.
    func update(configName: String, mixedPort: Int) {
        lock.lock()
        snapshot["config"] = configName
        snapshot["mixedPort"] = String(mixedPort)
        lock.unlock()
    }

    var environment: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    func notify(title: String, body: String) {
        // Kept in the log for now; a real user notification needs an explicit permission
        // flow, which is its own step rather than something to do behind the user.
        LPLog.shared.info("script.notify", "\(title): \(body)")
    }

    /// Blocking on purpose: JavaScript is synchronous, so a script that calls
    /// `$httpClient.get` waits. The timeout keeps a dead endpoint from stalling a
    /// proxied connection for longer than the script budget implies.
    func httpGet(url: String, timeoutMs: Int) -> (status: Int, body: String)? {
        guard let target = URL(string: url) else { return nil }
        var request = URLRequest(url: target)
        request.timeoutInterval = Double(timeoutMs) / 1000
        request.httpMethod = "GET"

        let semaphore = DispatchSemaphore(value: 0)
        var reply: (status: Int, body: String)?

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, let data {
                reply = (http.statusCode, String(decoding: data, as: UTF8.self))
            } else if let data {
                reply = (200, String(decoding: data, as: UTF8.self))
            }
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
            task.cancel()
            return nil
        }
        return reply
    }
}

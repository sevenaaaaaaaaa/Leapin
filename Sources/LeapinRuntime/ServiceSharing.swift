import Foundation
import Combine
import LeapinCore
import LeapinNet
import LeapinIntegrations

public struct ServiceSharePlan: Equatable, Sendable {
    public let origin: URL
    public let minutes: Int
    public let email: String?
    public let publicAccess: Bool
    public init(origin: String, minutes: Int, email: String, publicAccess: Bool) throws {
        guard let url = URL(string: origin), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host?.lowercased() ?? ""),
              let port = UInt16(exactly: url.port ?? 0), port > 0, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/", (1...120).contains(minutes) else {
            throw LeapinError.invalidConfiguration("请选择本机 HTTP / HTTPS 服务的明确端口，不带路径、参数或凭据；有效期为 1–120 分钟")
        }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard publicAccess || (email.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil) else {
            throw LeapinError.invalidConfiguration("请填写允许访问的邮箱，或明确选择任何持有链接的人可访问")
        }
        self.origin = url; self.minutes = minutes; self.email = publicAccess ? nil : email; self.publicAccess = publicAccess
    }
    public func arguments(emailSupported: Bool) throws -> [String] {
        guard email == nil || emailSupported else { throw LeapinError.unsupported("此 cloudflared 版本未提供邮箱访问限制，请升级，或重新审阅公开分享范围") }
        var args = ["tunnel", "--config", "/dev/null", "--url", origin.absoluteString, "--no-autoupdate"]
        if let email { args += ["--allowed-mail", email] }
        return args
    }
    public static func generatedURL(_ text: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: #"https://[a-z0-9]+(?:-[a-z0-9]+)*\.trycloudflare\.com(?![A-Za-z0-9_.-])"#) else { return nil }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { URL(string: ns.substring(with: $0.range)) }.last
    }
}

@MainActor
public final class ServiceSharing: ObservableObject {
    public let process = NetworkToolProcess()
    @Published public private(set) var url: URL?
    @Published public private(set) var expiresAt: Date?
    @Published public private(set) var message: String?
    @Published public private(set) var busy = false
    private var expiry: Task<Void, Never>?
    private var generation = UUID()
    private var failures: AnyCancellable?
    private let sleep: @Sendable (UInt64) async throws -> Void
    public init(sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.sleep = sleep
        failures = process.$failure.compactMap { $0 }.sink { [weak self] failure in
            self?.url = nil; self?.expiresAt = nil; self?.expiry?.cancel(); self?.message = failure
        }
    }
    public func start(_ plan: ServiceSharePlan) async {
        guard !busy else { return }
        stop(); let run = UUID(); generation = run; busy = true
        defer { if generation == run { busy = false } }
        do {
            guard let executable = NetworkTool.executable("cloudflared") else { throw LeapinError.unsupported("未发现 cloudflared，请先安装或选择可执行文件") }
            let help = try await Task.detached { try CommandRunner.runChecked(executable: executable.path, arguments: ["tunnel", "--help"], timeout: 5).combined }.value
            guard generation == run else { return }
            let arguments = try plan.arguments(emailSupported: help.contains("allowed-mail"))
            let probe = await HTTPProbe.probe(plan.origin.absoluteString, timeoutMs: 3000)
            guard generation == run else { return }
            guard probe.error == nil, probe.statusCode != nil else { throw LeapinError.connectionFailed("本地服务未返回 HTTP 响应：\(probe.error ?? "请先启动服务")") }
            message = "本地服务已响应，正在建立 Cloudflare 连接…"
            try await process.start(executable: executable, arguments: arguments, timeout: 25, removeEnvironmentPrefixes: ["TUNNEL_", "CF_", "CLOUDFLARED_"], removeEnvironmentKeys: ["NO_TLS_VERIFY"]) { logs in
                ServiceSharePlan.generatedURL(logs) != nil && logs.contains("Registered tunnel connection")
            }
            guard generation == run, process.running, let generated = ServiceSharePlan.generatedURL(process.logs) else { throw CancellationError() }
            url = generated; expiresAt = Date().addingTimeInterval(TimeInterval(plan.minutes * 60))
            message = "连接已建立，链接已生成；尚未验证外网访问。\(plan.email == nil ? "任何持有链接的人均可访问。" : "访客需通过允许邮箱登录；不适合无人值守 Agent。")"
            let wait = sleep
            expiry = Task { [weak self] in
                try? await wait(UInt64(plan.minutes) * 60_000_000_000)
                guard !Task.isCancelled, let self, self.generation == run else { return }
                self.stop(); self.message = "分享已到期，连接已停止。"
            }
        } catch {
            if generation == run { process.stop(); message = Redactor.redact(error.localizedDescription) }
        }
    }
    public func stop(force: Bool = false) {
        generation = UUID(); expiry?.cancel(); expiry = nil
        process.stop(force: force); url = nil; expiresAt = nil; busy = false; message = nil
    }
    public func reconcile() {
        if !process.running && !process.starting { url = nil; expiresAt = nil; expiry?.cancel(); message = process.failure ?? message }
    }
}

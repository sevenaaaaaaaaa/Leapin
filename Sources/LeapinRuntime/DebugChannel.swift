import Foundation
import Combine
import LeapinCore
import LeapinNet
import LeapinIntegrations

public struct DebugChannelPlan: Equatable, Sendable {
    public let host: String
    public let upstreamPort: UInt16
    public let upstreamCA: URL?
    public init(host: String, upstreamPort: UInt16, upstreamCA: URL? = nil) throws {
        guard let target = SiteTarget(host), upstreamPort > 0 else { throw LeapinError.invalidConfiguration("请指定要解密的网站和已就绪的 Mihomo 端口") }
        if let upstreamCA {
            guard upstreamCA.isFileURL else { throw LeapinError.invalidConfiguration("上游 CA 必须是本地证书文件") }
            let file = try FileHandle(forReadingFrom: upstreamCA); defer { try? file.close() }
            let data = try file.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
            guard upstreamCA.isFileURL, data.count <= 2 * 1024 * 1024, let pem = String(data: data, encoding: .utf8), pem.contains("BEGIN CERTIFICATE"), !pem.contains("PRIVATE KEY") else { throw LeapinError.invalidConfiguration("上游 CA 需为不含私钥的 PEM 证书") }
        }
        self.host = target.host; self.upstreamPort = upstreamPort; self.upstreamCA = upstreamCA
    }
    public func arguments(port: UInt16, directory: URL) -> [String] {
        let pattern = "^" + NSRegularExpression.escapedPattern(for: host) + "(:[0-9]+)?$"
        var args = ["--mode", "upstream:http://127.0.0.1:\(upstreamPort)", "--listen-host", "127.0.0.1", "--listen-port", String(port),
                "--allow-hosts", pattern, "--set", "confdir=\(directory.path)", "--set", "ssl_insecure=false",
                "--set", "connection_strategy=lazy", "--set", "flow_detail=0", "-s", directory.appendingPathComponent("metadata.py").path]
        if let upstreamCA { args += ["--set", "ssl_verify_upstream_trusted_ca=\(upstreamCA.path)"] }
        return args
    }
    static let addon = #"""
import json, os, time
from mitmproxy import http
_PATH = os.path.join(os.path.dirname(__file__), "requests.jsonl")
def emit(flow):
    if os.path.getsize(_PATH) > 2 * 1024 * 1024:
        return
    request = flow.request
    response = flow.response
    # Only origin-level metadata. No bodies, headers, paths, query or credentials.
    value = {"id": flow.id, "time": time.time(), "method": request.method,
             "host": request.host, "port": request.port, "scheme": request.scheme,
             "status": response.status_code if response else None,
             "http": response.http_version if response else None,
             "failed": flow.error is not None}
    with open(_PATH, "a", encoding="utf-8") as file:
        file.write(json.dumps(value, ensure_ascii=False) + "\n")
def response(flow: http.HTTPFlow):
    emit(flow)
def error(flow: http.HTTPFlow):
    emit(flow)
"""#
}

public struct DebugRequest: Decodable, Identifiable, Sendable {
    public let id: String
    public let time: TimeInterval
    public let method: String
    public let host: String
    public let port: Int
    public let scheme: String
    public let status: Int?
    public let http: String?
    public let failed: Bool
}

@MainActor
public final class DebugChannel: ObservableObject {
    public let process = NetworkToolProcess()
    @Published public private(set) var port: UInt16?
    @Published public private(set) var host: String?
    @Published public private(set) var message: String?
    @Published public private(set) var requests: [DebugRequest] = []
    @Published public private(set) var busy = false
    public let directory: URL
    private var generation = UUID()
    private var timer: Task<Void, Never>?
    public var certificateURL: URL { directory.appendingPathComponent("mitmproxy-ca-cert.pem") }
    public init(root: URL) { directory = root.appendingPathComponent("debug-channel") }
    public func start(_ plan: DebugChannelPlan) async {
        guard !busy else { return }
        stop(); let run = UUID(); generation = run; busy = true
        defer { if generation == run { busy = false } }
        do {
            guard let executable = NetworkTool.executable("mitmdump") else { throw LeapinError.unsupported("未找到 mitmdump，请先安装 mitmproxy 或选择可执行文件") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (name, contents) in [("metadata.py", DebugChannelPlan.addon), ("requests.jsonl", "")] {
                let file = directory.appendingPathComponent(name)
                try Data(contents.utf8).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            let port = try LoopbackPort.available()
            message = "正在建立独立调试通道…"
            try await process.start(executable: executable, arguments: plan.arguments(port: port, directory: directory), environment: ["PYTHONUNBUFFERED": "1"], removeEnvironmentKeys: ["SSLKEYLOGFILE"]) { logs in
                guard logs.contains("listening at"), logs.contains("127.0.0.1:\(port)") else { return false }
                guard let socket = try? await NetSocket.connect(host: "127.0.0.1", port: port, timeout: 0.2) else { return false }
                socket.close(); return true
            }
            guard generation == run else { return }
            self.port = port; host = plan.host
            message = "调试入口已就绪，尚未验证目标 HTTPS。为目标 App 设置此 HTTP 代理，并按需安装调试 CA；只解密所选网站，其余网站保持隧道。"
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled, let self, self.generation == run else { return }
                    self.refresh()
                }
            }
        } catch { if generation == run { process.stop(); message = Redactor.redact(error.localizedDescription) } }
    }
    public func refresh() {
        if !process.running && !process.starting { port = nil; timer?.cancel(); message = process.failure ?? message }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("requests.jsonl")), data.count <= 2 * 1024 * 1024 + 4096,
              let text = String(data: data, encoding: .utf8) else { return }
        requests = text.split(separator: "\n").suffix(100).compactMap { try? JSONDecoder().decode(DebugRequest.self, from: Data($0.utf8)) }
    }
    public func stop(force: Bool = false) {
        generation = UUID(); timer?.cancel(); timer = nil; process.stop(force: force); port = nil; host = nil; busy = false; message = nil
    }
}

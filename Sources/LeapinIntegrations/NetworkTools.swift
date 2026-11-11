import Foundation
import Combine
import Darwin
import LeapinCore

public struct NetworkTool: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let purpose: String
    public let upstream: URL
    public let documentation: URL
    public let license: String
    public let licenseURL: URL
    public static let catalog: [NetworkTool] = [
        NetworkTool(id: "mihomo", title: "Mihomo", purpose: "协议、分流、来源 DNS 与 SOCKS5 UDP", upstream: URL(string: "https://github.com/MetaCubeX/mihomo")!, documentation: URL(string: "https://wiki.metacubex.one/")!, license: "GPL-3.0 · 当前适配版本 1.19.25", licenseURL: URL(string: "https://github.com/MetaCubeX/mihomo/blob/v1.19.25/LICENSE")!),
        NetworkTool(id: "mitmdump", title: "mitmproxy", purpose: "限定网站的 HTTPS 调试通道", upstream: URL(string: "https://github.com/mitmproxy/mitmproxy")!, documentation: URL(string: "https://docs.mitmproxy.org/stable/")!, license: "MIT", licenseURL: URL(string: "https://github.com/mitmproxy/mitmproxy/blob/main/LICENSE")!),
        NetworkTool(id: "cloudflared", title: "cloudflared", purpose: "限时分享本地 HTTP 服务", upstream: URL(string: "https://github.com/cloudflare/cloudflared")!, documentation: URL(string: "https://developers.cloudflare.com/tunnel/")!, license: "Apache-2.0", licenseURL: URL(string: "https://github.com/cloudflare/cloudflared/blob/master/LICENSE")!)
    ]
    public static func executable(_ id: String) -> URL? {
        let key = "LEAPIN_" + id.uppercased() + "_PATH"
        let paths = [ProcessInfo.processInfo.environment[key], UserDefaults.standard.string(forKey: "leapin.\(id).path"), "/opt/homebrew/bin/\(id)", "/usr/local/bin/\(id)"]
        return paths.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    public static func version(_ id: String) async throws -> String {
        guard let executable = executable(id) else { throw LeapinError.unsupported("未找到 \(id)，请安装或选择可执行文件") }
        if id == "mihomo" { return try await KernelExecutable.version(at: executable) }
        return try await Task.detached {
            let result = try CommandRunner.runChecked(executable: executable.path, arguments: ["--version"], timeout: 12)
            return String(Redactor.redact(result.combined).prefix(400))
        }.value
    }
}

private final class ToolOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ value: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(value); if bytes.count > 32768 { bytes.removeFirst(bytes.count - 32768) } }
    var text: String { lock.lock(); defer { lock.unlock() }; return Redactor.redact(String(decoding: bytes, as: UTF8.self)) }
}

/// Each operation owns one process, one bounded output buffer and one generation.
/// Stop and late startup callbacks cannot resurrect a cancelled operation.
@MainActor
public final class NetworkToolProcess: ObservableObject {
    @Published public private(set) var running = false
    @Published public private(set) var starting = false
    @Published public private(set) var failure: String?
    private var child: Process?
    private var pipe: Pipe?
    private var output = ToolOutput()
    private var generation = UUID()
    public init() {}
    public var logs: String { output.text }
    public func start(executable: URL, arguments: [String], environment: [String: String] = [:],
                      timeout: TimeInterval = 15, removeEnvironmentPrefixes: [String] = [], removeEnvironmentKeys: [String] = [], ready: @escaping @MainActor (String) async -> Bool) async throws {
        stop()
        let run = UUID(); generation = run
        starting = true; failure = nil
        let process = Process(); let stream = Pipe(); let captured = ToolOutput()
        output = captured; child = process; pipe = stream
        process.executableURL = executable; process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        environment.forEach { env[$0.key] = $0.value }
        for key in Array(env.keys) where removeEnvironmentKeys.contains(key) || removeEnvironmentPrefixes.contains(where: key.hasPrefix) { env.removeValue(forKey: key) }
        process.environment = env; process.standardInput = FileHandle.nullDevice
        process.standardOutput = stream; process.standardError = stream
        stream.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData; if !data.isEmpty { captured.append(data) }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.generation == run else { return }
                self.running = false; self.starting = false
                self.failure = "工具已退出（\(process.terminationStatus)）。\(captured.text.suffix(400))"
            }
        }
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                guard generation == run else { throw CancellationError() }
                guard process.isRunning else { throw LeapinError.connectionFailed("工具启动退出：\(captured.text.suffix(400))") }
                let isReady = await ready(captured.text)
                guard generation == run, process.isRunning else { throw CancellationError() }
                if isReady { running = true; starting = false; return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw LeapinError.timeout
        } catch {
            if generation == run { stop(); failure = Redactor.redact(error.localizedDescription) }
            throw error
        }
    }
    public func stop(force: Bool = false) {
        generation = UUID(); running = false; starting = false; failure = nil
        pipe?.fileHandleForReading.readabilityHandler = nil; pipe = nil
        if let process = child, process.isRunning {
            process.terminate()
            if force { Darwin.kill(process.processIdentifier, SIGKILL) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
        }
        child = nil
    }
}

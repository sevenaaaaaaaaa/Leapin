import Foundation
import Darwin
import LeapinCore
import LeapinIntegrations

/// A separate, explicit CLI session. The GUI never elevates itself, modifies
/// system DNS or starts an unauthenticated privileged helper.
@MainActor
public final class ManagedTUNSession {
    public let kernel: ManagedMihomo
    private let directory: URL
    public init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("leapin-tun-\(UUID().uuidString)"), executable: URL? = nil) { self.directory = directory; kernel = ManagedMihomo(executable: executable) }
    public func check(source: String) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try await kernel.validate(source: source, directory: directory, tun: true)
    }
    public func start(source: String) async throws {
        guard geteuid() == 0 else { throw LeapinError.unsupported("此终端 TUN 会话需要管理员权限；请先检查导出的启动包，再通过 sudo 运行。图形 App 不应以 root 运行。") }
        _ = try await kernel.start(source: source, directory: directory, tun: true)
    }
    public func stop() { kernel.stop(waitForExit: true) }
}

public struct TUNLaunchPlan: Sendable {
    public let source: String
    public init(source: String) throws {
        guard source.utf8.count <= 8 * 1024 * 1024, try MiniYAML.parse(source).map != nil else { throw LeapinError.invalidConfiguration("请选择有效的 Mihomo 来源") }
        self.source = source
    }
    public func export(to directory: URL, cli: URL, kernel: URL? = KernelExecutable.mihomo()) throws -> URL {
        guard let kernel else { throw LeapinError.unsupported("导出启动包前请先指定 Mihomo 可执行文件") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let sourceURL = directory.appendingPathComponent("source.yaml")
        try Data(source.utf8).write(to: sourceURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceURL.path)
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = directory.appendingPathComponent("start.command")
        let contents = """
        #!/bin/bash
        set -euo pipefail
        printf '%s\\n' 'Leapin TUN：将创建虚拟网卡与路由；Ctrl-C 停止自有会话。先退出其他全局接管模式。'
        exec /usr/bin/sudo -- \(quote(cli.path)) tun --kernel \(quote(kernel.path)) --source \(quote(sourceURL.path))
        """
        try Data(contents.utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
}

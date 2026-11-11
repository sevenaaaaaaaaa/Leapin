import Foundation
import LeapinCore

public struct SystemVPNService: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let status: String
    public static func parse(_ text: String) -> [Self] {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^\s*\*?\s*\(([^)]+)\)\s+([0-9A-Fa-f-]{36})[^\n]*?\"([^\"]+)\""#) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            guard let id = UUID(uuidString: ns.substring(with: $0.range(at: 2))) else { return nil }
            return Self(id: id, name: ns.substring(with: $0.range(at: 3)), status: ns.substring(with: $0.range(at: 1)))
        }
    }
}
public struct SystemVPNConnector: Sendable {
    private let executable: URL
    public init(executable: URL = URL(fileURLWithPath: "/usr/sbin/scutil")) { self.executable = executable }
    private func run(_ arguments: [String]) async throws -> CommandOutput {
        try await Task.detached { try CommandRunner.runChecked(executable: executable.path, arguments: ["--nc"] + arguments, timeout: 6) }.value
    }
    public func services() async throws -> [SystemVPNService] { SystemVPNService.parse(try await run(["list"]).stdout) }
    public func start(_ id: UUID) async throws -> String {
        guard try await services().contains(where: { $0.id == id }) else { throw LeapinError.invalidConfiguration("此 VPN 已不在本机列表，请重新绑定；其他厂商工具请使用客户端入口") }
        _ = try await run(["start", id.uuidString])
        return try await run(["status", id.uuidString]).stdout.components(separatedBy: .newlines).first ?? "Unknown"
    }
}

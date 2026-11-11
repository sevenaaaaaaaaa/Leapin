import Foundation
import LeapinCore
import LeapinPolicy

public enum ExecutionKernel: String, Codable, CaseIterable, Sendable, Identifiable {
    case native, mihomo
    public var id: String { rawValue }
    public var title: String { self == .native ? "Leapin 原生" : "Mihomo" }
}

public struct KernelSource: Codable, Sendable {
    public var kernel: ExecutionKernel
    public var clash: String
    public var selections: [String: String]?
    public init(kernel: ExecutionKernel, clash: String) { self.kernel = kernel; self.clash = clash }
}

/// An immutable preview. Parsing never writes to the profile store or switches
/// the running engine. The original Clash source remains the external engine's input.
public struct ImportPreparation: Identifiable, Sendable {
    public let id: UUID
    public let outcome: ProfileImportOutcome
    public let clashSource: String
    public let preservesClashSource: Bool
    public let nativeBlockers: [String]
    public let origin: String
    public var externalConversionBlockers: [String] {
        guard !preservesClashSource else { return [] }
        return outcome.report.issues.filter { $0.kind != .unknownProtocol }.map { $0.display }
    }

    public init(text: String, name: String, origin: String = "粘贴内容", pathExtension: String? = nil) throws {
        guard text.utf8.count <= 8 * 1024 * 1024 else { throw LeapinError.invalidConfiguration("配置超过 8 MB") }
        let format = ProfileFormatDetector.detect(text: text, pathExtension: pathExtension)
        let outcome = try ProfileImporter.importText(text, name: name, pathExtension: pathExtension)
        guard !outcome.report.issues.contains(where: { $0.kind.isBlocking }) else {
            throw LeapinError.invalidConfiguration("配置解析失败，请修正文件后重新检查")
        }
        self.id = outcome.profile.id
        self.outcome = outcome
        self.preservesClashSource = format == .clash
        self.clashSource = format == .clash ? text : ProfileExporter.clash(outcome.profile)
        self.origin = origin
        var blockers: [String] = []
        for outbound in outcome.profile.outbounds {
            var why: String?
            if !outbound.type.isDialable { why = "协议 \(outbound.rawType ?? outbound.type.rawValue)" }
            else if let transport = outbound.network, !transport.isEmpty, transport.lowercased() != "tcp" { why = "传输 \(transport)" }
            else if outbound.type == .shadowsocks,
                    !["aes-256-gcm", "chacha20-ietf-poly1305"].contains(outbound.cipher?.lowercased() ?? "") { why = "加密 \(outbound.cipher ?? "未指定")" }
            else if outbound.type != .direct && outbound.type != .reject && (outbound.host.isEmpty || outbound.port == 0) { why = "缺少有效的服务器地址或端口" }
            else if outbound.plugin != nil { why = "协议插件" }
            else if outbound.security?.lowercased() == "reality" { why = "Reality" }
            else if outbound.skipCertVerify == true { why = "跳过证书校验（原生不采用此设置）" }
            if let why { blockers.append("\(outbound.name)：原生不支持\(why)") }
        }
        if !outcome.profile.proxyProviders.isEmpty { blockers.append("原生不执行 proxy-providers 动态节点集合") }
        for issue in outcome.report.issues where issue.kind == .unknownGroupType || issue.kind == .ruleError || issue.kind == .skippedItem || issue.kind == .duplicateName || issue.kind == .unsupportedField || issue.kind == .unsupportedSection {
            blockers.append(issue.display)
        }
        self.nativeBlockers = blockers
    }

    public static func download(_ link: String, name: String) async throws -> ImportPreparation {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else {
            throw LeapinError.invalidConfiguration("请输入有效的 http(s) 订阅链接")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Leapin/2", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LeapinError.connectionFailed("订阅下载失败，请检查链接与访问权限")
        }
        guard data.count <= 8 * 1024 * 1024, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw LeapinError.invalidConfiguration("订阅需要非空 UTF-8 文本，大小不超过 8 MB")
        }
        return try ImportPreparation(text: text, name: name.isEmpty ? (url.host ?? "订阅") : name,
                                     origin: url.host ?? "远程订阅")
    }
}

public extension ProfileStore {
    func kernelSource(for id: UUID) throws -> KernelSource? {
        let url = root.appendingPathComponent("kernel-sources/\(id.uuidString).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(KernelSource.self, from: Data(contentsOf: url))
    }

    func saveKernelSource(_ source: KernelSource?, for id: UUID) throws {
        let directory = root.appendingPathComponent("kernel-sources", isDirectory: true)
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        guard let source else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(source).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

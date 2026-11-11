import Foundation
import LeapinCore

/// Portable data, never commands, local application paths, credentials or VPN IDs.
public struct CompanyAccessTemplate: Codable, Sendable {
    public struct Resource: Codable, Sendable { public let title: String; public let address: String }
    public let version: Int
    public let name: String
    public let method: CompanyAccessMethod
    public let portal: URL?
    public let proxy: URL?
    public let notes: String
    public let resources: [Resource]
    public init(_ company: CompanyConnection) {
        version = 1; name = company.name; method = company.method; portal = company.portal; proxy = company.proxy; notes = company.notes
        resources = company.resources.map { Resource(title: $0.title, address: $0.url.absoluteString) }
    }
    public func draft() throws -> CompanyConnection {
        guard version == 1, resources.count <= 100 else { throw LeapinError.invalidConfiguration("仅支持版本 1 的公司资源模板，每份最多 100 个资源") }
        let draft = CompanyConnection(name: name, method: method,
            resources: try resources.map { try CompanyResource(title: $0.title, address: $0.address) }, portal: portal, proxy: proxy, notes: notes)
        var checked = draft
        // A template intentionally has no machine-specific binding; save still
        // requires selecting a real configured VPN on this computer.
        if checked.method == .systemVPN { checked.vpnServiceID = UUID() }
        try checked.validate(); return draft
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1024 * 1024 else { throw LeapinError.invalidConfiguration("模板不能超过 1 MB") }
        let template = try JSONDecoder().decode(Self.self, from: data)
        _ = try template.draft(); return template
    }
    public func data() throws -> Data {
        _ = try draft()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

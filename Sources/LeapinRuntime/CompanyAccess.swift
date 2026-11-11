import Foundation
import Combine
import LeapinCore
import LeapinNet
import LeapinPolicy

public enum CompanyAccessMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case client, systemVPN, browser, httpProxy, socksProxy
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .client: return "已有客户端 / VPN / 办公网"
        case .systemVPN: return "macOS 已配置 VPN"
        case .browser: return "浏览器统一登录"
        case .httpProxy: return "HTTP / HTTPS 内网代理"
        case .socksProxy: return "SOCKS5 内网代理"
        }
    }
    public var isProxy: Bool { self == .httpProxy || self == .socksProxy }
    public var usesSystemDNS: Bool { self == .client || self == .systemVPN }
}

public struct CompanyResource: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var url: URL
    public var host: String { Self.normalizedHost(url.host ?? "") }
    public var port: UInt16 { UInt16(url.port ?? ["https": 443, "http": 80, "smb": 445, "ssh": 22][url.scheme?.lowercased() ?? ""] ?? 443) }
    public var isWeb: Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") }
    public var origin: URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.path = "/"; parts.query = nil; parts.fragment = nil
        return parts.url!
    }
    public init(id: UUID = UUID(), title: String, address: String) throws {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: \.isWhitespace), !text.contains("\\"),
              let url = URL(string: text.contains("://") ? text : "https://" + text),
              ["http", "https", "smb", "ssh"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, let raw = url.host,
              Self.validHost(Self.normalizedHost(raw)),
              (1...65535).contains(url.port ?? 443) else {
            throw LeapinError.invalidConfiguration("请输入 HTTP、HTTPS、SMB 或 SSH 地址；支持内网短主机名和 IP，不接受 URL 登录凭据")
        }
        self.id = id; self.url = url
        self.title = String((title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.normalizedHost(raw) : title).prefix(100))
    }
    public func matchesProxyBypass(_ patterns: [String]) -> Bool {
        patterns.contains { pattern in
            if pattern == "<local>", !host.contains("."), !NetAddress.isIPLiteral(host) { return true }
            if HostGlob.matches(host, pattern: pattern) { return true }
            if let cidr = CIDR(pattern) {
                if let ip = IPParse.ipv4(host) { return cidr.contains(ipv4: ip) }
                if let ip = IPParse.ipv6(host) { return cidr.contains(ipv6: ip) }
            }
            return false
        }
    }
    public static func normalizedHost(_ raw: String) -> String { raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]")) }
    public static func validHost(_ host: String) -> Bool {
        NetAddress.isIPLiteral(host) || (!host.isEmpty && host.count <= 253 && host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        })
    }
}

public struct CompanyConnection: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var method: CompanyAccessMethod
    public var resources: [CompanyResource]
    public var application: URL?
    public var portal: URL?
    public var vpnServiceID: UUID?
    public var proxy: URL?
    public var notes: String
    public init(id: UUID = UUID(), name: String, method: CompanyAccessMethod = .client,
                resources: [CompanyResource] = [], application: URL? = nil, portal: URL? = nil,
                vpnServiceID: UUID? = nil, proxy: URL? = nil, notes: String = "") {
        self.id = id; self.name = name; self.method = method; self.resources = resources
        self.application = application; self.portal = portal; self.vpnServiceID = vpnServiceID; self.proxy = proxy; self.notes = notes
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
              !resources.isEmpty, resources.count <= 100, Set(resources.map(\.id)).count == resources.count,
              notes.count <= 2000 else { throw LeapinError.invalidConfiguration("请填写公司名称并添加 1–100 个资源，说明最多 2000 字") }
        for resource in resources {
            let checked = try CompanyResource(id: resource.id, title: resource.title, address: resource.url.absoluteString)
            guard checked.url == resource.url, checked.title == resource.title else { throw LeapinError.invalidConfiguration("资源必须使用完整 URL 和有效名称") }
        }
        if let application {
            guard application.isFileURL, application.pathExtension.lowercased() == "app" else { throw LeapinError.invalidConfiguration("客户端入口请选择本机 .app 应用") }
        }
        if let proxy {
            guard ["http", "https", "socks5"].contains(proxy.scheme?.lowercased() ?? ""), proxy.user == nil, proxy.password == nil,
                  proxy.query == nil, proxy.fragment == nil, let host = proxy.host, CompanyResource.validHost(CompanyResource.normalizedHost(host)),
                  proxy.path.isEmpty || proxy.path == "/", let port = proxy.port, (1...65535).contains(port) else {
                throw LeapinError.invalidConfiguration("代理配置不能包含 URL 凭据或临时令牌，且需要明确端口")
            }
        }
        if let portal {
            guard ["http", "https"].contains(portal.scheme?.lowercased() ?? ""), portal.host != nil, portal.user == nil, portal.password == nil else { throw LeapinError.invalidConfiguration("统一登录入口需为不含凭据的 HTTP(S) 地址") }
            let transient = Set(["token", "access_token", "id_token", "code", "ticket", "password", "secret", "refresh_token", "client_secret", "samlresponse", "assertion", "authorization"])
            guard !(URLComponents(url: portal, resolvingAgainstBaseURL: false)?.queryItems ?? []).contains(where: { transient.contains($0.name.lowercased()) }) else {
                throw LeapinError.invalidConfiguration("请使用稳定登录入口，不要保存带临时令牌的登录回调")
            }
        }
        if method == .browser {
            guard portal != nil, resources.allSatisfy(\.isWeb) else { throw LeapinError.invalidConfiguration("浏览器登录需填写登录入口，资源仅支持 Web 地址") }
        }
        if method == .systemVPN, vpnServiceID == nil { throw LeapinError.invalidConfiguration("请选择一个 macOS 已配置的 VPN，其他客户端请使用第一种接入方式") }
        if method.isProxy {
            _ = try proxyOutbound()
            guard resources.allSatisfy(\.isWeb) else { throw LeapinError.unsupported("内网代理模式当前只接入 Web 资源；SMB / SSH 请使用 VPN 或已有客户端") }
        }
    }
    public var policyName: String { "Company-" + id.uuidString }
    public func proxyOutbound() throws -> OutboundConfig {
        guard method.isProxy, let proxy, proxy.user == nil, proxy.password == nil,
              proxy.query == nil, proxy.fragment == nil, proxy.path.isEmpty || proxy.path == "/",
              let raw = proxy.host, CompanyResource.validHost(CompanyResource.normalizedHost(raw)),
              let port = UInt16(exactly: proxy.port ?? 0), port > 0,
              method == .httpProxy ? ["http", "https"].contains(proxy.scheme?.lowercased() ?? "") : proxy.scheme?.lowercased() == "socks5" else {
            throw LeapinError.invalidConfiguration("代理需为带明确端口的 http(s)://host:port 或 socks5://host:port，不带 URL 凭据；认证型 / PAC 代理请交由公司客户端")
        }
        return OutboundConfig(name: policyName, type: method == .httpProxy ? .http : .socks5,
                              host: CompanyResource.normalizedHost(raw), port: port, tls: proxy.scheme?.lowercased() == "https")
    }
    public var systemDNSHosts: Set<String> {
        if method.usesSystemDNS { return Set(resources.map(\.host)) }
        if method.isProxy, let host = proxy?.host { return [CompanyResource.normalizedHost(host)] }
        return []
    }
    public func validateLoops(ports: [UInt16], homeHost: String?) throws {
        try validate()
        let loopbacks = Set(["127.0.0.1", "localhost", "::1", "0.0.0.0", "::"])
        if method != .browser, let homeHost, resources.contains(where: { $0.host == homeHost }) {
            throw LeapinError.invalidConfiguration("公司资源与家庭资源使用了同一主机，请先移除其中一个绑定")
        }
        guard !resources.contains(where: { loopbacks.contains($0.host) && ports.contains($0.port) }) else {
            throw LeapinError.invalidConfiguration("资源不能指向 Leapin 自己的监听端口")
        }
        if method.isProxy {
            let outbound = try proxyOutbound()
            guard !(loopbacks.contains(outbound.host) && ports.contains(outbound.port)) else { throw LeapinError.invalidConfiguration("内网代理不能指向 Leapin / 受管内核自己的入口，会产生循环") }
        }
    }
    public func routing(_ base: Profile) throws -> Profile {
        try validate()
        guard method != .browser else { return base }
        guard !base.outbounds.contains(where: { $0.name == policyName }), !base.groups.contains(where: { $0.name == policyName }) else {
            throw LeapinError.invalidConfiguration("公司线路标识与当前配置冲突，请重新创建公司配置")
        }
        var profile = base
        profile.outbounds.append(method.isProxy ? try proxyOutbound() : OutboundConfig(name: policyName, type: .direct))
        profile.rules.insert(contentsOf: Set(resources.map(\.host)).sorted().map { Rule(kind: .domain, value: $0, policy: policyName, raw: "DOMAIN,\($0),\(policyName)") }, at: 0)
        return profile
    }
}

public struct CompanyAccessConfiguration: Codable, Sendable, Equatable {
    public var companies: [CompanyConnection]
    public var activeID: UUID?
    public init(companies: [CompanyConnection] = [], activeID: UUID? = nil) { self.companies = companies; self.activeID = activeID }
    public var active: CompanyConnection? { companies.first { $0.id == activeID } }
    public static func load(root: URL) throws -> Self {
        let file = root.appendingPathComponent("company-access.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return Self() }
        let data = try Data(contentsOf: file)
        guard data.count <= 4 * 1024 * 1024 else { throw LeapinError.invalidConfiguration("公司配置文件过大") }
        let configuration = try JSONDecoder().decode(Self.self, from: data)
        try configuration.validate(); return configuration
    }
    public func validate() throws {
        guard companies.count <= 50, Set(companies.map(\.id)).count == companies.count,
              activeID == nil || active != nil else { throw LeapinError.invalidConfiguration("公司配置标识无效") }
        try companies.forEach { try $0.validate() }
    }
    public func save(root: URL) throws {
        try validate()
        let file = root.appendingPathComponent("company-access.json")
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// Corporate names use the operating system's resolver (including VPN scoped
/// resolvers). Never retry them against Leapin's public DoH/fallback pipeline.
public struct CompanyScopedResolver: NameResolving, Sendable {
    private let base: any NameResolving
    private let system: any NameResolving
    private let hosts: Set<String>
    public init(base: any NameResolving, hosts: Set<String>, system: any NameResolving = CompanyScopedResolver.systemResolver()) {
        self.base = base; self.hosts = hosts; self.system = system
    }
    public static func systemResolver() -> DNSResolver { DNSResolver(config: DNSConfig(mode: .system, upstreams: [], fallback: [], cacheTTL: 0)) }
    public func resolve(_ host: String) async throws -> [String] {
        try await (hosts.contains(CompanyResource.normalizedHost(host)) ? system : base).resolve(host)
    }
}

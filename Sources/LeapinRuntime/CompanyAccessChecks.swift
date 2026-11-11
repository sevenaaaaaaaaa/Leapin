import Foundation
import Combine
import CFNetwork
import LeapinCore
import LeapinNet
import LeapinIntegrations

private final class NoCompanyRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum CompanyWebProbe {
    /// nil + systemDefault means normal system policy. Otherwise a nil port
    /// explicitly bypasses HTTP/SOCKS proxies while retaining OS VPN routing.
    public static func probe(_ origin: URL, proxyPort: UInt16?, systemDefault: Bool = false) async -> HTTPProbeResult {
        let started = Date()
        var result = HTTPProbeResult(url: origin.absoluteString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let proxyPort {
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1, kCFNetworkProxiesHTTPProxy as String: "127.0.0.1", kCFNetworkProxiesHTTPPort as String: Int(proxyPort),
                kCFNetworkProxiesHTTPSEnable as String: 1, kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1", kCFNetworkProxiesHTTPSPort as String: Int(proxyPort)]
        } else if !systemDefault {
            configuration.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable as String: 0, kCFNetworkProxiesHTTPSEnable as String: 0, kCFNetworkProxiesSOCKSEnable as String: 0]
        }
        let session = URLSession(configuration: configuration, delegate: NoCompanyRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: origin); request.httpMethod = "HEAD"; request.timeoutInterval = 6
        do {
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw LeapinError.protocolError("未返回 HTTP 响应") }
            result.statusCode = response.statusCode
        } catch { result.error = Redactor.redact(error.localizedDescription) }
        result.elapsedMs = Date().timeIntervalSince(started) * 1000; return result
    }
}

public struct CompanyCheckStep: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let problem: Bool
}
public struct CompanyAccessReport: Sendable {
    public let companyID: UUID
    public let resourceID: UUID
    public let date: Date
    public let steps: [CompanyCheckStep]
    public var hasProblem: Bool { steps.contains(where: \.problem) }
}

@MainActor
public final class CompanyAccess: ObservableObject {
    @Published public private(set) var configuration: CompanyAccessConfiguration
    @Published public private(set) var message: String?
    @Published public private(set) var failed = false
    @Published public private(set) var checking: UUID?
    @Published public private(set) var reports: [UUID: CompanyAccessReport] = [:]
    private let root: URL
    private let resolver: any NameResolving
    private let tcp: @Sendable (String, UInt16) async throws -> Void
    private let web: @Sendable (URL, UInt16?, Bool) async -> HTTPProbeResult
    private var generation = UUID()
    public var active: CompanyConnection? { configuration.active }
    public init(root: URL, resolver: any NameResolving = CompanyScopedResolver.systemResolver(),
                tcp: @escaping @Sendable (String, UInt16) async throws -> Void = { host, port in
                    let socket = try await NetSocket.connect(host: host, port: port, timeout: 3); socket.close()
                }, web: @escaping @Sendable (URL, UInt16?, Bool) async -> HTTPProbeResult = { await CompanyWebProbe.probe($0, proxyPort: $1, systemDefault: $2) }) {
        self.root = root; self.resolver = resolver; self.tcp = tcp; self.web = web
        do { configuration = try CompanyAccessConfiguration.load(root: root) }
        catch { configuration = CompanyAccessConfiguration(); message = "公司配置无法读取，请检查本机 company-access.json：\(error.localizedDescription)"; failed = true }
    }
    public func save(_ company: CompanyConnection, expected: CompanyConnection?, activate: Bool = true, apply: () throws -> Void) throws {
        try company.validate()
        guard configuration.companies.first(where: { $0.id == company.id }) == expected else { throw LeapinError.invalidConfiguration("公司配置已变化，请重新打开表单") }
        var next = configuration
        if let index = next.companies.firstIndex(where: { $0.id == company.id }) { next.companies[index] = company }
        else { next.companies.append(company) }
        if activate { next.activeID = company.id }
        try commit(next, apply: apply)
        message = activate ? "已保存并启用公司资源配置；网络连接和登录状态尚未验证。" : "已保存公司配置，尚未启用。"
    }
    public func activate(_ id: UUID?, apply: () throws -> Void) throws {
        var next = configuration; next.activeID = id
        try commit(next, apply: apply)
        message = id == nil ? "已暂停公司分流，恢复当前方案；现有连接不受影响。" : "已切换公司资源配置；现有连接不变，登录状态未验证。"
    }
    public func remove(_ id: UUID, apply: () throws -> Void) throws {
        var next = configuration; next.companies.removeAll { $0.id == id }
        if next.activeID == id { next.activeID = nil }
        try commit(next, apply: apply); message = "已移除本地公司入口；没有断开公司客户端或 VPN。"
    }
    private func commit(_ next: CompanyAccessConfiguration, apply: () throws -> Void) throws {
        let previous = configuration
        try next.save(root: root)
        do { try apply() }
        catch { try previous.save(root: root); throw error }
        generation = UUID(); checking = nil; reports = [:]
        configuration = next; failed = false
    }
    public func notice(_ text: String, failed: Bool = false) { message = text; self.failed = failed }
    public func cancelCheck() { generation = UUID(); checking = nil; message = "检查已取消。" }
    public func check(_ resource: CompanyResource, proxyPort: UInt16?, contextValid: () -> Bool = { true }) async {
        guard checking == nil, let company = active, company.resources.contains(resource) else { return }
        let run = UUID(); generation = run; checking = resource.id; failed = false
        let snapshot = configuration
        reports[resource.id] = nil
        func valid() -> Bool {
            guard generation == run, configuration == snapshot else { return false }
            guard contextValid() else { message = "检查期间网络配置发生变化，请重新检查。"; failed = true; return false }
            return true
        }
        var steps: [CompanyCheckStep] = []
        func step(_ id: String, _ title: String, _ detail: String, problem: Bool = false) {
            steps.append(CompanyCheckStep(id: id, title: title, detail: Redactor.redact(detail), problem: problem))
        }
        defer { if generation == run { checking = nil } }
        do {
            message = "正在检查 \(resource.title)…"
            if company.method != .browser {
                let targetHost = company.method.isProxy ? CompanyResource.normalizedHost(company.proxy?.host ?? "") : resource.host
                let targetPort = company.method.isProxy ? UInt16(company.proxy!.port!) : resource.port
                let addresses = try await resolver.resolve(targetHost)
                guard valid() else { return }
                guard !addresses.isEmpty else { throw LeapinError.connectionFailed("系统 / VPN DNS 没有返回地址，请先连接公司网络") }
                step("dns", company.method.isProxy ? "内网代理的系统解析" : "系统 / VPN DNS", addresses.joined(separator: " · ") + "；不向 Leapin 公共 DNS 回退")
                var connected = false
                for address in addresses.prefix(3) {
                    do { try await tcp(address, targetPort); connected = true; break } catch { continue }
                }
                guard valid() else { return }
                guard connected else { throw LeapinError.connectionFailed("系统路径到服务端口不可达。请检查 VPN / 客户端、网段路由、访问策略与端口，Leapin 不会自动更改它们。") }
                step("tcp", company.method.isProxy ? "内网代理端口可达" : "服务端口可达", "TCP \(targetPort) 已响应；不代表登录或业务功能可用")
            }
            if resource.isWeb {
                if company.method.isProxy && proxyPort == nil { throw LeapinError.connectionFailed("内网代理需要 Leapin 本地入口运行，启动本地服务后再检查；本次未请求目标域名") }
                let result = await web(resource.origin, company.method.isProxy ? proxyPort : nil, company.method == .browser)
                guard valid() else { return }
                if let error = result.error { step("web", "Web 检查未完成", error + "。请核对 TLS、代理认证与访问策略；不会关闭证书校验。", problem: true) }
                else {
                    let status = result.statusCode ?? 0
                    let detail: String
                    switch status {
                    case 200..<300: detail = "根地址已响应；未携带完整路径、参数、Cookie 或账号，仍需在浏览器登录验证。"
                    case 300..<400: detail = "根地址返回跳转；未自动跟随，可能需要从统一登录入口完成认证。"
                    case 401, 403: detail = "服务或访问网关要求身份 / 权限，请在官方客户端或浏览器处理认证。"
                    case 407: detail = "代理要求认证。当前专用代理不处理 PAC / NTLM / Kerberos，请使用公司官方客户端或已获授权的无认证代理。"
                    case 405, 501: detail = "站点不支持 HEAD；不能据此判断业务访问失败，请在目标 App 验证。"
                    default: detail = "已收到响应，但业务状态需要进一步检查。"
                    }
                    step("web", "HEAD HTTP \(status)", detail, problem: status >= 400 && status != 405 && status != 501)
                }
            }
        } catch {
            guard valid() else { return }
            step("failed", "检查发现阻碍", error.localizedDescription, problem: true)
        }
        guard valid() else { return }
        let report = CompanyAccessReport(companyID: company.id, resourceID: resource.id, date: Date(), steps: steps)
        reports[resource.id] = report; failed = report.hasProblem
        message = report.hasProblem ? "检查已完成，存在待处理项。" : "已完成本次路径检查；认证与业务功能仍需实际验证。"
    }
}

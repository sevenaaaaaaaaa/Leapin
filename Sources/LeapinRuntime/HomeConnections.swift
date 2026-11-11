import Foundation
import Combine
import LeapinCore
import LeapinNet
import LeapinIntegrations

public struct HomeConnection: Codable, Sendable, Equatable {
    public let selfID: String
    public let peerID: String
    public let peerName: String
    public let resource: URL
    public let address: String
    public let checkedAt: Date
    public var host: String { resource.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]")) ?? "" }
    public var port: UInt16 { UInt16(resource.port ?? (resource.scheme?.lowercased() == "smb" ? 445 : resource.scheme?.lowercased() == "https" ? 443 : 80)) }

    public init(snapshot: TailnetSnapshot, peer: TailnetPeer, resource: String, checkedAt: Date = Date()) throws {
        guard snapshot.state == "Running", snapshot.usesSystemTunnel, let selfID = snapshot.selfID, !selfID.isEmpty,
              snapshot.peers.contains(peer), peer.online, let address = peer.usableAddresses.first else {
            throw LeapinError.invalidConfiguration("请连接 Tailscale 并选择一台在线家庭设备")
        }
        guard let url = URL(string: resource.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https", "smb"].contains(scheme),
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]")),
              url.user == nil, url.password == nil,
              let port = UInt16(exactly: url.port ?? (scheme == "smb" ? 445 : scheme == "https" ? 443 : 80)), port > 0,
              peer.usableAddresses.map({ $0.lowercased() }).contains(host) || (!peer.normalizedDNSName.isEmpty && host == peer.normalizedDNSName) else {
            throw LeapinError.invalidConfiguration("资源需使用所选设备的 Tailscale IP 或完整 DNS 名，协议支持 http、https、smb，不能包含登录凭据")
        }
        self.selfID = selfID; peerID = peer.id; peerName = peer.displayName
        self.resource = url; self.address = peer.usableAddresses.first(where: { $0.lowercased() == host }) ?? address; self.checkedAt = checkedAt
    }
    private static func file(_ root: URL) -> URL { root.appendingPathComponent("home-connection.json") }
    public static func load(root: URL) throws -> HomeConnection? {
        let url = file(root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(HomeConnection.self, from: Data(contentsOf: url))
        guard TailnetAddress.isNodeAddress(value.address), !value.host.isEmpty,
              ["http", "https", "smb"].contains(value.resource.scheme?.lowercased() ?? ""),
              value.resource.user == nil, value.resource.password == nil,
              (1...65535).contains(value.resource.port ?? 80) else { throw LeapinError.invalidConfiguration("家庭资源配置无效，请重新设置") }
        return value
    }
    public static func save(_ value: HomeConnection?, root: URL) throws {
        let url = file(root)
        guard let value else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func routing(_ profile: Profile) -> Profile {
        var next = profile
        next.rules.insert(Rule(kind: .domain, value: host, policy: "DIRECT", raw: "DOMAIN,\(host),DIRECT"), at: 0)
        return next
    }
    public func dns(_ config: DNSConfig) -> DNSConfig {
        var next = config
        next.hosts[host] = address
        return next
    }
}

@MainActor
public final class HomeConnections: ObservableObject {
    @Published public private(set) var snapshot: TailnetSnapshot?
    @Published public private(set) var saved: HomeConnection?
    @Published public private(set) var busy = false
    @Published public private(set) var message: String?
    @Published public private(set) var failed = false
    @Published public private(set) var verifiedAt: Date?
    private let root: URL
    private let connector: any TailnetControlling
    private let probe: @Sendable (String, UInt16) async throws -> Void

    public init(root: URL, connector: any TailnetControlling = TailscaleConnector(),
                probe: @escaping @Sendable (String, UInt16) async throws -> Void = { address, port in
                    let socket = try await NetSocket.connect(host: address, port: port, timeout: 4)
                    socket.close()
                }) {
        self.root = root; self.connector = connector; self.probe = probe
        do { saved = try HomeConnection.load(root: root) }
        catch { message = "家庭资源配置无法读取，请重新设置"; failed = true }
    }
    public func refresh() async {
        guard !busy else { return }
        busy = true; verifiedAt = nil
        defer { busy = false }
        do { snapshot = try await connector.status(); message = snapshot?.statusText; failed = false }
        catch { fail(error) }
    }
    public func configure(peerID: String, resource: String, applyRouting: () throws -> Void = {}) async -> Bool {
        guard !busy else { return false }
        busy = true; failed = false; verifiedAt = nil
        defer { busy = false }
        do {
            let current = try await connector.status()
            snapshot = current
            guard let peer = current.peers.first(where: { $0.id == peerID }) else {
                throw LeapinError.invalidConfiguration("设备列表已变化，请刷新后重新选择")
            }
            let candidate = try HomeConnection(snapshot: current, peer: peer, resource: resource)
            try await verify(candidate)
            try persist(candidate, applyRouting: applyRouting)
            saved = candidate; verifiedAt = Date(); failed = false
            message = "设备与服务端口可达。打开后仍需由浏览器或访达确认登录。"
            return true
        } catch { fail(error); return false }
    }
    public func verifySaved(applyRouting: () throws -> Void = {}) async -> URL? {
        guard !busy, let saved else { return nil }
        busy = true; failed = false; verifiedAt = nil
        defer { busy = false }
        do {
            var current = try await connector.status()
            guard current.selfID == saved.selfID else { throw LeapinError.invalidConfiguration("Tailscale 账号或本机身份已变化，请重新绑定家庭设备") }
            if current.state == "Stopped" {
                message = "正在恢复 Tailscale 连接…"
                try await connector.reconnect()
                current = try await connector.status()
            }
            snapshot = current
            guard current.selfID == saved.selfID else { throw LeapinError.invalidConfiguration("连接后的设备身份已变化，请重新绑定") }
            guard let peer = current.peers.first(where: { $0.id == saved.peerID }) else {
                throw LeapinError.invalidConfiguration("当前网络找不到已绑定设备，请重新设置")
            }
            let candidate = try HomeConnection(snapshot: current, peer: peer, resource: saved.resource.absoluteString)
            message = "正在检查家庭设备和服务端口…"
            try await verify(candidate)
            try persist(candidate, applyRouting: applyRouting)
            self.saved = candidate; verifiedAt = Date()
            message = "设备与服务端口已验证；登录和页面功能由目标服务确认。"
            return candidate.resource
        } catch { fail(error); return nil }
    }
    public func forget(applyRouting: () throws -> Void = {}) throws {
        guard !busy else { throw LeapinError.invalidConfiguration("正在检查，请稍后操作") }
        try persist(nil, applyRouting: applyRouting)
        saved = nil; verifiedAt = nil; message = nil; failed = false
    }
    private func persist(_ candidate: HomeConnection?, applyRouting: () throws -> Void) throws {
        let previous = saved
        try HomeConnection.save(candidate, root: root)
        do { try applyRouting() }
        catch {
            try HomeConnection.save(previous, root: root)
            throw error
        }
    }
    private func verify(_ candidate: HomeConnection) async throws {
        _ = try await connector.ping(address: candidate.address)
        try await probe(candidate.address, candidate.port)
    }
    private func fail(_ error: Error) {
        failed = true; verifiedAt = nil; message = Redactor.redact(error.localizedDescription)
    }
}

import Foundation
import Darwin
import LeapinCore

public struct TailnetPeer: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let hostname: String
    public let dnsName: String
    public let addresses: [String]
    public let online: Bool
    enum CodingKeys: String, CodingKey {
        case id = "ID", hostname = "HostName", dnsName = "DNSName", addresses = "TailscaleIPs", online = "Online"
    }
    public init(id: String, hostname: String, dnsName: String = "", addresses: [String], online: Bool) {
        self.id = id; self.hostname = hostname; self.dnsName = dnsName; self.addresses = addresses; self.online = online
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? "设备"
        dnsName = try c.decodeIfPresent(String.self, forKey: .dnsName) ?? ""
        addresses = try c.decodeIfPresent([String].self, forKey: .addresses) ?? []
        online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? false
    }
    public var displayName: String { hostname.isEmpty ? String(dnsName.prefix(80)) : hostname }
    public var usableAddresses: [String] { addresses.filter(TailnetAddress.isNodeAddress) }
    public var normalizedDNSName: String { dnsName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
}

public enum TailnetAddress {
    public static func isNodeAddress(_ input: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, input, &v4) == 1 {
            let value = UInt32(bigEndian: v4.s_addr)
            return value & 0xffc00000 == 0x64400000 // Tailscale node IPv4 range.
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, input, &v6) == 1 else { return false }
        return withUnsafeBytes(of: v6) { bytes in
            Array(bytes.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
        }
    }
}

public struct TailnetSnapshot: Sendable, Equatable {
    public let state: String
    public let version: String
    public let selfID: String?
    public let usesSystemTunnel: Bool
    public let peers: [TailnetPeer]
    public init(state: String, version: String = "", selfID: String?, usesSystemTunnel: Bool = true, peers: [TailnetPeer]) {
        self.state = state; self.version = version; self.selfID = selfID
        self.usesSystemTunnel = usesSystemTunnel; self.peers = peers
    }
    public static func decode(_ data: Data) throws -> TailnetSnapshot {
        struct Payload: Decodable {
            let BackendState: String
            let Version: String?
            let TUN: Bool?
            let `Self`: TailnetPeer?
            let Peer: [String: TailnetPeer]?
        }
        let raw = try JSONDecoder().decode(Payload.self, from: data)
        return TailnetSnapshot(state: raw.BackendState, version: raw.Version ?? "", selfID: raw.Self?.id,
            usesSystemTunnel: raw.TUN ?? false,
            peers: (raw.Peer ?? [:]).values.filter { !$0.id.isEmpty && $0.id != raw.Self?.id }.sorted { $0.displayName < $1.displayName })
    }
    public var statusText: String {
        switch state {
        case "Running": return usesSystemTunnel ? "Tailscale 已连接" : "仅用户态运行，无法直接打开家庭资源"
        case "Stopped": return "Tailscale 已暂停"
        case "NeedsLogin": return "请先在 Tailscale 登录"
        case "NeedsMachineAuth": return "此设备等待网络管理员授权"
        case "Starting": return "Tailscale 正在连接"
        default: return "Tailscale 尚未就绪"
        }
    }
}

public protocol TailnetControlling: Sendable {
    func status() async throws -> TailnetSnapshot
    func reconnect() async throws
    func ping(address: String) async throws -> String
}

public struct TailscaleConnector: TailnetControlling, Sendable {
    private let executable: URL?
    public init(executable: URL? = nil) { self.executable = executable }
    public static func findExecutable() -> URL? {
        let paths: [String?] = [ProcessInfo.processInfo.environment["LEAPIN_TAILSCALE_PATH"],
            UserDefaults.standard.string(forKey: "leapin.tailscale.path"), "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        return paths.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    private func run(_ args: [String], timeout: TimeInterval = 8) async throws -> CommandOutput {
        guard let url = executable ?? Self.findExecutable() else {
            throw LeapinError.unsupported("未找到 Tailscale，请先安装或选择可执行文件")
        }
        return try await Task.detached {
            try CommandRunner.run(executable: url.path, arguments: args, timeout: timeout)
        }.value
    }
    public func status() async throws -> TailnetSnapshot {
        let result = try await run(["status", "--json"])
        guard !result.timedOut else { throw LeapinError.timeout }
        // Stopped/login states may be accompanied by a nonzero CLI exit status.
        if let data = result.stdout.data(using: .utf8), let snapshot = try? TailnetSnapshot.decode(data) { return snapshot }
        throw LeapinError.connectionFailed("无法读取 Tailscale 状态，请确认客户端正在运行且当前用户有访问权限")
    }
    public func reconnect() async throws {
        // No flags: documented to reconnect without resetting existing preferences.
        let result = try await run(["up"], timeout: 12)
        guard result.succeeded else {
            throw LeapinError.connectionFailed("Tailscale 未完成连接，请在客户端处理登录、授权或服务状态后重试")
        }
    }
    public func ping(address: String) async throws -> String {
        guard TailnetAddress.isNodeAddress(address) else { throw LeapinError.invalidConfiguration("设备没有有效的 Tailscale 地址") }
        let result = try await run(["ping", "--c", "1", "--timeout", "3s", "--until-direct=false", address], timeout: 5)
        guard result.succeeded else {
            throw LeapinError.connectionFailed("家庭设备未响应 Tailscale 检查，请确认设备在线及访问权限")
        }
        // Ping success is evidence of the overlay path, not of service/ACL usability.
        return Redactor.redact(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).prefix(1000).description
    }
}

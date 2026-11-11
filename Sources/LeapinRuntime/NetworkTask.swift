import Foundation
import LeapinCore

/// A deliberately bounded local task vocabulary. Unsupported requests never
/// turn into configuration changes; an LLM can later produce the same typed plans.
public enum NetworkTask: Equatable, Sendable {
    case connect, inspect(SiteTarget), direct(SiteTarget)
    case privacy, importProfile, home, company, shareService, toolCredits, nas, ssh, learn, unsupported

    public static func parse(_ input: String) -> NetworkTask {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch text.lowercased() {
        case "连接网络", "开始连接", "connect": return .connect
        case "减少广告和跟踪", "隐私保护": return .privacy
        case "导入订阅", "导入配置": return .importProfile
        case "公司内网", "访问公司内网", "公司资源": return .company
        case "分享本地服务", "限时分享本地服务": return .shareService
        case "工具与致谢", "开源作者": return .toolCredits
        case "回家", "tailscale 回家", "打开家庭资源": return .home
        case "访问家里的文件", "连接 nas", "nas": return .nas
        case "连接服务器", "ssh": return .ssh
        case "为 app 安排网络", "智能学习": return .learn
        default: break
        }
        if text.hasPrefix("让"), text.hasSuffix("直连") {
            let value = String(text.dropFirst().dropLast(2)).trimmingCharacters(in: .whitespaces)
            return SiteTarget(value).map(NetworkTask.direct) ?? .unsupported
        }
        let value = text.hasPrefix("诊断 ") ? String(text.dropFirst(3)) : text
        return SiteTarget(value).map(NetworkTask.inspect) ?? .unsupported
    }
}

public struct SiteTarget: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    /// Probe only the origin. Pasted paths, fragments and query tokens are discarded.
    public let origin: String

    public init?(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }),
              !text.contains("\\"), !text.contains("@") else { return nil }
        let absolute = text.contains("://") ? text : "https://" + text
        guard var parts = URLComponents(string: absolute),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              parts.user == nil, parts.password == nil,
              let rawHost = parts.url?.host?.lowercased(), !rawHost.isEmpty,
              let port = UInt16(exactly: parts.port ?? (scheme == "https" ? 443 : 80)), port > 0 else { return nil }
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        // Accept DNS names / IPv4 / localhost. IPv6 is available in the advanced tools.
        guard host == "localhost" || (host.contains(".") && host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-"
                && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }), host.count <= 253 else { return nil }
        parts.host = host
        parts.path = "/"
        parts.query = nil
        parts.fragment = nil
        guard let origin = parts.url?.absoluteString else { return nil }
        self.host = host
        self.port = port
        self.origin = origin
    }
}

/// Scope-safe undo: unrelated settings are preserved; intervening rule edits
/// require a fresh preview instead of silently replacing the user's work.
public struct NetworkRuleChange: Sendable {
    public let profileID: UUID
    public let before: [Rule]
    public let after: [Rule]

    public init(profile: Profile, target: SiteTarget) {
        profileID = profile.id
        before = profile.rules
        let rule = Rule(kind: .domain, value: target.host, policy: "DIRECT",
                        raw: "DOMAIN,\(target.host),DIRECT")
        after = [rule] + before.filter { $0 != rule }
    }

    public func canUndo(in profile: Profile) -> Bool {
        profile.id == profileID && profile.rules == after
    }
}

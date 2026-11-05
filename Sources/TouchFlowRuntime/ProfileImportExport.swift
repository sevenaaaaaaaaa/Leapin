import Foundation
import TouchFlowCore
import TouchFlowPolicy

public enum ProfileImportError: Error, LocalizedError {
    case unrecognized(String)
    case missingSection(String)
    public var errorDescription: String? {
        switch self {
        case .unrecognized(let s): return "无法识别的配置：\(s)"
        case .missingSection(let s): return "缺少配置段：\(s)"
        }
    }
}

public enum ProfileImporter {
    // MARK: - Clash

    public static func clash(_ text: String, name: String) throws -> Profile {
        let root = try MiniYAML.parse(text)
        guard root.map != nil else { throw ProfileImportError.unrecognized("Clash YAML 顶层不是映射") }
        var profile = ProfileDefaults.make()
        profile.name = name
        profile.sourcePath = nil

        if let mixed = root["mixed-port"]?.int { profile.general.mixedPort = UInt16(clamping: mixed) }
        if let http = root["port"]?.int { profile.general.httpPort = UInt16(clamping: http) }
        if let socks = root["socks-port"]?.int { profile.general.socksPort = UInt16(clamping: socks) }
        if let lan = root["allow-lan"]?.bool { profile.general.allowLAN = lan }
        if let level = root["log-level"]?.string, let l = LogLevel(rawValue: level) { profile.general.logLevel = l }

        if let dns = root["dns"]?.map {
            var cfg = profile.dns
            if let servers = dns["nameserver"]?.stringArray, !servers.isEmpty { cfg.upstreams = servers }
            if let fallback = dns["fallback"]?.stringArray { cfg.fallback = fallback }
            if let hosts = dns["hosts"]?.map {
                cfg.hosts = hosts.compactMapValues { $0.string ?? $0.array?.first?.string }
            }
            if let listen = dns["listen"]?.string {
                let parts = listen.split(separator: ":")
                if let port = parts.last.flatMap({ UInt16($0) }) { cfg.listenPort = port }
            }
            if dns["enhanced-mode"]?.string?.lowercased() == "fake-ip" {
                cfg.mode = .fakeIP
                if let range = dns["fake-ip-range"]?.string { cfg.fakeIPRange = range }
            } else if cfg.upstreams.contains(where: { $0.hasPrefix("https://") }) {
                cfg.mode = .doh
            }
            profile.dns = cfg
        }

        var outbounds: [OutboundConfig] = [.direct, .reject]
        for item in root["proxies"]?.array ?? [] {
            guard let m = item.map, let nm = m["name"]?.string, let typeRaw = m["type"]?.string else { continue }
            guard let type = mapOutboundType(typeRaw) else { continue }
            let host = m["server"]?.string ?? ""
            let port = UInt16(clamping: m["port"]?.int ?? 0)
            outbounds.append(OutboundConfig(
                name: nm, type: type, host: host, port: port,
                username: m["username"]?.string ?? m["user"]?.string,
                password: m["password"]?.string,
                cipher: m["cipher"]?.string,
                tls: (m["tls"]?.bool ?? false) || (m["sni"]?.string != nil),
                sni: m["sni"]?.string ?? m["servername"]?.string,
                extra: ["udp": m["udp"]?.string ?? "false"]
            ))
        }
        profile.outbounds = outbounds

        var groups: [PolicyGroup] = []
        for item in root["proxy-groups"]?.array ?? [] {
            guard let m = item.map, let nm = m["name"]?.string, let typeRaw = m["type"]?.string else { continue }
            let type = PolicyGroupType(rawValue: typeRaw.lowercased()) ?? .select
            let members = (m["proxies"]?.array ?? []).compactMap { $0.string }
            groups.append(PolicyGroup(name: nm, type: type, proxies: members,
                                      url: m["url"]?.string,
                                      interval: m["interval"]?.int,
                                      tolerance: m["tolerance"]?.int))
        }
        profile.groups = groups

        var rules: [Rule] = []
        for item in root["rules"]?.array ?? [] {
            guard let line = item.string else { continue }
            let (parsed, errors) = RuleParser.parseRules(line)
            if !errors.isEmpty { TFLog.shared.warn("import", "Clash 规则解析失败: \(line) — \(errors.joined(separator: "; "))") }
            rules.append(contentsOf: parsed)
        }
        profile.rules = rules
        if profile.rules.isEmpty {
            profile.rules = ProfileDefaults.baseRules
        }
        return profile
    }

    private static func mapOutboundType(_ raw: String) -> OutboundType? {
        switch raw.lowercased() {
        case "ss", "shadowsocks": return .shadowsocks
        case "trojan": return .trojan
        case "http", "https": return .http
        case "socks5", "socks": return .socks5
        case "direct": return .direct
        case "reject": return .reject
        default: return nil
        }
    }

    // MARK: - Surge

    public static func surge(_ text: String, name: String) throws -> Profile {
        var profile = ProfileDefaults.make()
        profile.name = name
        var section = ""
        var outbounds: [OutboundConfig] = [.direct, .reject]
        var groups: [PolicyGroup] = []
        var rules: [Rule] = []
        var generalLines: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = line.dropFirst().dropLast().lowercased()
                continue
            }
            switch section {
            case "general":
                generalLines.append(line)
            case "proxy":
                if let ob = parseSurgeProxy(line) { outbounds.append(ob) }
            case "proxy group":
                if let g = parseSurgeGroup(line) { groups.append(g) }
            case "rule":
                let (parsed, errors) = RuleParser.parseRules(line)
                if !errors.isEmpty { TFLog.shared.warn("import", "Surge 规则解析失败: \(line) — \(errors.joined(separator: "; "))") }
                rules.append(contentsOf: parsed)
            default:
                break
            }
        }

        for line in generalLines {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "loglevel", "log-level":
                if let l = LogLevel(rawValue: parts[1].lowercased()) { profile.general.logLevel = l }
            case "http-listen", "mixed-listen":
                if let port = UInt16(parts[1].split(separator: ":").last ?? "") { profile.general.mixedPort = port }
            case "socks5-listen":
                if let port = UInt16(parts[1].split(separator: ":").last ?? "") { profile.general.socksPort = port }
            case "allow-lan", "allow-hotspot-access":
                profile.general.allowLAN = (parts[1].lowercased() == "true")
            default: break
            }
        }

        profile.outbounds = outbounds
        profile.groups = groups
        profile.rules = rules.isEmpty ? ProfileDefaults.baseRules : rules
        return profile
    }

    /// `Name = http, host, port, user, pass` / `Name = ss, host, port, encrypt-method=..., password=...`
    private static func parseSurgeProxy(_ line: String) -> OutboundConfig? {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        let name = parts[0]
        let fields = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 3 else { return nil }
        let typeRaw = fields[0].lowercased()
        guard let type = mapOutboundType(typeRaw) else { return nil }
        guard let port = UInt16(fields[2]) else { return nil }
        var username: String?
        var password: String?
        var cipher: String?
        var tls = false
        var sni: String?

        // Positional forms first (http/socks5: host,port,user,pass), then k=v overrides.
        if type == .http || type == .socks5 {
            if fields.count >= 5, !fields[3].contains("=") {
                username = fields[3]; password = fields[4]
            }
        }
        for field in fields.dropFirst(3) {
            let kv = field.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            switch kv[0].lowercased() {
            case "username", "user": username = kv[1]
            case "password", "pass": password = kv[1]
            case "encrypt-method", "cipher": cipher = kv[1]
            case "sni": sni = kv[1]; tls = true
            case "tls": tls = (kv[1].lowercased() == "true")
            case "skip-cert-verify": break
            default: break
            }
        }
        return OutboundConfig(name: name, type: type, host: fields[1], port: port,
                              username: username, password: password, cipher: cipher,
                              tls: tls, sni: sni)
    }

    private static func parseSurgeGroup(_ line: String) -> PolicyGroup? {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        let fields = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = fields.first else { return nil }
        let type: PolicyGroupType
        var members: [String]
        switch first.lowercased() {
        case "select": type = .select; members = Array(fields.dropFirst())
        case "url-test": type = .urlTest; members = Array(fields.dropFirst())
        case "fallback": type = .fallback; members = Array(fields.dropFirst())
        case "load-balance": type = .loadBalance; members = Array(fields.dropFirst())
        default: return nil
        }
        members = members.filter { !$0.contains("=") }
        return PolicyGroup(name: parts[0], type: type, proxies: members)
    }
}

public enum ProfileExporter {
    public static func clash(_ profile: Profile) -> String {
        var out: [String] = []
        out.append("# Generated by TouchFlow")
        out.append("mixed-port: \(profile.general.mixedPort)")
        out.append("port: \(profile.general.httpPort)")
        out.append("socks-port: \(profile.general.socksPort)")
        out.append("allow-lan: \(profile.general.allowLAN)")
        out.append("mode: rule")
        out.append("log-level: \(profile.general.logLevel.rawValue)")
        out.append("")
        out.append("dns:")
        out.append("  enable: true")
        out.append("  listen: 127.0.0.1:\(profile.dns.listenPort)")
        out.append("  enhanced-mode: \(profile.dns.mode == .fakeIP ? "fake-ip" : "redir-host")")
        out.append("  fake-ip-range: \(profile.dns.fakeIPRange)")
        out.append("  nameserver:")
        for s in profile.dns.upstreams { out.append("    - \(quote(s))") }
        if !profile.dns.fallback.isEmpty {
            out.append("  fallback:")
            for s in profile.dns.fallback { out.append("    - \(quote(s))") }
        }
        out.append("")
        out.append("proxies:")
        for ob in profile.outbounds where ob.type != .direct && ob.type != .reject {
            out.append("  - name: \(quote(ob.name))")
            out.append("    type: \(clashType(ob.type))")
            out.append("    server: \(ob.host)")
            out.append("    port: \(ob.port)")
            if let cipher = ob.cipher { out.append("    cipher: \(cipher)") }
            if let password = ob.password { out.append("    password: \(quote(password))") }
            if let username = ob.username { out.append("    username: \(quote(username))") }
            if ob.tls { out.append("    tls: true") }
            if let sni = ob.sni { out.append("    sni: \(sni)") }
        }
        out.append("")
        out.append("proxy-groups:")
        for g in profile.groups {
            out.append("  - name: \(quote(g.name))")
            out.append("    type: \(g.type.rawValue)")
            out.append("    proxies:")
            for p in g.proxies { out.append("      - \(quote(p))") }
            if let url = g.url { out.append("    url: \(quote(url))") }
            if let interval = g.interval { out.append("    interval: \(interval)") }
        }
        out.append("")
        out.append("rules:")
        for line in RuleParser.exportClash(profile.rules).components(separatedBy: .newlines) where !line.isEmpty {
            out.append("  - \(line)")
        }
        return out.joined(separator: "\n") + "\n"
    }

    public static func surge(_ profile: Profile) -> String {
        var out: [String] = []
        out.append("#!MANAGED-CONFIG")
        out.append("# Generated by TouchFlow")
        out.append("[General]")
        out.append("loglevel = \(profile.general.logLevel.rawValue)")
        out.append("http-listen = 127.0.0.1:\(profile.general.httpPort)")
        out.append("socks5-listen = 127.0.0.1:\(profile.general.socksPort)")
        out.append("allow-lan = \(profile.general.allowLAN)")
        out.append("")
        out.append("[Proxy]")
        for ob in profile.outbounds where ob.type != .direct && ob.type != .reject {
            var fields: [String] = [surgeType(ob.type), ob.host, String(ob.port)]
            if ob.type == .http || ob.type == .socks5, let u = ob.username, let p = ob.password {
                fields.append(u); fields.append(p)
            }
            if let cipher = ob.cipher { fields.append("encrypt-method=\(cipher)") }
            if let password = ob.password { fields.append("password=\(password)") }
            if ob.tls { fields.append("tls=true") }
            if let sni = ob.sni { fields.append("sni=\(sni)") }
            out.append("\(ob.name) = \(fields.joined(separator: ", "))")
        }
        out.append("")
        out.append("[Proxy Group]")
        for g in profile.groups {
            out.append("\(g.name) = \(g.type.rawValue), \(g.proxies.joined(separator: ", "))")
        }
        out.append("")
        out.append("[Rule]")
        out.append(contentsOf: RuleParser.exportSurge(profile.rules).components(separatedBy: .newlines).filter { !$0.isEmpty })
        return out.joined(separator: "\n") + "\n"
    }

    private static func quote(_ s: String) -> String {
        if s.contains(":") || s.contains("#") || s.contains(",") || s.hasPrefix(" ") || s.hasSuffix(" ") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return s
    }
    private static func clashType(_ t: OutboundType) -> String {
        switch t { case .shadowsocks: return "ss"; case .trojan: return "trojan"
        case .http: return "http"; case .socks5: return "socks5"; default: return "direct" }
    }
    private static func surgeType(_ t: OutboundType) -> String {
        switch t { case .shadowsocks: return "ss"; case .trojan: return "trojan"
        case .http: return "http"; case .socks5: return "socks5"; default: return "direct" }
    }
}

public enum ProfileDefaults {
    public static let baseRules: [Rule] = [
        Rule(kind: .ipCIDR, value: "127.0.0.0/8", policy: "DIRECT"),
        Rule(kind: .ipCIDR, value: "10.0.0.0/8", policy: "DIRECT"),
        Rule(kind: .ipCIDR, value: "172.16.0.0/12", policy: "DIRECT"),
        Rule(kind: .ipCIDR, value: "192.168.0.0/16", policy: "DIRECT"),
        Rule(kind: .domainSuffix, value: "local", policy: "DIRECT"),
        Rule(kind: .domainSuffix, value: "lan", policy: "DIRECT"),
        Rule(kind: .processName, value: "ssh", policy: "DIRECT"),
        Rule(kind: .geoIP, value: "CN", policy: "DIRECT"),
        Rule(kind: .match, value: "", policy: "PROXY"),
    ]

    public static func make() -> Profile {
        Profile(
            name: "默认配置",
            general: GeneralConfig(),
            dns: DNSConfig(),
            adblock: AdBlockConfig(),
            outbounds: [
                .direct, .reject,
                OutboundConfig(name: "示例-上游", type: .http, host: "127.0.0.1", port: 1087),
            ],
            groups: [
                PolicyGroup(name: "PROXY", type: .select, proxies: ["DIRECT", "示例-上游"], selected: "DIRECT"),
                PolicyGroup(name: "AUTO", type: .urlTest, proxies: ["DIRECT", "示例-上游"], url: "http://www.gstatic.com/generate_204", interval: 300),
            ],
            rules: baseRules
        )
    }
}

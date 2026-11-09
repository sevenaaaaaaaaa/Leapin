import Foundation
import LeapinCore

// MARK: - Import diagnostics

/// One concrete problem found while importing a profile. The line number is
/// 1-based and references the source file when known.
public struct ImportIssue: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case unknownProtocol
        case unknownGroupType
        case unsupportedSection
        case unsupportedField
        case skippedItem
        case parseError
        case ruleError
        case duplicateName

        public var isBlocking: Bool {
            switch self {
            case .parseError: return true
            case .unknownProtocol, .unknownGroupType, .unsupportedSection,
                 .unsupportedField, .skippedItem, .ruleError, .duplicateName: return false
            }
        }
    }

    public var id: String { "\(kind.rawValue)|\(line ?? 0)|\(item)|\(message)" }
    public var kind: Kind
    public var line: Int?
    /// Failing construct: proxy name, rule text, section name, ...
    public var item: String
    public var message: String

    public init(kind: Kind, line: Int? = nil, item: String = "", message: String) {
        self.kind = kind
        self.line = line
        self.item = item
        self.message = message
    }

    public var display: String {
        var parts: [String] = []
        if let line { parts.append("第 \(line) 行") }
        if !item.isEmpty { parts.append(item) }
        parts.append(message)
        return parts.joined(separator: "：")
    }
}

/// What an import actually produced. The UI should surface issues instead of
/// pretending every field was understood.
public struct ImportReport: Sendable, Hashable, Codable {
    public var format: String
    public var outboundCount: Int
    public var groupCount: Int
    public var ruleCount: Int
    public var skippedOutbounds: Int
    public var issues: [ImportIssue]
    /// Outbounds that imported fine but whose protocol this build cannot dial yet.
    /// Kept separate from `issues` so the UI can say "these nodes will fail" up front
    /// instead of letting the user discover it on the first connection.
    public var notDialable: [String]

    public init(format: String, outboundCount: Int = 0, groupCount: Int = 0,
                ruleCount: Int = 0, skippedOutbounds: Int = 0, issues: [ImportIssue] = [],
                notDialable: [String] = []) {
        self.format = format
        self.outboundCount = outboundCount
        self.groupCount = groupCount
        self.ruleCount = ruleCount
        self.skippedOutbounds = skippedOutbounds
        self.issues = issues
        self.notDialable = notDialable
    }

    /// Fills `notDialable` from the imported profile and records one aggregated
    /// issue per protocol, so the report is honest about what will not work.
    public mutating func annotateDialability(of profile: Profile) {
        notDialable = profile.outbounds.filter { !$0.type.isDialable }.map { $0.name }
        var seen = Set<String>()
        for outbound in profile.outbounds where !outbound.type.isDialable {
            let token = (outbound.rawType ?? outbound.type.rawValue).lowercased()
            guard seen.insert(token).inserted else { continue }
            let affected = profile.outbounds.filter {
                !$0.type.isDialable && ($0.rawType ?? $0.type.rawValue).lowercased() == token
            }.count
            issues.append(ImportIssue(
                kind: .unknownProtocol,
                item: token,
                message: "协议 \(token) 已保留但暂不可拨号（\(affected) 个出站）；选用它的规则会在连接时失败"))
        }
    }

    public var isClean: Bool { issues.isEmpty }

    /// Protocol tokens that were preserved as unsupported outbounds.
    public var unknownProtocols: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for issue in issues where issue.kind == .unknownProtocol {
            if seen.insert(issue.item).inserted { result.append(issue.item) }
        }
        return result
    }

    public var summary: String {
        var text = "\(format)：\(outboundCount) 个出站 / \(groupCount) 个策略组 / \(ruleCount) 条规则"
        if skippedOutbounds > 0 { text += "，跳过 \(skippedOutbounds) 项" }
        if !notDialable.isEmpty { text += "，\(notDialable.count) 个出站暂不可拨号" }
        if !issues.isEmpty { text += "，\(issues.count) 条提示" }
        return text
    }

    public mutating func add(_ issue: ImportIssue) {
        issues.append(issue)
    }
}

public struct ProfileImportOutcome: Sendable {
    public var profile: Profile
    public var report: ImportReport

    public init(profile: Profile, report: ImportReport) {
        self.profile = profile
        self.report = report
    }
}

// MARK: - Format detection

public enum ProfileFormatKind: String, Sendable {
    case clash
    case surge
    case json
    case subscription
    case unknown
}

public enum ProfileFormatDetector {
    public static func detect(text: String, pathExtension: String? = nil) -> ProfileFormatKind {
        let ext = pathExtension?.lowercased()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ext == "json" || trimmed.hasPrefix("{") { return .json }
        if looksLikeSurge(text) { return .surge }
        if looksLikeClash(text) { return .clash }
        if SubscriptionImporter.looksLikeSubscription(text) { return .subscription }
        if ext == "yaml" || ext == "yml" { return .clash }
        return .unknown
    }

    static func looksLikeSurge(_ text: String) -> Bool {
        let sections = ["[general]", "[proxy]", "[proxy group]", "[rule]", "[host]"]
        for rawLine in text.components(separatedBy: .newlines).prefix(400) {
            let line = rawLine.trimmingCharacters(in: .whitespaces).lowercased()
            if sections.contains(line) { return true }
        }
        return false
    }

    static func looksLikeClash(_ text: String) -> Bool {
        let keys = ["proxies:", "proxy-groups:", "rules:", "mixed-port:", "socks-port:",
                    "rule-providers:", "proxy-providers:"]
        for rawLine in text.components(separatedBy: .newlines).prefix(400) {
            let line = rawLine.trimmingCharacters(in: .whitespaces).lowercased()
            if keys.contains(where: { line.hasPrefix($0) }) { return true }
        }
        return false
    }
}

// MARK: - Importer

public enum ProfileImporter {
    /// Detects the format and imports. The path extension is only a hint.
    public static func importText(_ text: String, name: String,
                                  pathExtension: String? = nil) throws -> ProfileImportOutcome {
        switch ProfileFormatDetector.detect(text: text, pathExtension: pathExtension) {
        case .json:
            return try json(Data(text.utf8), name: name)
        case .surge:
            return try surge(text, name: name)
        case .clash:
            return try clash(text, name: name)
        case .subscription:
            return try subscription(text, name: name)
        case .unknown:
            // A YAML-looking document still goes through the Clash parser so the
            // caller gets a precise parse error instead of silence.
            if text.contains(":") { return try clash(text, name: name) }
            throw ProfileImportError.unrecognized("无法识别的配置格式")
        }
    }

    public static func json(_ data: Data, name: String) throws -> ProfileImportOutcome {
        var profile = try JSONDecoder().decode(Profile.self, from: data)
        if !name.isEmpty { profile.name = name }
        var report = ImportReport(format: "Leapin JSON",
                                  outboundCount: profile.outbounds.count,
                                  groupCount: profile.groups.count,
                                  ruleCount: profile.rules.count)
        report.annotateDialability(of: profile)
        return ProfileImportOutcome(profile: profile, report: report)
    }

    // MARK: Clash

    public static func clash(_ text: String, name: String) throws -> ProfileImportOutcome {
        let root = try MiniYAML.parse(text)
        guard root.map != nil else { throw ProfileImportError.unrecognized("Clash YAML 顶层不是映射") }
        var profile = ProfileDefaults.make()
        profile.name = name
        profile.sourcePath = nil
        var report = ImportReport(format: "Clash YAML")

        let mixed = root["mixed-port"]?.int
        let http = root["port"]?.int
        if let mixed { profile.general.mixedPort = UInt16(clamping: mixed) }
        if let http {
            profile.general.httpPort = UInt16(clamping: http)
            // Many real configs publish a single port and no mixed-port.
            if mixed == nil { profile.general.mixedPort = UInt16(clamping: http) }
        }
        if let socks = root["socks-port"]?.int { profile.general.socksPort = UInt16(clamping: socks) }
        if let lan = root["allow-lan"]?.bool { profile.general.allowLAN = lan }
        // Leapin extension: local control plane. Unknown to Clash proper.
        if let controlPort = root["control-port"]?.int, (0...65535).contains(controlPort) {
            profile.general.controlPort = UInt16(controlPort)
        }
        if let controlLAN = root["control-allow-lan"]?.bool { profile.general.controlAllowLAN = controlLAN }
        if let level = root["log-level"]?.string, let l = LogLevel(rawValue: level) { profile.general.logLevel = l }
        if let mode = root["mode"]?.string, mode.lowercased() != "rule" {
            report.add(ImportIssue(kind: .unsupportedField, item: "mode",
                                   message: "仅支持 rule 模式，已按 rule 导入"))
        }

        profile.dns = clashDNS(root["dns"]?.map, base: profile.dns, report: &report)
        profile.outbounds = clashOutbounds(root["proxies"]?.array ?? [], report: &report)
        profile.groups = clashGroups(root["proxy-groups"]?.array ?? [], report: &report)
        profile.rules = clashRules(root["rules"]?.array ?? [], report: &report)
        profile.ruleProviders = clashProviders(root["rule-providers"]?.map ?? [:],
                                               label: "rule-providers", report: &report)
        profile.proxyProviders = clashProviders(root["proxy-providers"]?.map ?? [:],
                                                label: "proxy-providers", report: &report)

        report.outboundCount = profile.outbounds.count
        report.groupCount = profile.groups.count
        report.ruleCount = profile.rules.count
        report.annotateDialability(of: profile)
        return ProfileImportOutcome(profile: profile, report: report)
    }

    static func clashDNS(_ dns: [String: YAMLValue]?, base: DNSConfig,
                         report: inout ImportReport) -> DNSConfig {
        guard let dns else { return base }
        var cfg = base
        if let servers = dns["nameserver"]?.stringArray, !servers.isEmpty { cfg.upstreams = servers }
        if let fallback = dns["fallback"]?.stringArray { cfg.fallback = fallback }
        if let hosts = dns["hosts"]?.map {
            var parsed: [String: String] = [:]
            for (host, value) in hosts {
                let ips = value.stringArray ?? []
                guard let first = ips.first else { continue }
                parsed[host] = first
                if ips.count > 1 {
                    report.add(ImportIssue(kind: .unsupportedField, item: "dns.hosts.\(host)",
                                           message: "只保留第一个地址 \(first)，其余 \(ips.count - 1) 个未导入"))
                }
            }
            cfg.hosts = parsed
        }
        if let listen = dns["listen"]?.string {
            let parts = listen.split(separator: ":")
            if let port = parts.last.flatMap({ UInt16($0) }) { cfg.listenPort = port }
        }
        if let policy = dns["nameserver-policy"]?.map {
            var parsed: [String: [String]] = [:]
            for (key, value) in policy {
                let servers = value.stringArray ?? []
                if !servers.isEmpty { parsed[key] = servers }
            }
            cfg.nameserverPolicy = parsed
        }
        if let filter = dns["fake-ip-filter"]?.stringArray { cfg.fakeIPFilter = filter }
        let enhanced = dns["enhanced-mode"]?.string?.lowercased()
        if enhanced == "fake-ip" {
            cfg.mode = .fakeIP
            if let range = dns["fake-ip-range"]?.string { cfg.fakeIPRange = range }
        } else {
            cfg.mode = inferredDNSMode(upstreams: cfg.upstreams)
        }
        return cfg
    }

    static func inferredDNSMode(upstreams: [String]) -> DNSMode {
        if upstreams.contains(where: { $0.hasPrefix("https://") }) { return .doh }
        if upstreams.contains(where: { $0.hasPrefix("tls://") }) { return .dot }
        return .system
    }

    static func clashOutbounds(_ items: [YAMLValue], report: inout ImportReport) -> [OutboundConfig] {
        var outbounds: [OutboundConfig] = [.direct, .reject]
        var line = 0
        for item in items {
            line += 1
            guard let m = item.map else { continue }
            guard let name = m["name"]?.string, !name.isEmpty else {
                report.skippedOutbounds += 1
                report.add(ImportIssue(kind: .skippedItem, item: "#\(line)", message: "代理缺少 name，已跳过"))
                continue
            }
            guard let typeRaw = m["type"]?.string else {
                report.skippedOutbounds += 1
                report.add(ImportIssue(kind: .skippedItem, item: name, message: "代理缺少 type，已跳过"))
                continue
            }
            outbounds.append(clashOutbound(name: name, typeRaw: typeRaw, map: m, report: &report))
        }
        return outbounds
    }

    static func clashOutbound(name: String, typeRaw: String, map m: [String: YAMLValue],
                              report: inout ImportReport) -> OutboundConfig {
        let type = outboundType(typeRaw)
        if type == nil {
            report.add(ImportIssue(kind: .unknownProtocol, item: typeRaw,
                                   message: "协议 \(typeRaw) 暂不支持拨号，已原样保留（\(name)）"))
        }
        var ob = OutboundConfig(name: name, type: type ?? .unsupported,
                                host: m["server"]?.string ?? "",
                                port: UInt16(clamping: m["port"]?.int ?? 0),
                                rawType: typeRaw)
        ob.tls = m["tls"]?.bool ?? false
        ob.sni = m["sni"]?.string ?? m["servername"]?.string
        ob.username = m["username"]?.string ?? m["user"]?.string
        ob.password = m["password"]?.string
        ob.cipher = m["cipher"]?.string
        ob.uuid = m["uuid"]?.string
        ob.alterId = m["alterId"]?.int ?? m["alter-id"]?.int
        ob.flow = m["flow"]?.string
        ob.network = m["network"]?.string
        ob.security = m["security"]?.string
        ob.skipCertVerify = m["skip-cert-verify"]?.bool
        ob.udp = m["udp"]?.bool
        ob.alpn = m["alpn"]?.stringArray
        ob.obfs = m["obfs"]?.string
        ob.obfsPassword = m["obfs-password"]?.string
        ob.plugin = m["plugin"]?.string
        if let ws = m["ws-opts"]?.map {
            ob.wsPath = ws["path"]?.string
            ob.wsHost = ws["headers"]?["Host"]?.string ?? ws["headers"]?["host"]?.string
        }
        if let grpc = m["grpc-opts"]?.map {
            ob.grpcServiceName = grpc["grpc-service-name"]?.string
        }
        if let reality = m["reality-opts"]?.map {
            ob.publicKey = reality["public-key"]?.string
            ob.shortID = reality["short-id"]?.string
            if ob.security == nil { ob.security = "reality" }
        }
        if let pluginOpts = m["plugin-opts"]?.map {
            ob.pluginOpts = pluginOpts.keys.sorted().map { "\($0)=\(pluginOpts[$0]?.string ?? "")" }
                .joined(separator: ";")
        }
        for (key, value) in m where !clashConsumedKeys.contains(key) {
            if let scalar = value.string ?? value.int.map(String.init) ?? value.bool.map(String.init) {
                ob.extra[key] = scalar
            }
        }
        return ob
    }

    static let clashConsumedKeys: Set<String> = [
        "name", "type", "server", "port", "username", "user", "password", "cipher",
        "uuid", "alterId", "alter-id", "flow", "network", "tls", "sni", "servername",
        "security", "skip-cert-verify", "udp", "alpn", "obfs", "obfs-password",
        "plugin", "plugin-opts", "ws-opts", "grpc-opts", "reality-opts",
    ]

    static func clashGroups(_ items: [YAMLValue], report: inout ImportReport) -> [PolicyGroup] {
        var groups: [PolicyGroup] = []
        for item in items {
            guard let m = item.map, let name = m["name"]?.string, !name.isEmpty else { continue }
            let typeRaw = m["type"]?.string ?? "select"
            let mappedType = PolicyGroupType(rawValue: typeRaw.lowercased())
            if mappedType == nil {
                report.add(ImportIssue(kind: .unknownGroupType, item: typeRaw,
                                       message: "策略组 \(name) 的类型 \(typeRaw) 未建模，运行时按 select 处理，导出时保留原类型"))
            }
            let rawMembers = (m["proxies"]?.array ?? []).compactMap { $0.string }
            let use = (m["use"]?.array ?? []).compactMap { $0.string }
            let filter = m["filter"]?.string
            let excludeFilter = m["exclude-filter"]?.string
            let includeAll = m["include-all"]?.bool ?? m["include-all-proxies"]?.bool
                ?? m["include-all-providers"]?.bool ?? false
            if rawMembers.isEmpty && !use.isEmpty {
                report.add(ImportIssue(kind: .unsupportedField, item: name,
                                       message: "策略组成员来自 proxy-provider \(use.joined(separator: ", "))，未展开"))
            }
            var seen = Set<String>()
            let members = rawMembers.filter { seen.insert($0).inserted }
            groups.append(PolicyGroup(name: name, type: mappedType ?? .select, proxies: members,
                                      url: m["url"]?.string,
                                      interval: m["interval"]?.int,
                                      tolerance: m["tolerance"]?.int,
                                      rawType: mappedType == nil ? typeRaw : nil,
                                      use: use, filter: filter,
                                      excludeFilter: excludeFilter, includeAll: includeAll))
        }
        return groups
    }

    static func clashRules(_ items: [YAMLValue], report: inout ImportReport) -> [Rule] {
        var rules: [Rule] = []
        for (index, item) in items.enumerated() {
            guard let line = item.string, !line.isEmpty else { continue }
            let (parsed, errors) = RuleParser.parseRules(line)
            for error in errors {
                report.add(ImportIssue(kind: .ruleError, line: index + 1, item: line, message: error))
            }
            rules.append(contentsOf: parsed)
        }
        return rules
    }

    static func clashProviders(_ providers: [String: YAMLValue], label: String,
                               report: inout ImportReport) -> [RuleProvider] {
        var result: [RuleProvider] = []
        for (name, value) in providers.sorted(by: { $0.key < $1.key }) {
            guard let m = value.map else {
                report.add(ImportIssue(kind: .skippedItem, item: name, message: "\(label) 项不是映射，已跳过"))
                continue
            }
            let type = m["type"]?.string ?? "http"
            let behavior = m["behavior"]?.string ?? "classical"
            let payload = (m["payload"]?.array ?? []).compactMap { $0.string }
            var extra: [String: String] = [:]
            let consumed: Set<String> = ["type", "behavior", "url", "path", "interval", "format", "payload"]
            for (key, value) in m where !consumed.contains(key) {
                if let scalar = value.string ?? value.int.map(String.init) ?? value.bool.map(String.init) {
                    extra[key] = scalar
                }
            }
            result.append(RuleProvider(name: name, type: type, behavior: behavior,
                                       url: m["url"]?.string, path: m["path"]?.string,
                                       interval: m["interval"]?.int, format: m["format"]?.string,
                                       payload: payload, extra: extra))
        }
        return result
    }

    // MARK: Surge

    public static func surge(_ text: String, name: String) throws -> ProfileImportOutcome {
        var profile = ProfileDefaults.make()
        profile.name = name
        var report = ImportReport(format: "Surge Conf")
        var section = ""
        var outbounds: [OutboundConfig] = [.direct, .reject]
        var groups: [PolicyGroup] = []
        var rules: [Rule] = []
        var generalLines: [String] = []
        var reportedSections: Set<String> = []

        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
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
                if let ob = parseSurgeProxy(line) {
                    outbounds.append(ob)
                } else {
                    report.skippedOutbounds += 1
                    report.add(ImportIssue(kind: .skippedItem, line: offset + 1, item: line,
                                           message: "无法解析的代理行"))
                }
            case "proxy group":
                if let g = parseSurgeGroup(line, line: offset + 1, report: &report) { groups.append(g) }
            case "rule":
                let (parsed, errors) = RuleParser.parseRules(line)
                for error in errors {
                    report.add(ImportIssue(kind: .ruleError, line: offset + 1, item: line, message: error))
                }
                rules.append(contentsOf: parsed)
            case "host":
                if let pair = parseSurgeHost(line, report: &report) {
                    profile.dns.hosts[pair.0] = pair.1
                }
            default:
                if !section.isEmpty, !surgeHandledSections.contains(section),
                   reportedSections.insert(section).inserted {
                    report.add(ImportIssue(kind: .unsupportedSection, item: "[\(section)]",
                                           message: "该段未导入"))
                }
            }
        }

        applySurgeGeneral(generalLines, profile: &profile, report: &report)
        profile.outbounds = outbounds
        profile.groups = groups
        profile.rules = rules
        profile.dns.mode = inferredDNSMode(upstreams: profile.dns.upstreams)
        report.outboundCount = outbounds.count
        report.groupCount = groups.count
        report.ruleCount = rules.count
        report.annotateDialability(of: profile)
        return ProfileImportOutcome(profile: profile, report: report)
    }

    static let surgeHandledSections: Set<String> = ["general", "proxy", "proxy group", "rule", "host"]

    static func parseSurgeHost(_ line: String, report: inout ImportReport) -> (String, String)? {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        let host = parts[0].lowercased()
        let addresses = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = addresses.first, !first.isEmpty else { return nil }
        if addresses.count > 1 {
            report.add(ImportIssue(kind: .unsupportedField, item: "[Host] \(host)",
                                   message: "只保留第一个地址 \(first)，其余 \(addresses.count - 1) 个未导入"))
        }
        return (host, first)
    }

    static func applySurgeGeneral(_ lines: [String], profile: inout Profile,
                                  report: inout ImportReport) {
        for line in lines {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1]
            switch key {
            case "loglevel", "log-level":
                if let level = LogLevel(rawValue: value.lowercased()) { profile.general.logLevel = level }
            case "http-listen":
                if let port = UInt16(value.split(separator: ":").last ?? "") { profile.general.httpPort = port }
            case "mixed-listen":
                if let port = UInt16(value.split(separator: ":").last ?? "") { profile.general.mixedPort = port }
            case "socks5-listen":
                if let port = UInt16(value.split(separator: ":").last ?? "") { profile.general.socksPort = port }
            case "allow-lan", "allow-hotspot-access":
                profile.general.allowLAN = (value.lowercased() == "true")
            case "control-port":
                if let port = UInt16(value.split(separator: ":").last ?? "") {
                    profile.general.controlPort = port
                }
            case "control-listen":
                if let port = UInt16(value.split(separator: ":").last ?? "") {
                    profile.general.controlPort = port
                }
            case "control-allow-lan":
                profile.general.controlAllowLAN = (value.lowercased() == "true")
            case "dns-server":
                let servers = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if !servers.isEmpty { profile.dns.upstreams = servers }
            case "skip-cert-verify", "ipv6", "dns-follow", "exclude-simple-hostnames",
                 "tun-excluded-routes", "wifi-assist", "internet-test-url", "proxy-test-url":
                break
            default:
                report.add(ImportIssue(kind: .unsupportedField, item: "[General] \(key)",
                                       message: "该设置未导入"))
            }
        }
    }

    /// Name = http, host, port, user, pass
    /// Name = ss, host, port, encrypt-method=..., password=...
    static func parseSurgeProxy(_ line: String) -> OutboundConfig? {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        let name = parts[0]
        let fields = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 3 else { return nil }
        let typeRaw = fields[0].lowercased()
        guard let type = outboundType(typeRaw) else { return nil }
        guard let port = UInt16(fields[2]) else { return nil }
        var ob = OutboundConfig(name: name, type: type, host: fields[1], port: port, rawType: typeRaw)
        ob.tls = (typeRaw == "https")

        // Positional forms first (http/socks5: host,port,user,pass), then k=v overrides.
        if (type == .http || type == .socks5), fields.count >= 5, !fields[3].contains("=") {
            ob.username = fields[3]
            ob.password = fields[4]
        }
        for field in fields.dropFirst(3) {
            let kv = field.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            let value = kv[1]
            switch kv[0].lowercased() {
            case "username", "user": ob.username = value
            case "password", "pass": ob.password = value
            case "encrypt-method", "cipher": ob.cipher = value
            case "sni": ob.sni = value; ob.tls = true
            case "tls": ob.tls = (value.lowercased() == "true")
            case "skip-cert-verify": ob.skipCertVerify = (value.lowercased() == "true")
            case "udp-relay": ob.udp = (value.lowercased() == "true")
            case "obfs": ob.obfs = value
            case "ws": ob.network = (value.lowercased() == "true") ? "ws" : nil
            case "ws-path": ob.wsPath = value
            case "ws-headers":
                if let host = value.split(separator: ":").first { ob.wsHost = String(host) }
            default: ob.extra[kv[0].lowercased()] = value
            }
        }
        return ob
    }

    static func parseSurgeGroup(_ line: String, line number: Int,
                                report: inout ImportReport) -> PolicyGroup? {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        let fields = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = fields.first else { return nil }
        let typeRaw = first.lowercased()
        let type: PolicyGroupType
        switch typeRaw {
        case "select": type = .select
        case "url-test": type = .urlTest
        case "fallback": type = .fallback
        case "load-balance": type = .loadBalance
        default:
            type = .select
            report.add(ImportIssue(kind: .unknownGroupType, line: number, item: typeRaw,
                                   message: "策略组 \(parts[0]) 的类型 \(typeRaw) 未建模，运行时按 select 处理"))
        }
        var members: [String] = []
        var url: String?
        var interval: Int?
        var tolerance: Int?
        var filter: String?
        for field in fields.dropFirst() where !field.isEmpty {
            if let eq = field.firstIndex(of: "=") {
                let key = String(field[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(field[field.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                switch key {
                case "url": url = value
                case "interval": interval = Int(value)
                case "tolerance": tolerance = Int(value)
                case "policy-regex-filter": filter = value
                default: break
                }
            } else {
                members.append(field)
            }
        }
        return PolicyGroup(name: parts[0], type: type, proxies: members, url: url,
                           interval: interval, tolerance: tolerance,
                           rawType: type.rawValue == typeRaw ? nil : typeRaw,
                           filter: filter)
    }

    // MARK: Subscription

    public static func subscription(_ text: String, name: String) throws -> ProfileImportOutcome {
        let result = SubscriptionImporter.parse(text)
        guard !result.outbounds.isEmpty else {
            throw ProfileImportError.unrecognized(
                "订阅中没有可识别的节点（ss:// / trojan:// / vmess:// / vless:// / hysteria2://）")
        }
        var profile = ProfileDefaults.make()
        profile.name = name
        profile.outbounds = [.direct, .reject] + result.outbounds
        profile.groups = [PolicyGroup(name: "PROXY", type: .select,
                                      proxies: ["DIRECT"] + result.outbounds.map(\.name),
                                      selected: result.outbounds.first?.name)]
        profile.rules = ProfileDefaults.baseRules
        var report = ImportReport(format: "订阅", outboundCount: profile.outbounds.count,
                                  groupCount: profile.groups.count,
                                  ruleCount: profile.rules.count,
                                  skippedOutbounds: result.skipped)
        report.issues = result.issues
        report.annotateDialability(of: profile)
        return ProfileImportOutcome(profile: profile, report: report)
    }

    // MARK: Shared mapping

    static func outboundType(_ raw: String) -> OutboundType? {
        switch raw.lowercased() {
        case "ss", "shadowsocks": return .shadowsocks
        case "trojan": return .trojan
        case "http", "https": return .http
        case "socks5", "socks": return .socks5
        case "direct": return .direct
        case "reject", "reject-drop", "block": return .reject
        case "vmess": return .vmess
        case "vless": return .vless
        case "hysteria": return .hysteria
        case "hysteria2", "hy2": return .hysteria2
        case "tuic": return .tuic
        case "wireguard": return .wireguard
        case "snell": return .snell
        default: return nil
        }
    }
}

// MARK: - Errors

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

// MARK: - Subscription URI parsing

public enum SubscriptionImporter {
    public static func looksLikeSubscription(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let schemes = ["ss://", "ssr://", "trojan://", "vmess://", "vless://", "hysteria2://", "hy2://"]
        for rawLine in trimmed.components(separatedBy: .newlines).prefix(200) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if schemes.contains(where: { line.hasPrefix($0) }) { return true }
        }
        // A whole document that is base64: decode and look for a URI scheme.
        if !trimmed.contains("://"), let decoded = decodeBase64(trimmed), decoded.contains("://") {
            return true
        }
        return false
    }

    public struct Result: Sendable {
        public var outbounds: [OutboundConfig]
        public var skipped: Int
        public var issues: [ImportIssue]

        public init(outbounds: [OutboundConfig], skipped: Int, issues: [ImportIssue]) {
            self.outbounds = outbounds
            self.skipped = skipped
            self.issues = issues
        }
    }

    public static func parse(_ text: String) -> Result {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var issues: [ImportIssue] = []
        if !body.contains("://"), let decoded = decodeBase64(body) {
            body = decoded
        }
        var outbounds: [OutboundConfig] = []
        var skipped = 0
        var seen = Set<String>()
        for (offset, rawLine) in body.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else { continue }
            guard var outbound = parseURI(line) else {
                skipped += 1
                issues.append(ImportIssue(kind: .unknownProtocol, line: offset + 1, item: line,
                                          message: "无法识别的订阅节点"))
                continue
            }
            var name = outbound.name
            if name.isEmpty { name = "\(outbound.host):\(outbound.port)" }
            if !seen.insert(name).inserted {
                var counter = 2
                var candidate = "\(name) \(counter)"
                while !seen.insert(candidate).inserted {
                    counter += 1
                    candidate = "\(name) \(counter)"
                }
                name = candidate
            }
            outbound.name = name
            outbounds.append(outbound)
        }
        return Result(outbounds: outbounds, skipped: skipped, issues: issues)
    }

    static func parseURI(_ line: String) -> OutboundConfig? {
        let lowered = line.lowercased()
        if lowered.hasPrefix("ss://") { return parseShadowsocks(line) }
        if lowered.hasPrefix("trojan://") { return parseTrojan(line) }
        if lowered.hasPrefix("vmess://") { return parseVMess(line) }
        if lowered.hasPrefix("vless://") { return parseVLESS(line) }
        if lowered.hasPrefix("hysteria2://") || lowered.hasPrefix("hy2://") { return parseHysteria2(line) }
        return nil
    }

    static func parseShadowsocks(_ uri: String) -> OutboundConfig? {
        var body = String(uri.dropFirst("ss://".count))
        var name = ""
        if let hash = body.firstIndex(of: "#") {
            name = percentDecode(String(body[body.index(after: hash)...]))
            body = String(body[..<hash])
        }
        var query: [String: String] = [:]
        if let mark = body.firstIndex(of: "?") {
            query = parseQuery(String(body[body.index(after: mark)...]))
            body = String(body[..<mark])
        }
        var method = ""
        var password = ""
        var host = ""
        var port: UInt16 = 0
        if let at = body.lastIndex(of: "@") {
            let userinfo = String(body[..<at])
            let authority = String(body[body.index(after: at)...])
            if let decoded = decodeBase64(userinfo), decoded.contains(":") {
                let parts = decoded.split(separator: ":", maxSplits: 1).map(String.init)
                method = parts[0]
                password = parts.count > 1 ? parts[1] : ""
            } else if userinfo.contains(":") {
                let parts = userinfo.split(separator: ":", maxSplits: 1).map(String.init)
                method = percentDecode(parts[0])
                password = parts.count > 1 ? percentDecode(parts[1]) : ""
            } else {
                return nil
            }
            guard let pair = splitHostPort(authority) else { return nil }
            host = pair.host
            port = pair.port
        } else {
            guard let decoded = decodeBase64(body), let at = decoded.lastIndex(of: "@") else { return nil }
            let userinfo = String(decoded[..<at])
            let authority = String(decoded[decoded.index(after: at)...])
            let parts = userinfo.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let pair = splitHostPort(authority) else { return nil }
            method = parts[0]
            password = parts[1]
            host = pair.host
            port = pair.port
        }
        guard !host.isEmpty, port != 0 else { return nil }
        var ob = OutboundConfig(name: name, type: .shadowsocks, host: host, port: port,
                                password: password, cipher: method, rawType: "ss")
        if let plugin = query["plugin"] {
            ob.plugin = plugin
            ob.extra["plugin"] = plugin
        }
        return ob
    }

    static func parseTrojan(_ uri: String) -> OutboundConfig? {
        guard let parsed = parseUserInfoAuthority(uri, scheme: "trojan://") else { return nil }
        var ob = OutboundConfig(name: parsed.name, type: .trojan, host: parsed.host,
                                port: parsed.port, password: parsed.user, tls: true, rawType: "trojan")
        ob.sni = parsed.query["sni"] ?? parsed.query["peer"]
        if let insecure = parsed.query["allowinsecure"] ?? parsed.query["insecure"] {
            ob.skipCertVerify = (insecure == "1" || insecure.lowercased() == "true")
        }
        ob.network = parsed.query["type"]
        ob.wsPath = parsed.query["path"]
        ob.wsHost = parsed.query["host"]
        return ob
    }

    static func parseVLESS(_ uri: String) -> OutboundConfig? {
        guard let parsed = parseUserInfoAuthority(uri, scheme: "vless://") else { return nil }
        let security = parsed.query["security"]
        var ob = OutboundConfig(name: parsed.name, type: .vless, host: parsed.host,
                                port: parsed.port,
                                tls: security == "tls" || security == "reality",
                                rawType: "vless")
        ob.uuid = parsed.user
        ob.sni = parsed.query["sni"]
        ob.flow = parsed.query["flow"]
        ob.network = parsed.query["type"]
        ob.wsPath = parsed.query["path"]
        ob.wsHost = parsed.query["host"]
        ob.security = security
        ob.grpcServiceName = parsed.query["servicename"]
        return ob
    }

    static func parseHysteria2(_ uri: String) -> OutboundConfig? {
        let scheme = uri.lowercased().hasPrefix("hy2://") ? "hy2://" : "hysteria2://"
        guard let parsed = parseUserInfoAuthority(uri, scheme: scheme) else { return nil }
        var ob = OutboundConfig(name: parsed.name, type: .hysteria2, host: parsed.host,
                                port: parsed.port, password: parsed.user, tls: true, rawType: "hysteria2")
        ob.sni = parsed.query["sni"]
        if let insecure = parsed.query["insecure"] {
            ob.skipCertVerify = (insecure == "1" || insecure.lowercased() == "true")
        }
        if let obfs = parsed.query["obfs"] {
            ob.obfs = obfs
            ob.obfsPassword = parsed.query["obfs-password"]
        }
        return ob
    }

    static func parseVMess(_ uri: String) -> OutboundConfig? {
        let body = String(uri.dropFirst("vmess://".count))
        guard let decoded = decodeBase64(body),
              let data = decoded.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func text(_ key: String) -> String? {
            if let value = json[key] as? String, !value.isEmpty { return value }
            if let value = json[key] as? Int { return String(value) }
            return nil
        }
        guard let host = text("add"), let portText = text("port"), let port = UInt16(portText) else { return nil }
        var ob = OutboundConfig(name: text("ps") ?? "", type: .vmess, host: host, port: port,
                                rawType: "vmess")
        ob.uuid = text("id")
        if let aid = text("aid").flatMap(Int.init) { ob.alterId = aid }
        ob.network = text("net")
        ob.wsPath = text("path")
        ob.wsHost = text("host")
        let tls = (text("tls") ?? "").lowercased()
        ob.tls = (tls == "tls")
        ob.security = ob.tls ? "tls" : nil
        ob.sni = text("sni")
        return ob
    }

    struct URIParts {
        var user: String
        var host: String
        var port: UInt16
        var name: String
        var query: [String: String]
    }

    static func parseUserInfoAuthority(_ uri: String, scheme: String) -> URIParts? {
        guard uri.lowercased().hasPrefix(scheme) else { return nil }
        var body = String(uri.dropFirst(scheme.count))
        var name = ""
        if let hash = body.firstIndex(of: "#") {
            name = percentDecode(String(body[body.index(after: hash)...]))
            body = String(body[..<hash])
        }
        var query: [String: String] = [:]
        if let mark = body.firstIndex(of: "?") {
            query = parseQuery(String(body[body.index(after: mark)...]))
            body = String(body[..<mark])
        }
        guard let at = body.lastIndex(of: "@") else { return nil }
        let user = percentDecode(String(body[..<at]))
        let authority = String(body[body.index(after: at)...])
        guard let pair = splitHostPort(authority) else { return nil }
        return URIParts(user: user, host: pair.host, port: pair.port, name: name, query: query)
    }

    static func splitHostPort(_ authority: String) -> (host: String, port: UInt16)? {
        let trimmed = authority.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            guard rest.hasPrefix(":") else { return nil }
            let portText = String(rest.dropFirst())
            guard let port = UInt16(portText) else { return nil }
            return (host, port)
        }
        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        let host = String(trimmed[..<colon])
        let portText = String(trimmed[trimmed.index(after: colon)...])
        guard !host.isEmpty, let port = UInt16(portText) else { return nil }
        return (host, port)
    }

    static func parseQuery(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let key = parts.first?.lowercased(), !key.isEmpty else { continue }
            let value = parts.count > 1 ? percentDecode(String(parts[1])) : ""
            result[key] = value
        }
        return result
    }

    static func percentDecode(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }

    public static func decodeBase64(_ text: String) -> String? {
        let compact = text.filter { !$0.isWhitespace }
        guard compact.count >= 8 else { return nil }
        var normalized = compact
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 { normalized += "=" }
        guard let data = Data(base64Encoded: normalized),
              let decoded = String(data: data, encoding: .utf8) else { return nil }
        return decoded
    }
}

// MARK: - Exporter

/// Writes profiles back out in formats other tools accept. The exporters never
/// invent data: anything not modelled is dropped deliberately and documented in
/// docs/audit-formats.md, while unknown-but-kept keys travel through extra maps.
public enum ProfileExporter {
    public static func clash(_ profile: Profile) -> String {
        var out: [String] = []
        out.append("mixed-port: \(profile.general.mixedPort)")
        out.append("port: \(profile.general.httpPort)")
        out.append("socks-port: \(profile.general.socksPort)")
        out.append("allow-lan: \(profile.general.allowLAN)")
        out.append("control-port: \(profile.general.controlPort)")
        out.append("control-allow-lan: \(profile.general.controlAllowLAN)")
        out.append("mode: rule")
        out.append("log-level: \(profile.general.logLevel.rawValue)")
        out.append(contentsOf: clashDNSBlock(profile.dns))

        let proxies = profile.outbounds.filter { $0.type != .direct && $0.type != .reject }
        if proxies.isEmpty {
            out.append("proxies: []")
        } else {
            out.append("proxies:")
            for outbound in proxies {
                out.append(contentsOf: clashOutboundBlock(outbound))
            }
        }

        if profile.groups.isEmpty {
            out.append("proxy-groups: []")
        } else {
            out.append("proxy-groups:")
            for group in profile.groups {
                out.append(contentsOf: clashGroupBlock(group))
            }
        }

        if !profile.ruleProviders.isEmpty {
            out.append("rule-providers:")
            for provider in profile.ruleProviders {
                out.append(contentsOf: clashProviderBlock(name: provider.name, provider: provider))
            }
        }
        if !profile.proxyProviders.isEmpty {
            out.append("proxy-providers:")
            for provider in profile.proxyProviders {
                out.append(contentsOf: clashProviderBlock(name: provider.name, provider: provider))
            }
        }

        let rules = RuleParser.exportClash(profile.rules)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if rules.isEmpty {
            out.append("rules: []")
        } else {
            out.append("rules:")
            for line in rules {
                out.append("  - \(line)")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func clashDNSBlock(_ dns: DNSConfig) -> [String] {
        var block: [String] = ["dns:", "  enable: true"]
        block.append("  listen: 0.0.0.0:\(dns.listenPort)")
        if dns.mode == .fakeIP {
            block.append("  enhanced-mode: fake-ip")
            block.append("  fake-ip-range: \(yamlScalar(dns.fakeIPRange))")
        }
        if !dns.upstreams.isEmpty {
            block.append("  nameserver:")
            for server in dns.upstreams { block.append("    - \(yamlScalar(server))") }
        }
        if !dns.fallback.isEmpty {
            block.append("  fallback:")
            for server in dns.fallback { block.append("    - \(yamlScalar(server))") }
        }
        if !dns.hosts.isEmpty {
            block.append("  hosts:")
            for key in dns.hosts.keys.sorted() {
                guard let value = dns.hosts[key] else { continue }
                block.append("    \(yamlScalar(key)): \(yamlScalar(value))")
            }
        }
        if !dns.nameserverPolicy.isEmpty {
            block.append("  nameserver-policy:")
            for key in dns.nameserverPolicy.keys.sorted() {
                guard let servers = dns.nameserverPolicy[key], !servers.isEmpty else { continue }
                block.append("    \(yamlScalar(key)):")
                for server in servers { block.append("      - \(yamlScalar(server))") }
            }
        }
        if !dns.fakeIPFilter.isEmpty {
            block.append("  fake-ip-filter:")
            for pattern in dns.fakeIPFilter { block.append("    - \(yamlScalar(pattern))") }
        }
        return block
    }

    static func clashOutboundBlock(_ outbound: OutboundConfig) -> [String] {
        var block: [String] = []
        block.append("  - name: \(yamlScalar(outbound.name))")
        block.append("    type: \(clashType(outbound))")
        if !outbound.host.isEmpty { block.append("    server: \(yamlScalar(outbound.host))") }
        if outbound.port != 0 { block.append("    port: \(outbound.port)") }
        if let value = outbound.username, !value.isEmpty { block.append("    username: \(yamlScalar(value))") }
        if let value = outbound.password, !value.isEmpty { block.append("    password: \(yamlScalar(value))") }
        if let value = outbound.cipher, !value.isEmpty { block.append("    cipher: \(yamlScalar(value))") }
        if let value = outbound.uuid, !value.isEmpty { block.append("    uuid: \(yamlScalar(value))") }
        if let value = outbound.alterId { block.append("    alterId: \(value)") }
        if let value = outbound.flow, !value.isEmpty { block.append("    flow: \(yamlScalar(value))") }
        if outbound.tls { block.append("    tls: true") }
        if let value = outbound.sni, !value.isEmpty { block.append("    sni: \(yamlScalar(value))") }
        if let value = outbound.security, !value.isEmpty { block.append("    security: \(yamlScalar(value))") }
        if let value = outbound.skipCertVerify { block.append("    skip-cert-verify: \(value)") }
        if let value = outbound.udp { block.append("    udp: \(value)") }
        if let value = outbound.network, !value.isEmpty { block.append("    network: \(yamlScalar(value))") }
        if let alpn = outbound.alpn, !alpn.isEmpty {
            let items = alpn.map { yamlScalar($0) }.joined(separator: ", ")
            block.append("    alpn: [\(items)]")
        }
        if outbound.wsPath != nil || outbound.wsHost != nil {
            block.append("    ws-opts:")
            if let value = outbound.wsPath { block.append("      path: \(yamlScalar(value))") }
            if let value = outbound.wsHost {
                block.append("      headers:")
                block.append("        Host: \(yamlScalar(value))")
            }
        }
        if let value = outbound.grpcServiceName, !value.isEmpty {
            block.append("    grpc-opts:")
            block.append("      grpc-service-name: \(yamlScalar(value))")
        }
        if outbound.publicKey != nil || outbound.shortID != nil {
            block.append("    reality-opts:")
            if let value = outbound.publicKey { block.append("      public-key: \(yamlScalar(value))") }
            if let value = outbound.shortID { block.append("      short-id: \(yamlScalar(value))") }
        }
        if let value = outbound.obfs, !value.isEmpty { block.append("    obfs: \(yamlScalar(value))") }
        if let value = outbound.obfsPassword, !value.isEmpty { block.append("    obfs-password: \(yamlScalar(value))") }
        if let value = outbound.plugin, !value.isEmpty { block.append("    plugin: \(yamlScalar(value))") }
        if let value = outbound.pluginOpts, !value.isEmpty { block.append("    plugin-opts: \(yamlScalar(value))") }
        for key in outbound.extra.keys.sorted() {
            guard let value = outbound.extra[key] else { continue }
            block.append("    \(yamlScalar(key)): \(yamlScalar(value))")
        }
        return block
    }

    static func clashGroupBlock(_ group: PolicyGroup) -> [String] {
        var block: [String] = []
        block.append("  - name: \(yamlScalar(group.name))")
        block.append("    type: \(clashGroupType(group))")
        if !group.proxies.isEmpty {
            block.append("    proxies:")
            for proxy in group.proxies { block.append("      - \(yamlScalar(proxy))") }
        }
        if !group.use.isEmpty {
            block.append("    use:")
            for provider in group.use { block.append("      - \(yamlScalar(provider))") }
        }
        if let value = group.filter, !value.isEmpty { block.append("    filter: \(yamlScalar(value))") }
        if let value = group.excludeFilter, !value.isEmpty { block.append("    exclude-filter: \(yamlScalar(value))") }
        if group.includeAll { block.append("    include-all: true") }
        if let value = group.url, !value.isEmpty { block.append("    url: \(yamlScalar(value))") }
        if let value = group.interval { block.append("    interval: \(value)") }
        if let value = group.tolerance { block.append("    tolerance: \(value)") }
        return block
    }

    static func clashProviderBlock(name: String, provider: RuleProvider) -> [String] {
        var block: [String] = []
        block.append("  \(yamlScalar(name)):")
        let type = provider.type.isEmpty ? "http" : provider.type
        block.append("    type: \(yamlScalar(type))")
        if !provider.behavior.isEmpty { block.append("    behavior: \(yamlScalar(provider.behavior))") }
        if let value = provider.url, !value.isEmpty { block.append("    url: \(yamlScalar(value))") }
        if let value = provider.path, !value.isEmpty { block.append("    path: \(yamlScalar(value))") }
        if let value = provider.interval { block.append("    interval: \(value)") }
        if let value = provider.format, !value.isEmpty { block.append("    format: \(yamlScalar(value))") }
        if !provider.payload.isEmpty {
            block.append("    payload:")
            for item in provider.payload { block.append("      - \(yamlScalar(item))") }
        }
        for key in provider.extra.keys.sorted() {
            guard let value = provider.extra[key] else { continue }
            block.append("    \(yamlScalar(key)): \(yamlScalar(value))")
        }
        return block
    }

    public static func surge(_ profile: Profile) -> String {
        var lines: [String] = []
        lines.append("# Leapin Surge 5 导出")
        lines.append("")
        lines.append("[General]")
        lines.append("loglevel = \(profile.general.logLevel.rawValue)")
        lines.append("mixed-listen = 0.0.0.0:\(profile.general.mixedPort)")
        lines.append("http-listen = 0.0.0.0:\(profile.general.httpPort)")
        lines.append("socks5-listen = 0.0.0.0:\(profile.general.socksPort)")
        lines.append("allow-lan = \(profile.general.allowLAN)")
        lines.append("control-port = \(profile.general.controlPort)")
        lines.append("control-allow-lan = \(profile.general.controlAllowLAN)")
        if !profile.dns.upstreams.isEmpty {
            lines.append("dns-server = \(profile.dns.upstreams.joined(separator: ", "))")
        }
        lines.append("")
        lines.append("[Proxy]")
        for outbound in profile.outbounds where outbound.type != .direct && outbound.type != .reject {
            if let line = surgeProxyLine(outbound) {
                lines.append(line)
            } else {
                let token = outbound.rawType ?? outbound.type.rawValue
                lines.append("# Surge 不支持该协议，未导出：\(outbound.name) (\(token))")
            }
        }
        lines.append("")
        lines.append("[Proxy Group]")
        for group in profile.groups {
            var parts: [String] = [surgeGroupType(group)]
            parts.append(contentsOf: group.proxies)
            if let value = group.url, !value.isEmpty { parts.append("url=\(value)") }
            if let value = group.interval { parts.append("interval=\(value)") }
            if let value = group.tolerance { parts.append("tolerance=\(value)") }
            if let value = group.filter, !value.isEmpty { parts.append("policy-regex-filter=\(value)") }
            lines.append("\(group.name) = \(parts.joined(separator: ", "))")
        }
        let rules = RuleParser.exportSurge(profile.rules)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !rules.isEmpty {
            lines.append("")
            lines.append("[Rule]")
            lines.append(contentsOf: rules)
        }
        if !profile.dns.hosts.isEmpty {
            lines.append("")
            lines.append("[Host]")
            for key in profile.dns.hosts.keys.sorted() {
                guard let value = profile.dns.hosts[key] else { continue }
                lines.append("\(key) = \(value)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func surgeProxyLine(_ outbound: OutboundConfig) -> String? {
        switch outbound.type {
        case .shadowsocks:
            var parts: [String] = ["ss", outbound.host, String(outbound.port)]
            if let value = outbound.cipher, !value.isEmpty { parts.append("encrypt-method=\(value)") }
            if let value = outbound.password, !value.isEmpty { parts.append("password=\(value)") }
            if let value = outbound.obfs, !value.isEmpty { parts.append("obfs=\(value)") }
            if let value = outbound.obfsPassword, !value.isEmpty { parts.append("obfs-password=\(value)") }
            if let value = outbound.udp { parts.append("udp-relay=\(value)") }
            return "\(outbound.name) = \(parts.joined(separator: ", "))"
        case .trojan:
            var parts: [String] = ["trojan", outbound.host, String(outbound.port)]
            if let value = outbound.password, !value.isEmpty { parts.append("password=\(value)") }
            if let value = outbound.sni, !value.isEmpty { parts.append("sni=\(value)") }
            parts.append("tls=true")
            if let value = outbound.skipCertVerify { parts.append("skip-cert-verify=\(value)") }
            if let value = outbound.network, !value.isEmpty { parts.append("network=\(value)") }
            if let value = outbound.wsPath, !value.isEmpty { parts.append("ws-path=\(value)") }
            if let value = outbound.udp { parts.append("udp-relay=\(value)") }
            return "\(outbound.name) = \(parts.joined(separator: ", "))"
        case .http, .socks5:
            let token = outbound.type == .http ? "http" : "socks5"
            var parts: [String] = [token, outbound.host, String(outbound.port)]
            if let value = outbound.username, !value.isEmpty { parts.append(value) }
            if let value = outbound.password, !value.isEmpty { parts.append(value) }
            if outbound.type == .http && outbound.tls { parts.append("tls=true") }
            if let value = outbound.sni, !value.isEmpty { parts.append("sni=\(value)") }
            return "\(outbound.name) = \(parts.joined(separator: ", "))"
        case .vmess, .vless, .hysteria, .hysteria2, .tuic, .wireguard, .snell, .unsupported:
            return nil
        case .direct, .reject:
            return nil
        }
    }

    static func clashType(_ outbound: OutboundConfig) -> String {
        if let raw = outbound.rawType, !raw.isEmpty { return raw }
        switch outbound.type {
        case .shadowsocks: return "ss"
        case .trojan: return "trojan"
        case .http: return "http"
        case .socks5: return "socks5"
        case .vmess: return "vmess"
        case .vless: return "vless"
        case .hysteria: return "hysteria"
        case .hysteria2: return "hysteria2"
        case .tuic: return "tuic"
        case .wireguard: return "wireguard"
        case .snell: return "snell"
        case .direct: return "direct"
        case .reject: return "reject"
        case .unsupported: return "unsupported"
        }
    }

    static func clashGroupType(_ group: PolicyGroup) -> String {
        if let raw = group.rawType, !raw.isEmpty { return raw }
        switch group.type {
        case .select: return "select"
        case .urlTest: return "url-test"
        case .fallback: return "fallback"
        case .loadBalance: return "load-balance"
        case .reject: return "select"
        }
    }

    static func surgeGroupType(_ group: PolicyGroup) -> String {
        if let raw = group.rawType, !raw.isEmpty { return raw }
        switch group.type {
        case .select: return "select"
        case .urlTest: return "url-test"
        case .fallback: return "fallback"
        case .loadBalance: return "load-balance"
        case .reject: return "select"
        }
    }

    /// Quotes a YAML scalar only when leaving it bare would change its meaning.
    public static func yamlScalar(_ text: String) -> String {
        if text.isEmpty { return "\"\"" }
        if needsYAMLQuoting(text) {
            let escaped = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(escaped)\""
        }
        return text
    }

    static func needsYAMLQuoting(_ text: String) -> Bool {
        if text != text.trimmingCharacters(in: .whitespaces) { return true }
        if text.contains("\n") || text.contains("\\") { return true }
        if text.contains("\u{0060}") { return true }
        let specials: Set<Character> = [":", "#", ",", "{", "}", "[", "]", "&", "*", "!", "|", ">", "'", "\"", "%", "@"]
        if text.contains(where: { specials.contains($0) }) { return true }
        guard let first = text.first else { return true }
        if "-?:,[]{}#&*!|>'\"%@".contains(first) { return true }
        let lower = text.lowercased()
        if ["true", "false", "null", "~", "yes", "no", "on", "off"].contains(lower) { return true }
        if Double(text) != nil { return true }
        return false
    }
}

// MARK: - Network-blocklist exports (hosts / ABP / Clash rule-set)

/// Extra export targets that other tools consume directly. Only rules whose
/// policy actually resolves to REJECT are exported as blocks: exporting a
/// DIRECT/PROXY rule into a blocklist would silently change behaviour, so those
/// are counted and reported in the file header instead.
extension ProfileExporter {
    /// True when `policy` names REJECT, the built-in reject outbound, or any
    /// policy group that resolves to a reject group.
    static func isRejectPolicy(_ policy: String, in profile: Profile) -> Bool {
        let upper = policy.uppercased()
        if upper == "REJECT" || upper == "REJECT-DROP" { return true }
        guard let group = profile.groups.first(where: { $0.name == policy }) else { return false }
        return group.type == .reject
    }

    /// `/etc/hosts` style blocklist. hosts has no suffix or wildcard syntax, so
    /// only exact DOMAIN rules can be emitted faithfully.
    public static func hosts(_ profile: Profile) -> String {
        var out: [String] = []
        var emitted = 0
        var unsupported = 0
        var lines: [String] = []
        for rule in profile.rules {
            guard isRejectPolicy(rule.policy, in: profile) else { continue }
            switch rule.kind {
            case .domain:
                let host = rule.value.trimmingCharacters(in: .whitespaces)
                guard !host.isEmpty, !host.contains("*") else { unsupported += 1; continue }
                lines.append("0.0.0.0 \(host)")
                emitted += 1
            case .domainSuffix, .domainKeyword, .domainRegex:
                unsupported += 1
            default:
                unsupported += 1
            }
        }
        out.append("# Leapin hosts export")
        out.append("# 仅导出策略为 REJECT 的精确域名规则（\(emitted) 条）。")
        if unsupported > 0 {
            out.append("# 另有 \(unsupported) 条规则无法用 hosts 表达（后缀/关键词/正则/IP/进程/组合规则），请改用 ABP 或 Clash rule-set 导出。")
        }
        out.append(contentsOf: lines)
        return out.joined(separator: "\n") + "\n"
    }

    /// Adblock Plus / uBlock Origin filter list.
    public static func abp(_ profile: Profile) -> String {
        var out: [String] = []
        var emitted = 0
        var unsupported = 0
        var lines: [String] = []
        for rule in profile.rules {
            guard isRejectPolicy(rule.policy, in: profile) else { continue }
            let value = rule.value.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { unsupported += 1; continue }
            switch rule.kind {
            case .domain, .domainSuffix:
                // domain-suffix must also cover subdomains: ||example.com^ does.
                lines.append("||\(value)^")
                emitted += 1
            case .domainKeyword:
                lines.append("/\(value)/")
                emitted += 1
            case .domainRegex:
                lines.append("/\(value)/")
                emitted += 1
            default:
                unsupported += 1
            }
        }
        out.append("! Title: Leapin adblock export")
        out.append("! 仅导出策略为 REJECT 的 \(emitted) 条域名规则。")
        if unsupported > 0 {
            out.append("! \(unsupported) 条规则（IP/进程/GEOSITE 等）ABP 无法表达，已在导出时跳过。")
        }
        out.append(contentsOf: lines)
        return out.joined(separator: "\n") + "\n"
    }

    /// Clash `behavior: classical` rule-set payload, reusable in a
    /// `rule-providers` entry or pasted into another Clash profile.
    public static func ruleSet(_ profile: Profile) -> String {
        let exportable: Set<RuleKind> = [.domain, .domainSuffix, .domainKeyword, .domainRegex, .ipCIDR, .ipCIDR6, .geoIP]
        var out: [String] = ["payload:"]
        var emitted = 0
        for rule in profile.rules where exportable.contains(rule.kind) {
            let line = RuleParser.exportLine(rule, matchToken: "MATCH")
            out.append("  - " + line)
            emitted += 1
        }
        if emitted == 0 { out.append("  []") }
        return out.joined(separator: "\n") + "\n"
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
                PolicyGroup(name: "AUTO", type: .urlTest, proxies: ["DIRECT", "示例-上游"],
                            url: "http://www.gstatic.com/generate_204", interval: 300),
            ],
            rules: baseRules
        )
    }
}


import Foundation
import LeapinCore

public enum DiagnosticAction: String, Sendable {
    case connect, settings, capture, profiles, debugChannel, none
}
public struct DiagnosticFinding: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let action: DiagnosticAction
    public let isProblem: Bool
}
public struct DiagnosticLogCluster: Identifiable, Sendable {
    public var id: String { source + kind }
    public let source: String
    public let kind: String
    public var count: Int
    public var first: Date?
    public var last: Date?
    public let sample: String
}
public struct NetworkDiagnosticReport: Identifiable, Sendable {
    public let id = UUID()
    public let date: Date
    public let profileID: UUID
    public let target: String?
    public let captureCheck: Bool
    public let findings: [DiagnosticFinding]
    public let logClusters: [DiagnosticLogCluster]
    public var problemCount: Int { findings.filter(\.isProblem).count }
    public var copyText: String {
        var rows = ["Leapin 网络检查", ISO8601DateFormatter().string(from: date), target.map { "目标：\($0)" } ?? "范围：本地状态",
                    "待处理：\(problemCount)"]
        for finding in findings { rows.append("\(finding.title)：\(Redactor.redact(finding.detail))") }
        for cluster in logClusters { rows.append("日志线索：\(cluster.source) · \(cluster.kind) · \(cluster.count) 条（不含原始日志内容）") }
        return rows.joined(separator: "\n")
    }
}

public struct NetworkDiagnosticInput: Sendable {
    public var profileID: UUID
    public var state: EngineState
    public var systemProxyActive: Bool
    public var kernel: ExecutionKernel
    public var managedRunning: Bool
    public var captureEnabled: Bool
    public var mitmEnabled: Bool
    public var certificateExists: Bool
    public var captureCount: Int
    public var captureCheck: Bool
    public var target: String?
    public var dns: DNSTrace?
    public var direct: HTTPProbeResult?
    public var proxy: HTTPProbeResult?
    public var logs: [LogEntry]
    public var managedLogs: String
    public var date: Date
    public init(profileID: UUID = UUID(), state: EngineState = .stopped, systemProxyActive: Bool = false,
                kernel: ExecutionKernel = .native, managedRunning: Bool = false, captureEnabled: Bool = true,
                mitmEnabled: Bool = false, certificateExists: Bool = false, captureCount: Int = 0,
                captureCheck: Bool = false, target: String? = nil, dns: DNSTrace? = nil,
                direct: HTTPProbeResult? = nil, proxy: HTTPProbeResult? = nil, logs: [LogEntry] = [],
                managedLogs: String = "", date: Date = Date()) {
        self.profileID = profileID; self.state = state; self.systemProxyActive = systemProxyActive
        self.kernel = kernel; self.managedRunning = managedRunning; self.captureEnabled = captureEnabled
        self.mitmEnabled = mitmEnabled; self.certificateExists = certificateExists; self.captureCount = captureCount
        self.captureCheck = captureCheck; self.target = target; self.dns = dns; self.direct = direct; self.proxy = proxy
        self.logs = logs; self.managedLogs = managedLogs; self.date = date
    }
}

public enum NetworkDiagnosticAnalyzer {
    public static func analyze(_ input: NetworkDiagnosticInput) -> NetworkDiagnosticReport {
        var findings: [DiagnosticFinding] = []
        func add(_ id: String, _ title: String, _ detail: String, _ action: DiagnosticAction = .none, problem: Bool = true) {
            findings.append(DiagnosticFinding(id: id, title: title, detail: Redactor.redact(detail), action: action, isProblem: problem))
        }
        switch input.state {
        case .stopped: add("stopped", "本地代理未运行", "还没有可供 App 使用的本地监听服务。需要代理时，可启动并接入网络。", .connect)
        case .starting: add("starting", "服务仍在启动", "就绪后再检查目标路径。", problem: false)
        case .failed(let reason):
            let lower = reason.lowercased()
            if lower.contains("in use") || lower.contains("address already") || reason.contains("占用") {
                add("port", "监听端口可能被占用", "启动返回：\(reason)。在设置中换用空闲端口，或检查占用进程；不会自动结束其他软件。", .settings)
            } else { add("failed", "服务启动失败", "\(reason)。可检查当前配置与内核状态后重试。", .profiles) }
        case .running:
            if input.kernel == .mihomo && !input.managedRunning {
                add("kernel", "外部内核未就绪", "本地入口的状态不能代表 Mihomo 正常。请在线路与订阅中检查内核并重新启用。", .profiles)
            }
            if !input.systemProxyActive {
                add("not-system", "系统代理未接入", "本地入口可以供手动配置的 App 使用；其他 App 不一定经过 Leapin。", .connect, problem: false)
            }
        }
        if input.target == nil {
            add("scope", "本次只检查本地状态", "没有请求外部网站，也未验证实际代理出口、完整页面或家庭资源。", problem: false)
        }
        if let direct = input.direct {
            if let error = direct.error {
                add("direct", "直连 GET 未完成", "\(error)。这只说明直连检查异常，不能据此判断代理路径。", problem: input.proxy == nil)
            } else {
                add("direct", "直连 GET 返回 HTTP \(direct.statusCode ?? 0)", "耗时 \(Int(direct.elapsedMs)) ms。GET 与代理 HEAD 方法不同，响应不可直接等同。", problem: false)
            }
        }
        if let dns = input.dns, let error = dns.error { add("dns", "当前 DNS 检查失败", "\(error)。先检查解析上游、过滤与目标域名。", .settings) }
        if let result = input.proxy {
            if let error = result.error {
                let comparison = input.direct?.error == nil && (200..<400).contains(input.direct?.statusCode ?? 0)
                    ? "直连 GET 能收到响应，而代理 HEAD 失败。两种方法不同，应进一步核对线路、TLS 与站点行为。" : "当前代理 HEAD 请求没有完成。"
                add("proxy-path", "代理路径检查失败", "\(comparison) \(error)", .profiles)
            } else if result.statusCode == 405 || result.statusCode == 501 {
                add("head", "网站不支持此 HEAD 检查", "这不能单独证明代理不可用。请在浏览器或目标 App 中验证实际请求。", problem: false)
            } else if (result.statusCode ?? 0) >= 400 {
                add("http", "代理路径返回 HTTP \(result.statusCode ?? 0)", "已收到 HTTP 响应；访问限制、登录要求或上游错误仍需结合站点和日志判断。", .profiles)
            } else { add("responded", "代理路径已收到响应", "HEAD HTTP \(result.statusCode ?? 0)，\(Int(result.elapsedMs)) ms。此结果不验证登录、完整页面或 Agent 任务。", problem: false) }
        }
        if input.captureCheck {
            if !input.captureEnabled { add("capture-off", "抓包没有开启", "先开启请求记录，再让目标 App 产生一次新请求。", .capture) }
            if input.kernel == .mihomo {
                add("mitm-managed", "内置抓包不解密 Mihomo 的 HTTPS", "可建立独立 mitmproxy 调试通道，限定网站并配置目标 App 与调试 CA。它与此处的原生抓包记录分开。", .debugChannel)
            } else if !input.mitmEnabled {
                add("mitm-off", "HTTPS 解密未开启", "HTTPS 隧道没有明文详情属于当前配置行为。需要时在抓包页选择解密范围并处理证书信任。", .capture, problem: false)
            } else if !input.certificateExists {
                add("ca-missing", "未发现本地 CA 文件", "先启动原生服务生成 CA，再按系统提示安装并信任；不会静默设置信任。", .capture)
            } else {
                add("ca-present", "CA 文件存在，信任状态未验证", "还需确认系统信任、目标主机范围和客户端证书固定。原生解密目前仅处理 HTTP/1.1。", .capture, problem: false)
            }
            if input.captureEnabled && input.captureCount == 0 {
                add("no-samples", "当前没有请求样本", "请确认目标 App 的流量实际经过代理，并产生新请求。没有样本不能判断抓包引擎已经损坏。", .capture, problem: false)
            }
        }
        let clusters = cluster(input)
        if clusters.contains(where: { $0.kind == "TLS / 证书" }) {
            add("tls-hint", "日志包含 TLS 或证书线索", "这是历史日志线索，不等于已发生中间人攻击。请核对证书链、目标主机、CA 信任、协议版本与证书固定；不通过关闭校验来修复。", .capture, problem: false)
        }
        return NetworkDiagnosticReport(date: input.date, profileID: input.profileID, target: input.target,
            captureCheck: input.captureCheck, findings: findings, logClusters: clusters)
    }
    private static func cluster(_ input: NetworkDiagnosticInput) -> [DiagnosticLogCluster] {
        var grouped: [String: DiagnosticLogCluster] = [:]
        func append(source: String, message: String, date: Date?) {
            let lower = message.lowercased()
            let kind: String
            if ["certificate", "tls", "x509", "证书"].contains(where: lower.contains) { kind = "TLS / 证书" }
            else if ["dns", "resolve", "解析"].contains(where: lower.contains) { kind = "DNS / 解析" }
            else if ["in use", "bind failed", "占用"].contains(where: lower.contains) { kind = "端口 / 监听" }
            else if ["unsupported", "not dialable", "不支持", "不可拨"].contains(where: lower.contains) { kind = "协议 / 配置" }
            else if ["timeout", "timed out", "超时"].contains(where: lower.contains) { kind = "连接超时" }
            else if ["refused", "拒绝", "unreachable"].contains(where: lower.contains) { kind = "连接拒绝 / 不可达" }
            else { return }
            let key = source + kind
            if var current = grouped[key] {
                current.count += 1
                if let date { current.first = min(current.first ?? date, date); current.last = max(current.last ?? date, date) }
                grouped[key] = current
            } else {
                grouped[key] = DiagnosticLogCluster(source: source, kind: kind, count: 1, first: date, last: date,
                    sample: String(Redactor.redact(message).prefix(320)))
            }
        }
        for entry in input.logs.suffix(300) where entry.date >= input.date.addingTimeInterval(-900) && entry.date <= input.date && entry.level >= .warning {
            append(source: "Leapin", message: entry.message, date: entry.date)
        }
        if input.kernel == .mihomo {
            for line in input.managedLogs.split(separator: "\n").suffix(100) { append(source: "Mihomo", message: String(line), date: nil) }
        }
        return grouped.values.sorted { $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count }
    }
}

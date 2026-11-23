import Foundation
import Combine
import LeapinCore
import LeapinNet

/// 常驻层（菜单栏面板 / 实时浮窗 / 图标）唯一的状态源。
///
/// 为什么要有这个类型：面板、浮窗和图标各自读 `LiveTraffic` 并各自按秒差分，
/// 同一时刻就能显示三个不同的速率。速率差分是**有状态**的，所以它只能发生一次；
/// 一旦发生两次，两个面就各有一份基准，永远对不齐。
///
/// 这里只有纯计算（`ResidentStatus.make`）和一个可观测的容器
/// （`ResidentStatusStore`）。容器不持有定时器：采样由面自己（面板打开时、浮窗的
/// 1 Hz）驱动，容器只负责把第二帧之后的字节差算成速率。
public enum ResidentTone: String, Sendable, Equatable, CaseIterable {
    /// 没在跑：墨色，不报警。
    case idle
    /// 正常：墨色，三级信息的第一级。
    case normal
    /// 降级：半红。还在跑，但已经有一件事不对（脚本停用、系统代理没接管、残留错误）。
    case degraded
    /// 异常：红。引擎自己失败了。
    case failed

    public var isAlert: Bool { self == .degraded || self == .failed }
}

// MARK: - 速率

/// 一帧字节计数。`bytesIn` 是客户端→远端（上传），`bytesOut` 是远端→客户端（下载），
/// 与 `LiveTraffic` / `BytePump.Stats` 的命名一致。
public struct ResidentTrafficSample: Sendable, Equatable {
    public var bytesIn: Int
    public var bytesOut: Int
    public var at: Date
    public init(bytesIn: Int = 0, bytesOut: Int = 0, at: Date = Date()) {
        self.bytesIn = bytesIn; self.bytesOut = bytesOut; self.at = at
    }
}

public struct ResidentRates: Sendable, Equatable {
    public var down: Double
    public var up: Double
    public init(down: Double = 0, up: Double = 0) { self.down = down; self.up = up }
    public static let zero = ResidentRates()

    public var downText: String { ResidentFormat.rate(down) }
    public var upText: String { ResidentFormat.rate(up) }
    /// 「↓ 1.2 MB/s · ↑ 12 KB/s」——两个面共用这一行，所以数字不会各说各的。
    public var summary: String { "↓ \(downText) · ↑ \(upText)" }
}

/// 字节/秒的展示格式。与旧浮窗的写法保持完全一致，避免这次重构顺手改掉数字的样子。
public enum ResidentFormat {
    public static func rate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1 { return "0 B/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSecond
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return value < 10 ? String(format: "%.1f %@", value, units[index])
                          : String(format: "%.0f %@", value, units[index])
    }
}

/// 单帧差分的唯一实现。
///
/// `minimumInterval` 不是节流，是正确性：两个面（面板与浮窗）都会喂同一帧，
/// 若一帧刚落账、0.2 秒后又来一帧，按 0.2 秒去差分就会把同一段字节算两遍，
/// 速率瞬间翻倍。窗口不到一半就不采，窗口满了才用上一帧结算的基准算。
public struct ResidentRateMeter: Sendable, Equatable {
    public static let minimumInterval: TimeInterval = 0.5

    public private(set) var last: ResidentTrafficSample?
    public private(set) var rates: ResidentRates

    public init() { rates = .zero }

    @discardableResult
    public mutating func sample(_ next: ResidentTrafficSample) -> ResidentRates {
        guard let previous = last else {
            last = next
            return rates
        }
        let elapsed = next.at.timeIntervalSince(previous.at)
        guard elapsed >= Self.minimumInterval else { return rates }
        // 计数器在重启后会归零：负的增量不是负速率，是 0。
        let down = max(Double(next.bytesOut) - Double(previous.bytesOut), 0) / elapsed
        let up = max(Double(next.bytesIn) - Double(previous.bytesIn), 0) / elapsed
        last = next
        rates = ResidentRates(down: down, up: up)
        return rates
    }

    public mutating func reset() {
        last = nil
        rates = .zero
    }
}

// MARK: - 接管范围（PRODUCT-v4 §2.5）

public enum ResidentCoverageScope: String, Sendable, Equatable {
    /// 系统代理已接管：愿意走系统代理的进程会经过 Leapin。
    case systemProxy
    /// 什么都没接管：所有进程都绕过。
    case none
}

/// 接管范围的一行事实。这一行必须写进界面，不是免责声明。
public struct ResidentCoverage: Sendable, Equatable {
    public var scope: ResidentCoverageScope
    /// 已知会绕过的进程数；`nil` = 这一版检测不到，只说「部分」不编数字。
    public var uncoveredProcesses: Int?

    public init(scope: ResidentCoverageScope = .none, uncoveredProcesses: Int? = nil) {
        self.scope = scope
        self.uncoveredProcesses = uncoveredProcesses
    }

    public var isCoveringTraffic: Bool { scope == .systemProxy }

    public var declaration: String {
        guard scope == .systemProxy else { return "接管范围：未接管 · 所有进程都绕过" }
        guard let uncovered = uncoveredProcesses else {
            return "接管范围：系统代理 · 部分进程未覆盖"
        }
        return uncovered == 0
            ? "接管范围：系统代理 · 未检测到绕过进程"
            : "接管范围：系统代理 · 有 \(uncovered) 个进程未覆盖"
    }
}

// MARK: - 最近连接

public enum ResidentFlowKind: String, Sendable, Equatable {
    case blocked, direct, proxy, other
}

/// 浮窗「最近连接」的一行。标签与语义在这里定死，两个面就不会各写一套判断。
public struct ResidentFlowBrief: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var host: String
    public var label: String
    public var kind: ResidentFlowKind
    public init(id: UUID, host: String, label: String, kind: ResidentFlowKind) {
        self.id = id; self.host = host; self.label = label; self.kind = kind
    }

    public static func label(for flow: FlowEvent) -> String {
        if flow.blockedBy != nil { return "拦截" }
        return flow.policy.isEmpty ? "—" : flow.policy
    }

    public static func kind(for flow: FlowEvent) -> ResidentFlowKind {
        if flow.blockedBy != nil { return .blocked }
        switch flow.policy.lowercased() {
        case "direct": return .direct
        case "proxy", "global": return .proxy
        default: return .other
        }
    }

    /// 最新的在最上面。
    public static func briefs(from flows: [FlowEvent], limit: Int = 3) -> [ResidentFlowBrief] {
        flows.suffix(limit).reversed().map { flow in
            ResidentFlowBrief(id: flow.id, host: flow.host,
                              label: label(for: flow), kind: kind(for: flow))
        }
    }
}

// MARK: - 异常

public struct ResidentIssue: Identifiable, Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable {
        /// 引擎自己失败：红。
        case failure
        /// 还在跑，但有一件事不对：半红。
        case degraded
    }
    public var severity: Severity
    public var text: String
    public var id: String { severity.rawValue + "|" + text }
    public init(severity: Severity, text: String) {
        self.severity = severity; self.text = text
    }
}

// MARK: - 输入

/// 常驻层需要的全部输入，一次性说清。字段来自引擎，不从视图里补。
public struct ResidentStatusInput: Sendable {
    public var state: EngineState
    public var stats: EngineStats
    public var traffic: ResidentTrafficSample
    public var flows: [FlowEvent]
    public var coverage: ResidentCoverage
    public var profileName: String
    /// Mihomo 的 mode（rule / global / direct）；原生引擎为 nil。
    public var mode: String?
    public var exit: String?
    public var exitGroup: String?
    public var lastError: String?
    /// 脚本名 → 停用原因（`ScriptRuntime.disabledReasons`）。
    public var scriptIssues: [String: String]
    /// 正在建立的连接数（`engine.activeConnections`），不是累计值。
    public var activeConnections: Int

    public init(state: EngineState = .stopped, stats: EngineStats,
                traffic: ResidentTrafficSample = ResidentTrafficSample(),
                flows: [FlowEvent] = [], coverage: ResidentCoverage = ResidentCoverage(),
                profileName: String = "", mode: String? = nil, exit: String? = nil,
                exitGroup: String? = nil, lastError: String? = nil,
                scriptIssues: [String: String] = [:], activeConnections: Int = 0) {
        self.state = state; self.stats = stats; self.traffic = traffic; self.flows = flows
        self.coverage = coverage; self.profileName = profileName; self.mode = mode
        self.exit = exit; self.exitGroup = exitGroup; self.lastError = lastError
        self.scriptIssues = scriptIssues; self.activeConnections = activeConnections
    }
}

// MARK: - 输出

public struct ResidentStatus: Sendable, Equatable {
    public var tone: ResidentTone
    /// 「运行中 · 规则模式」/「代理未运行」/「代理出错」
    public var title: String
    /// 「海外 · GLOBAL › HK 01」
    public var subtitle: String
    public var stateLabel: String
    public var profileName: String
    public var exit: String?
    public var exitGroup: String?
    public var rates: ResidentRates
    public var blocked: Int
    public var connections: Int
    public var coverage: ResidentCoverage
    public var issues: [ResidentIssue]
    public var recent: [ResidentFlowBrief]

    /// 「异常」块唯一的渲染条件：没有错误也没有降级时它不出现，而不是出现一个空块。
    public var needsAttention: Bool { !issues.isEmpty }

    public init(tone: ResidentTone, title: String, subtitle: String, stateLabel: String,
                profileName: String, exit: String?, exitGroup: String? = nil, rates: ResidentRates,
                blocked: Int, connections: Int, coverage: ResidentCoverage, issues: [ResidentIssue],
                recent: [ResidentFlowBrief]) {
        self.tone = tone; self.title = title; self.subtitle = subtitle
        self.stateLabel = stateLabel; self.profileName = profileName; self.exit = exit
        self.exitGroup = exitGroup
        self.rates = rates; self.blocked = blocked; self.connections = connections
        self.coverage = coverage; self.issues = issues; self.recent = recent
    }

    public static let empty = ResidentStatus(tone: .idle, title: "", subtitle: "", stateLabel: "",
                                             profileName: "", exit: nil, rates: .zero, blocked: 0,
                                             connections: 0, coverage: ResidentCoverage(),
                                             issues: [], recent: [])

    /// 纯函数：输入 + 已算好的速率 → 常驻层要显示的那一份。
    public static func make(_ input: ResidentStatusInput, rates: ResidentRates) -> ResidentStatus {
        var issues: [ResidentIssue] = []

        switch input.state {
        case .failed(let message):
            issues.append(ResidentIssue(severity: .failure, text: message))
        default:
            if let error = input.lastError, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 还在跑却留着错误：流量在走，但有一件事不对——半红，不是红。
                issues.append(ResidentIssue(severity: input.state == .running ? .degraded : .failure,
                                            text: error))
            }
        }

        if !input.scriptIssues.isEmpty {
            issues.append(ResidentIssue(severity: .degraded, text: scriptSummary(input.scriptIssues)))
        }

        if input.state == .running, !input.coverage.isCoveringTraffic {
            issues.append(ResidentIssue(severity: .degraded,
                                        text: "系统代理未接管，所有进程都绕过 Leapin"))
        }

        let tone: ResidentTone
        if case .failed = input.state {
            tone = .failed
        } else if issues.contains(where: { $0.severity == .failure }) {
            tone = .failed
        } else if !issues.isEmpty {
            tone = .degraded
        } else if input.state == .running {
            tone = .normal
        } else {
            tone = .idle
        }

        let title: String
        switch input.state {
        case .stopped:
            title = "代理未运行"
        case .starting:
            title = "启动中"
        case .running:
            let flavor = input.mode.map { MenuBarKit.modeTitle($0) } ?? "规则分流"
            title = "运行中 · \(flavor)"
        case .failed:
            title = "代理出错"
        }

        let exitPath: String?
        if let exit = input.exit {
            exitPath = input.exitGroup.map { "\($0) › \(exit)" } ?? exit
        } else {
            exitPath = nil
        }
        let subtitle = input.state == .running
            ? "\(input.profileName) · \(exitPath ?? "没有可切换的节点")"
            : input.profileName

        return ResidentStatus(tone: tone, title: title, subtitle: subtitle,
                              stateLabel: input.state.label,
                              profileName: input.profileName, exit: input.exit,
                              exitGroup: input.exitGroup, rates: rates, blocked: input.stats.blocked,
                              connections: input.activeConnections,
                              coverage: input.coverage, issues: issues,
                              recent: ResidentFlowBrief.briefs(from: input.flows))
    }

    private static func scriptSummary(_ issues: [String: String]) -> String {
        let names = issues.keys.sorted()
        guard let first = names.first else { return "脚本降级" }
        guard names.count > 1 else { return "脚本降级：\(first) — \(issues[first] ?? "")" }
        return "脚本降级：\(names.count) 个脚本已停用（\(names.prefix(2).joined(separator: "、"))）"
    }
}

// MARK: - 唯一入口

/// 所有常驻面共用的容器。谁采样都行，差分只在这里发生一次。
///
/// 不持有定时器：面板打开期间自己按 1 Hz 喂帧，浮窗用它原有的 1 Hz ticker。
/// 这样关窗八小时里没有任何一个新对象在后台醒着（里程碑里那条 RSS 要求）。
@MainActor
public final class ResidentStatusStore: ObservableObject {
    public static let shared = ResidentStatusStore()

    @Published public private(set) var status: ResidentStatus

    private var meter = ResidentRateMeter()
    /// 出口只有一个面取得到（面板要等 `menuBarSnapshot()`）：记住它，浮窗不必再取一次。
    private var lastSnapshot: MenuBarSnapshot?

    public init(status: ResidentStatus = .empty) {
        self.status = status
    }

    /// 采一帧。两个面调多次也只差分一次——窗口没满时返回上一次的结果。
    @discardableResult
    public func update(_ input: ResidentStatusInput) -> ResidentStatus {
        var current = input
        if let snapshot = lastSnapshot {
            if current.mode == nil { current.mode = snapshot.mode }
            if current.exit == nil, current.exitGroup == nil {
                current.exit = snapshot.current
                current.exitGroup = snapshot.currentGroup
            }
        }
        let next = ResidentStatus.make(current, rates: meter.sample(current.traffic))
        if next != status { status = next }
        return next
    }

    /// 从引擎取全部输入。这里不传出口：出口来自最近一次快照。
    @discardableResult
    public func update(from engine: LeapinEngine,
                       snapshot: MenuBarSnapshot? = nil,
                       uncoveredProcesses: Int? = nil,
                       at now: Date = Date()) -> ResidentStatus {
        rememberExit(snapshot: snapshot)
        return update(engine.residentStatusInput(uncoveredProcesses: uncoveredProcesses, at: now))
    }

    /// 面板拿到快照后记下出口；`nil`（还没取到）不覆盖上一次的。
    public func rememberExit(snapshot: MenuBarSnapshot?) {
        guard let snapshot else { return }
        lastSnapshot = snapshot
    }

    public func reset() {
        meter.reset()
        lastSnapshot = nil
        status = .empty
    }
}

public extension LeapinEngine {
    /// 常驻层读引擎的唯一入口。视图不再自己拼这些字段。
    func residentStatusInput(uncoveredProcesses: Int? = nil, at now: Date = Date()) -> ResidentStatusInput {
        let live = liveTraffic
        return ResidentStatusInput(
            state: state,
            stats: stats,
            traffic: ResidentTrafficSample(bytesIn: live.bytesIn, bytesOut: live.bytesOut, at: now),
            flows: flows,
            coverage: ResidentCoverage(scope: systemProxyActive ? .systemProxy : .none,
                                       uncoveredProcesses: uncoveredProcesses),
            profileName: profile.name,
            mode: nil,
            exit: nil,
            exitGroup: nil,
            lastError: lastError,
            scriptIssues: scriptBox?.current?.disabledReasons ?? [:],
            activeConnections: activeConnections)
    }
}

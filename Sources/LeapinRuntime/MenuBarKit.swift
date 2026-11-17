import Foundation
import Combine
import LeapinCore
import LeapinControl
import LeapinIntegrations

/// Latency band a row is painted in. Shared by the menu bar and the node list so
/// one number never means two colours.
public enum LatencyTone: String, Sendable, Equatable {
    case fast, ok, slow, failed, unknown

    public static func of(_ latencyMs: Int?, failed: Bool = false) -> LatencyTone {
        guard let latencyMs else { return failed ? .failed : .unknown }
        if latencyMs < 200 { return .fast }
        if latencyMs <= 800 { return .ok }
        return .slow
    }
}

public struct MenuBarNode: Identifiable, Sendable, Equatable {
    public var name: String
    public var latencyMs: Int?
    public var failed: Bool
    public var dialable: Bool
    public var id: String { name }
    public init(name: String, latencyMs: Int? = nil, failed: Bool = false, dialable: Bool = true) {
        self.name = name; self.latencyMs = latencyMs; self.failed = failed; self.dialable = dialable
    }
    public var tone: LatencyTone { .of(latencyMs, failed: failed) }
}

public struct MenuBarGroup: Identifiable, Sendable, Equatable {
    public var name: String
    public var type: String
    public var selected: String
    public var members: [MenuBarNode]
    /// Only a Selector can be switched by hand; url-test / fallback pick themselves.
    public var selectable: Bool
    public var id: String { name }
    public init(name: String, type: String, selected: String, members: [MenuBarNode], selectable: Bool) {
        self.name = name; self.type = type; self.selected = selected
        self.members = members; self.selectable = selectable
    }
}

public struct MenuBarProfile: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var kernel: ExecutionKernel
    public init(id: UUID, name: String, kernel: ExecutionKernel) {
        self.id = id; self.name = name; self.kernel = kernel
    }
}

public struct MenuBarSnapshot: Sendable, Equatable {
    public var kernel: ExecutionKernel
    public var running: Bool
    public var mode: String?
    public var groups: [MenuBarGroup]
    public var current: String?
    public var currentGroup: String?
    public var currentLatencyMs: Int?
    public var profiles: [MenuBarProfile]
    public var activeProfile: UUID?
    public var note: String?
    public init(kernel: ExecutionKernel, running: Bool, mode: String? = nil,
                groups: [MenuBarGroup] = [], current: String? = nil, currentGroup: String? = nil,
                currentLatencyMs: Int? = nil, profiles: [MenuBarProfile] = [],
                activeProfile: UUID? = nil, note: String? = nil) {
        self.kernel = kernel; self.running = running; self.mode = mode
        self.groups = groups; self.current = current; self.currentGroup = currentGroup
        self.currentLatencyMs = currentLatencyMs; self.profiles = profiles
        self.activeProfile = activeProfile; self.note = note
    }

    /// Groups a user may switch, in kernel order.
    public var switchableGroups: [MenuBarGroup] { groups.filter(\.selectable) }

    /// The groups worth showing in the node menu. Outside global mode GLOBAL is
    /// not what traffic uses, so listing it twice only makes the pick ambiguous.
    public var nodeMenuGroups: [MenuBarGroup] {
        let selectors = switchableGroups
        guard mode?.lowercased() != "global" else { return selectors }
        let named = selectors.filter { $0.name.uppercased() != "GLOBAL" }
        return named.isEmpty ? selectors : named
    }
}

public struct MenuBarBest: Sendable, Equatable {
    public var name: String
    public var latencyMs: Int
    public init(name: String, latencyMs: Int) { self.name = name; self.latencyMs = latencyMs }
}

/// What the menu bar keeps after a test: the number on the icon and the fastest
/// node found, so a finished test is still visible after the panel closes.
@MainActor
public final class MenuBarStatus: ObservableObject {
    public static let shared = MenuBarStatus()

    /// Latency of the node in use, from the last quick test.
    @Published public var current: MenuBarTestOutcome?
    /// Fastest node from the last full test.
    @Published public var best: MenuBarBest?
    /// Nodes still to test; 0 when nothing is running.
    @Published public var pending: Int = 0

    public init() {}

    /// "87" — the number drawn beside the shield. Nil when nothing is measured yet.
    public var badge: String? {
        if pending > 0 { return nil }
        if let latency = current?.latencyMs { return String(latency) }
        if let latency = best?.latencyMs { return String(latency) }
        return nil
    }

    public func reset() {
        current = nil; best = nil; pending = 0
    }
}

public struct MenuBarTestOutcome: Sendable, Equatable {
    public var name: String?
    public var latencyMs: Int?
    public var error: String?
    public init(name: String? = nil, latencyMs: Int? = nil, error: String? = nil) {
        self.name = name; self.latencyMs = latencyMs; self.error = error
    }
}

public struct MenuBarTestSummary: Sendable, Equatable {
    public var tested: Int
    public var failed: Int
    public var best: MenuBarBest?
    public var error: String?
    public init(tested: Int = 0, failed: Int = 0, best: MenuBarBest? = nil, error: String? = nil) {
        self.tested = tested; self.failed = failed; self.best = best; self.error = error
    }
}

/// Everything the menu bar derives without touching the UI: sorting, labels,
/// filtering and "which node is fastest" all live here so they can be tested.
public enum MenuBarKit {
    /// One URL for every surface's latency test. Plain HTTP on purpose: the number
    /// should measure the node, not a TLS handshake.
    public static let testURL = "http://www.gstatic.com/generate_204"

    public static func latencyText(_ latencyMs: Int?, failed: Bool = false) -> String {
        if let latencyMs { return "\(latencyMs) ms" }
        return failed ? "失败" : "未测"
    }

    public static func best(in nodes: [MenuBarNode]) -> MenuBarBest? {
        var winner: MenuBarBest?
        for node in nodes where node.dialable {
            guard let latency = node.latencyMs, latency > 0 else { continue }
            if winner == nil || latency < winner!.latencyMs {
                winner = MenuBarBest(name: node.name, latencyMs: latency)
            }
        }
        return winner
    }

    /// Case- and diacritic-insensitive, so "hk" still finds "🇭🇰 香港".
    public static func matches(_ name: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    public static func filtered(_ group: MenuBarGroup, query: String) -> MenuBarGroup {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return group }
        var copy = group
        copy.members = group.members.filter { matches($0.name, query: query) }
        return copy
    }

    static func menuNode(from node: ControlNode) -> MenuBarNode {
        MenuBarNode(name: node.name, latencyMs: node.latencyMs,
                    failed: node.checkedAtMs != nil && node.latencyMs == nil,
                    dialable: node.dialable)
    }

    /// "PROXY › 🇭🇰香港 01 · 87 ms", or the reason there is nothing to show.
    public static func summary(_ snapshot: MenuBarSnapshot) -> String {
        guard snapshot.running else { return "代理未运行" }
        guard let current = snapshot.current else { return snapshot.note ?? "没有可切换的节点" }
        let group = snapshot.currentGroup.map { "\($0) › " } ?? ""
        let latency = snapshot.currentLatencyMs.map { " · \($0) ms" } ?? ""
        return group + current + latency
    }

    /// The group the last MATCH / FINAL rule hands traffic to. In rule mode this
    /// is what "the node in use" means; GLOBAL is only the truth in global mode.
    public static func finalPolicy(in clash: String) -> String? {
        var policy: String?
        for raw in clash.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("-") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if let comment = line.firstIndex(of: "#") {
                line = String(line[..<comment]).trimmingCharacters(in: .whitespaces)
            }
            let upper = line.uppercased()
            guard upper.hasPrefix("MATCH,") || upper.hasPrefix("FINAL,") else { continue }
            let parts = line.split(separator: ",").map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
            if let last = parts.last, !["MATCH", "FINAL"].contains(last.uppercased()) { policy = last }
        }
        return policy
    }

    /// Kernel mode in words for the panel header.
    public static func modeTitle(_ mode: String?) -> String {
        switch mode?.lowercased() {
        case "global": return "全局模式"
        case "direct": return "直连模式"
        case "rule": return "规则模式"
        default: return "内核模式"
        }
    }
}

public extension LeapinEngine {
    /// One glance at what the menu bar needs: nodes, groups, the node in use.
    func menuBarSnapshot() async -> MenuBarSnapshot {
        let profiles = store.list().map { meta in
            MenuBarProfile(id: meta.id, name: meta.name,
                           kernel: (try? store.kernelSource(for: meta.id))?.kernel ?? .native)
        }
        var snapshot = MenuBarSnapshot(kernel: executionKernel, running: state == .running,
                                       profiles: profiles, activeProfile: store.activeProfileID)

        if executionKernel == .mihomo {
            guard managedKernel.running else {
                snapshot.note = "Mihomo 内核未运行"
                return snapshot
            }
            let proxies = (try? await managedKernel.proxies()) ?? []
            guard !proxies.isEmpty else {
                snapshot.note = "内核还没有返回策略组"
                return snapshot
            }
            let nodes = Self.mergeKernelNodes(proxies: proxies, profile: profile, health: LPHealth.shared.snapshot())
            let byName = Dictionary(nodes.map { ($0.name, MenuBarKit.menuNode(from: $0)) }) { first, _ in first }
            snapshot.mode = await managedKernel.mode()
            snapshot.groups = proxies.filter { $0.isGroup }.map { group in
                MenuBarGroup(name: group.name, type: group.type, selected: group.selected ?? "",
                             members: group.members.map { name in
                                 byName[name] ?? MenuBarNode(name: name, dialable: false)
                             },
                             selectable: group.isSelectable)
            }
            let global = snapshot.groups.first { $0.name.uppercased() == "GLOBAL" }
            let selectors = snapshot.groups.filter { $0.selectable }
            let source = try? store.kernelSource(for: profile.id)
            let finalPolicy = source.flatMap { MenuBarKit.finalPolicy(in: $0.clash) }
            let named = finalPolicy.flatMap { policy in selectors.first { $0.name == policy } }
            let primary: MenuBarGroup?
            if snapshot.mode?.lowercased() == "global" {
                primary = global ?? selectors.first
            } else {
                primary = named ?? selectors.first { $0.name.uppercased() != "GLOBAL" } ?? global ?? snapshot.groups.first
            }
            snapshot.currentGroup = primary?.name
            snapshot.current = primary?.selected.isEmpty == false ? primary?.selected : nil
            snapshot.currentLatencyMs = snapshot.current.flatMap { byName[$0]?.latencyMs }
            if snapshot.groups.isEmpty { snapshot.note = "内核没有暴露策略组，请在配置里保留 proxy-groups" }
            return snapshot
        }

        let nodes = await controlNodes()
        let byName = Dictionary(nodes.map { ($0.name, MenuBarKit.menuNode(from: $0)) }) { first, _ in first }
        snapshot.groups = profile.groups.map { group in
            let effective = effectiveMember(group: group.name) ?? group.selected ?? ""
            return MenuBarGroup(name: group.name, type: group.type.rawValue, selected: effective,
                                members: group.proxies.map { name in
                                    byName[name] ?? MenuBarNode(name: name, dialable: false)
                                },
                                selectable: group.type == .select)
        }
        let primary = snapshot.groups.first { $0.selectable } ?? snapshot.groups.first
        snapshot.currentGroup = primary?.name
        snapshot.current = primary?.selected
        snapshot.currentLatencyMs = snapshot.current.flatMap { byName[$0]?.latencyMs }
        if snapshot.groups.isEmpty { snapshot.note = "这份配置没有策略组" }
        return snapshot
    }

    /// Test the node traffic is using right now. Empty outcome means "nothing to test".
    func menuBarQuickTest() async -> MenuBarTestOutcome {
        let snapshot = await menuBarSnapshot()
        guard snapshot.running else { return MenuBarTestOutcome(error: "代理未运行") }
        guard let current = snapshot.current else { return MenuBarTestOutcome(error: "当前没有选中的节点") }
        do {
            let results = try await controlTestNodes(names: [current])
            let result = results.first
            return MenuBarTestOutcome(name: result?.name ?? current, latencyMs: result?.latencyMs,
                                      error: result?.error)
        } catch {
            return MenuBarTestOutcome(name: current, error: error.localizedDescription)
        }
    }

    /// Every dialable node, then the fastest one. Progress is (done, total).
    func menuBarTestAll(onProgress: ((Int, Int) -> Void)? = nil) async -> MenuBarTestSummary {
        guard state == .running else { return MenuBarTestSummary(error: "代理未运行") }
        do {
            let results = try await controlTestNodes(names: [], onProgress: onProgress)
            var summary = MenuBarTestSummary(tested: results.count)
            var nodes: [MenuBarNode] = []
            for result in results {
                if result.latencyMs == nil { summary.failed += 1 }
                nodes.append(MenuBarNode(name: result.name, latencyMs: result.latencyMs,
                                         failed: result.latencyMs == nil))
            }
            summary.best = MenuBarKit.best(in: nodes)
            return summary
        } catch {
            return MenuBarTestSummary(error: error.localizedDescription)
        }
    }

    /// Switch one policy group. Mihomo mode goes through the kernel's own selection
    /// API and persists it, so a restart keeps the pick.
    func menuBarSelect(group: String, member: String) async throws {
        guard !configurationBusy else {
            throw LeapinError.invalidConfiguration("正在切换配置，请稍后再选择线路")
        }
        if executionKernel == .mihomo {
            try await selectManagedPolicy(group: group, member: member, persist: true)
        } else {
            selectOutbound(group: group, outbound: member)
        }
    }

    /// Switch subscription ("机场") from the menu bar. Same path as the profiles page.
    func menuBarSwitch(profile id: UUID) async {
        guard id != store.activeProfileID || state != .running else { return }
        await activate(id)
    }
}

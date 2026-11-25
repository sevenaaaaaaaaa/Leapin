import SwiftUI
import LeapinControl

/// 首页：这台手机的网络（v5 构图）。
///
/// 页头 28 → 墨色焦点带（一条路 + 四事实 + 一个主操作）→ 证据区两块。
/// 三问的顺序不变：引擎开没开、系统用没用上、Mac 在不在线。
struct DashboardView: View {
    @Environment(ConsoleStore.self) private var store
    private var local: LocalProxyEngine { .shared }
    @State private var showSettings = false
    @State private var showGuide = false
    @State private var reloadSummary: String?
    @State private var isReloading = false

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LEAPIN_MOBILE_GUIDE"] == "1" {
            _showGuide = State(initialValue: true)
        }
        #endif
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    LPPageHeader(title: "这台手机的网络", status: statusLine)
                    focusBand
                    engineSection
                    macSection
                    footerNote
                }
                .padding(.horizontal, LP.gutter)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            .background(LP.canvas)
            .contentMargins(.bottom, 120, for: .scrollContent)
            .refreshable { await store.refresh() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showGuide) { LocalProxyGuide() }
        }
    }

    // MARK: - 页头一句

    private var statusLine: String {
        guard local.isRunning else { return "本机引擎未启动" }
        return "引擎运行中 · 127.0.0.1:\(local.port) · 全部直连"
    }

    // MARK: - 焦点带

    private var focusBand: some View {
        FocusBand(eyebrow: "现在") {
            RouteLine(nodes: ["你", "本机引擎", "直连"], current: 1, onInk: true)

            HStack(alignment: .top, spacing: 10) {
                LPFact(label: "连接", value: String(local.activeConnections))
                LPFact(label: "下行", value: LPFormat.bytes(Int64(local.totalBytesIn)))
                LPFact(label: "上行", value: LPFormat.bytes(Int64(local.totalBytesOut)))
                LPFact(label: "系统代理", value: usageLabel, mono: false)
            }

            Button { showGuide = true } label: {
                Text("把这台手机的 Wi-Fi 代理指过来")
            }
            .buttonStyle(OnInkButtonStyle())
        }
    }

    // MARK: - 证据区一：本机引擎与系统使用

    private var engineSection: some View {
        LPSection(header: "本机引擎",
                  footer: local.lastError ?? "引擎在这台手机里跑；不连 Mac 也用它。") {
            LPListRow(title: "系统代理", subtitle: usageSubtitle, isLast: false) {
                Button(local.isChecking ? "…" : "自检") {
                    Task { await local.selfCheck() }
                }
                .font(.system(size: 15))
                .foregroundStyle(LP.accent)
                .buttonStyle(.plain)
                .disabled(!local.isRunning || local.isChecking)
            }
            LPListRow(title: local.isRunning ? "正在监听" : "已停止",
                      value: local.isRunning ? "127.0.0.1:\(local.port)" : nil,
                      mono: local.isRunning,
                      isLast: true) {
                Toggle("", isOn: Binding(
                    get: { local.isRunning },
                    set: { on in if on { local.start() } else { local.stop() } }
                ))
                .labelsHidden()
                .tint(LP.accent)
            }
        }
    }

    // MARK: - 证据区二：Mac

    @ViewBuilder
    private var macSection: some View {
        if let endpoint = store.endpoint {
            LPSection(header: "Mac",
                      footer: store.lastError ?? store.lastUpdated.map { "更新于 \(LPFormat.timeAgo($0))" }) {
                LPListRow(title: stateTitle(store.status?.engineState ?? "unknown"),
                          subtitle: subtitle(store.status?.engineState ?? "unknown"),
                          value: endpoint.displayAddress,
                          mono: true)
                LPListRow(title: "规则", value: String(store.status?.ruleCount ?? 0), mono: true)
                LPListRow(title: "混合代理", value: String(store.status?.mixedPort ?? 0), mono: true)
                LPListRow(title: "重载规则", subtitle: reloadSummary, isLast: true) {
                    if isReloading {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button("重载") {
                            Task {
                                isReloading = true
                                let result = await store.reloadRules()
                                isReloading = false
                                if let result {
                                    reloadSummary = "已重载 \(result.ruleCount) 条规则（\(result.applied.count) 项生效）"
                                }
                            }
                        }
                        .font(.system(size: 15))
                        .foregroundStyle(LP.accent)
                        .buttonStyle(.plain)
                    }
                }
            }
        } else {
            LPSection(header: "Mac",
                      footer: "未配对时本机引擎与工具照常可用；配对后这里显示 Mac 的规则与出口。") {
                LPListRow(title: "未连接 Mac", subtitle: "本机引擎不依赖它", isLast: true) {
                    Button("配对") { store.pairingSheetShown = true }
                        .font(.system(size: 15))
                        .foregroundStyle(LP.accent)
                        .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 页脚

    private var footerNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 10))
            Text(store.lastUpdated.map { "Mac 更新于 \(LPFormat.timeAgo($0))" } ?? "尚未连过 Mac")
                .font(.system(size: 11))
        }
        .foregroundStyle(LP.textTertiary)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - 文案

    private var usageLabel: String {
        guard local.isRunning else { return "未设置" }
        guard let check = local.lastCheck else { return "未验证" }
        return check.contains("收到 HTTP") ? "已验证" : "未通过"
    }

    private var usageSubtitle: String? {
        guard local.isRunning else { return "引擎未启动，系统代理无从指向" }
        if let check = local.lastCheck { return usageLabel + " · " + check }
        return "填 127.0.0.1:\(local.port) 后点右边的自检"
    }

    private func stateTitle(_ state: String) -> String {
        switch state.lowercased() {
        case "running": return "正在保护"
        case "starting": return "正在启动"
        case "stopping": return "正在停止"
        case "failed": return "启动失败"
        case "stopped": return "已停止"
        default: return "未知状态"
        }
    }

    private func subtitle(_ state: String) -> String {
        switch state.lowercased() {
        case "running": return "代理与规则引擎均已就绪"
        case "starting": return "监听端口准备中"
        case "stopping": return "正在收尾"
        case "failed": return "查看日志定位原因"
        case "stopped": return "代理未运行"
        default: return "还没有收到状态"
        }
    }
}

/// ink 底上的主按钮：纸色底、墨色字。一屏只有一个。
struct OnInkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LPFont.body.weight(.semibold))
            .foregroundStyle(LP.ink)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous)
                    .fill(LP.onInk.opacity(configuration.isPressed ? 0.82 : 1))
            )
    }
}

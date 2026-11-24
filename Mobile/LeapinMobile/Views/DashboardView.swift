import SwiftUI
import LeapinControl

/// 首页：这台手机的网络。
///
/// 三块按顺序回答三问——本机引擎开没开、有没有被系统使用、Mac 在不在线。
/// 未配对时三块仍显示本机真实数据：配对是次动作，不是首页的前提。
/// 依据 docs/PRODUCT-v4.md §4 M3 DoD 1–2。
struct DashboardView: View {
    @Environment(ConsoleStore.self) private var store
    private var local: LocalProxyEngine { .shared }
    @State private var showSettings = false
    @State private var showGuide = false
    @State private var reloadSummary: String?
    @State private var isReloading = false

    init() {
        #if DEBUG
        // QA hook: LEAPIN_MOBILE_GUIDE=1 opens the Wi-Fi proxy guide for screenshots,
        // the same way LEAPIN_MOBILE_TAB picks a tab.
        if ProcessInfo.processInfo.environment["LEAPIN_MOBILE_GUIDE"] == "1" {
            _showGuide = State(initialValue: true)
        }
        #endif
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    localSection
                    systemUsageSection
                    macSection
                    footerNote
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(LP.groupedBackground)
            .contentMargins(.bottom, 120, for: .scrollContent)
            .refreshable { await store.refresh() }
            .navigationTitle("这台手机的网络")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showGuide) {
                LocalProxyGuide()
            }
        }
    }

    // MARK: - 一 / 本机引擎

    private var localSection: some View {
        LPSection(header: "本机引擎",
                  footer: local.lastError
                    ?? (local.isRunning ? "这台手机自己跑代理；不连 Mac 也用它。" : "打开后手机自己分流，不需要 Mac。")) {
            LPListRow(title: "状态",
                      subtitle: local.isRunning ? "正在监听" : "未启动",
                      value: local.isRunning ? "运行中" : "已停止", isLast: false) {
                Toggle("", isOn: Binding(
                    get: { local.isRunning },
                    set: { on in if on { local.start() } else { local.stop() } }
                ))
                .labelsHidden()
                .tint(LP.accent)
            }
            LPListRow(title: "地址",
                      value: local.isRunning ? "127.0.0.1:" + String(local.port) : "—",
                      mono: true)
            LPListRow(title: "连接", value: String(local.activeConnections), mono: true)
            LPListRow(title: "流量",
                      value: "↓ " + LPFormat.bytes(Int64(local.totalBytesIn)) + " · ↑ " + LPFormat.bytes(Int64(local.totalBytesOut)),
                      mono: true,
                      isLast: true) { EmptyView() }
        }
    }

    // MARK: - 二 / 系统使用

    private var systemUsageSection: some View {
        LPSection(header: "系统使用",
                  footer: "iOS 不会自动把流量交给 App。要生效，在「设置 → 无线局域网 → 当前网络 ⓘ → 配置代理 → 手动」里填上面这个地址。") {
            LPListRow(title: "系统代理",
                      subtitle: usageSubtitle,
                      isLast: false) {
                Button(local.isChecking ? "…" : "自检") {
                    Task { await local.selfCheck() }
                }
                .font(.system(size: 15))
                .foregroundStyle(LP.accent)
                .buttonStyle(.plain)
                .disabled(!local.isRunning || local.isChecking)
            }
            LPListRow(title: "把这台手机的 Wi-Fi 代理指过来",
                      subtitle: "127.0.0.1:" + String(local.port == 0 ? LocalProxyEngine.defaultPort : local.port),
                      showsChevron: true,
                      isLast: true) { EmptyView() }
                .contentShape(Rectangle())
                .onTapGesture { showGuide = true }
        }
    }

    private var usageLabel: String {
        guard local.isRunning else { return "未设置" }
        guard let check = local.lastCheck else { return "未验证" }
        return check.contains("收到 HTTP") ? "已验证" : "未通过"
    }

    /// 一句里同时给结论与证据：结论在前，自检原文在后。
    private var usageSubtitle: String? {
        guard local.isRunning else { return "引擎未启动，系统代理无从指向" }
        if let check = local.lastCheck {
            return usageLabel + " · " + check
        }
        return "填 127.0.0.1:" + String(local.port) + " 后点右边的自检"
    }

    // MARK: - 三 / Mac

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
                LPListRow(title: "去广告规则", value: String(store.status?.adblockRuleCount ?? 0), mono: true)
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
                                    reloadSummary = "已重载 \(result.ruleCount) 条规则（\(result.applied.count) 项生效，用时 \(LPFormat.milliseconds(result.elapsedMs))）"
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
                LPListRow(title: "未连接 Mac",
                          subtitle: "本机引擎不依赖它",
                          isLast: true) {
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

    // MARK: - Copy

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

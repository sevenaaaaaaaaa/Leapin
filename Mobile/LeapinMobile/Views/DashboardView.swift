import SwiftUI
import LeapinControl

/// 总览 in the shape iOS uses for a dashboard: one large title, inset groups,
/// numbers aligned right, and a single action per group.
struct DashboardView: View {
    @Environment(ConsoleStore.self) private var store
    private var local: LocalProxyEngine { .shared }
    @State private var showSettings = false
    @State private var reloadSummary: String?
    @State private var isReloading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    localSection
                    macSection
                    portsSection
                    actionsSection
                    footerNote
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(LP.groupedBackground)
            .contentMargins(.bottom, 84, for: .scrollContent)
            .refreshable { await store.refresh() }
            .navigationTitle("总览")
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
        }
    }

    // MARK: - Sections

    private var localSection: some View {
        LPSection(header: "本机引擎",
                  footer: local.lastCheck ?? (local.isRunning ? nil : "打开后手机自己分流，不需要 Mac。")) {
            LPListRow(title: "状态",
                      subtitle: local.isRunning ? "127.0.0.1:" + String(local.port) : nil,
                      value: local.isRunning ? "运行中" : "未启动", isLast: false) {
                Toggle("", isOn: Binding(
                    get: { local.isRunning },
                    set: { on in if on { local.start() } else { local.stop() } }
                ))
                .labelsHidden()
                .tint(LP.accent)
            }
            LPListRow(title: "连接", value: String(local.activeConnections), mono: true)
            LPListRow(title: "下行", value: LPFormat.bytes(Int64(local.totalBytesIn)), mono: true)
            LPListRow(title: "上行", value: LPFormat.bytes(Int64(local.totalBytesOut)), mono: true, isLast: !local.isRunning) {
                if local.isRunning {
                    Button(local.isChecking ? "…" : "自检") {
                        Task { await local.selfCheck() }
                    }
                    .font(.system(size: 15))
                    .foregroundStyle(LP.accent)
                    .buttonStyle(.plain)
                    .disabled(local.isChecking)
                }
            }
        }
    }

    private var macSection: some View {
        let state = store.status?.engineState ?? "unknown"
        return LPSection(header: "Mac", footer: local.lastError ?? nil) {
            LPListRow(title: stateTitle(state),
                      subtitle: subtitle(state),
                      value: store.endpoint?.displayAddress ?? "未连接",
                      mono: store.endpoint != nil, showsChevron: store.endpoint == nil, isLast: false)
            LPListRow(title: "规则", value: String(store.status?.ruleCount ?? 0), mono: true)
            LPListRow(title: "已运行", value: LPFormat.duration(store.status?.uptimeSeconds ?? 0))
            LPListRow(title: "去广告规则", value: String(store.status?.adblockRuleCount ?? 0), mono: true, isLast: true)
        }
    }

    private var portsSection: some View {
        LPSection(header: "监听端口", footer: "Mac 上的代理入口") {
            LPListRow(title: "混合代理", value: String(store.status?.mixedPort ?? 0), mono: true)
            LPListRow(title: "HTTP", value: String(store.status?.httpPort ?? 0), mono: true)
            LPListRow(title: "SOCKS5", value: String(store.status?.socksPort ?? 0), mono: true)
            LPListRow(title: "控制面", value: String(store.status?.controlPort ?? 0), mono: true)
            LPListRow(title: "系统代理", value: (store.status?.systemProxyActive ?? false) ? "已开启" : "未开启", isLast: true)
        }
    }

    private var actionsSection: some View {
        LPSection(header: "操作", footer: reloadSummary) {
            LPListRow(title: "重载规则", isLast: true) {
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
                    .disabled(store.endpoint == nil)
                }
            }
        }
    }

    private var footerNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 10))
            Text(store.lastUpdated.map { "更新于 \(LPFormat.timeAgo($0))" } ?? "尚未刷新")
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

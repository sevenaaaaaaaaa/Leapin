import SwiftUI
import LeapinControl

struct DashboardView: View {
    @Environment(ConsoleStore.self) private var store
    @State private var showSettings = false
    @State private var reloadSummary: String?
    @State private var isReloading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    stateCard
                    metricsGrid
                    portsCard
                    actionsCard
                    footerNote
                }
                .lpPage()
            }
            .background(LP.canvas)
            .refreshable { await store.refresh() }
            .navigationTitle("总览")
            .navigationBarTitleDisplayMode(.inline)
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

    private var stateCard: some View {
        let state = store.status?.engineState ?? "unknown"
        return LPCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(stateTint(state).opacity(0.14))
                            .frame(width: 44, height: 44)
                        Circle()
                            .fill(stateTint(state))
                            .frame(width: 9, height: 9)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(stateTitle(state))
                                .font(LPFont.display(17, weight: .semibold))
                                .foregroundStyle(LP.text)
                            LPPill(text: state, tint: stateTint(state))
                        }
                        Text(subtitle(state))
                            .font(LPFont.caption)
                            .foregroundStyle(LP.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                Divider().overlay(LP.stroke)
                LPRow(key: "Mac", value: store.endpoint?.displayAddress ?? "未连接", mono: true)
            }
        }
    }

    private var metricsGrid: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                LPCard {
                    LPStat(label: "活动连接", value: "\(store.status?.activeConnections ?? 0)",
                           tint: store.status?.activeConnections == 0 ? LP.text : LP.accent)
                }
                LPCard {
                    LPStat(label: "规则", value: "\(store.status?.ruleCount ?? 0)")
                }
            }
            HStack(spacing: 12) {
                LPCard {
                    LPStat(label: "已运行", value: LPFormat.duration(store.status?.uptimeSeconds ?? 0))
                }
                LPCard {
                    LPStat(label: "去广告规则", value: "\(store.status?.adblockRuleCount ?? 0)")
                }
            }
        }
    }

    private var portsCard: some View {
        LPCard(title: "监听端口", subtitle: "本机代理入口") {
            VStack(spacing: 7) {
                LPRow(key: "混合代理", value: "\(store.status?.mixedPort ?? 0)", mono: true)
                LPRow(key: "HTTP", value: "\(store.status?.httpPort ?? 0)", mono: true)
                LPRow(key: "SOCKS5", value: "\(store.status?.socksPort ?? 0)", mono: true)
                LPRow(key: "控制面", value: "\(store.status?.controlPort ?? 0)", mono: true)
                LPRow(key: "系统代理", value: (store.status?.systemProxyActive ?? false) ? "已开启" : "未开启")
            }
        }
    }

    private var actionsCard: some View {
        LPCard(title: "操作") {
            VStack(spacing: 10) {
                Button {
                    Task {
                        isReloading = true
                        let result = await store.reloadRules()
                        isReloading = false
                        if let result {
                            reloadSummary = "已重载 \(result.ruleCount) 条规则（\(result.applied.count) 项生效，用时 \(LPFormat.milliseconds(result.elapsedMs))）"
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isReloading { ProgressView().tint(.white).scaleEffect(0.8) }
                        Text(isReloading ? "正在重载…" : "重载规则")
                    }
                }
                .buttonStyle(LPButtonStyle())
                .disabled(isReloading)

                if let reloadSummary {
                    Text(reloadSummary)
                        .font(LPFont.micro)
                        .foregroundStyle(LP.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var footerNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 10))
            Text("更新于 \(LPFormat.timeAgo(store.lastUpdated))")
                .font(LPFont.micro)
            if store.isRefreshing {
                ProgressView().scaleEffect(0.6)
            }
        }
        .foregroundStyle(LP.textTertiary)
        .padding(.horizontal, 2)
    }

    private func stateTitle(_ state: String) -> String {
        switch state {
        case "running": return "正在保护"
        case "starting": return "正在启动"
        case "stopped": return "已停止"
        case "failed": return "启动失败"
        default: return "未知状态"
        }
    }

    private func subtitle(_ state: String) -> String {
        switch state {
        case "running": return "代理与规则引擎均已就绪"
        case "starting": return "内核正在初始化，稍候"
        case "stopped": return "在 Mac 上点「连接网络」即可开始"
        case "failed": return "请回到 Mac 查看错误详情"
        default: return "还没有收到状态"
        }
    }

    private func stateTint(_ state: String) -> Color {
        switch state {
        case "running": return LP.mint
        case "starting": return LP.amber
        case "failed": return LP.danger
        default: return LP.textTertiary
        }
    }
}

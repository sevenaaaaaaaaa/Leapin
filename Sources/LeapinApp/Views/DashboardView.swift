import SwiftUI
import Combine
import LeapinCore
import LeapinRuntime

/// A deliberately low-frequency snapshot of the engine: state, active profile and
/// configuration flags only. It never subscribes to flows or stats, so the
/// overview does not re-render on every connection.
@MainActor
private final class OverviewModel: ObservableObject {
    @Published var state: EngineState
    @Published var profile: Profile
    @Published var systemProxyActive: Bool

    private var cancellables = Set<AnyCancellable>()

    init() {
        let engine = LeapinEngine.shared
        state = engine.state
        profile = engine.profile
        systemProxyActive = engine.systemProxyActive

        engine.$state.receive(on: RunLoop.main).sink { [weak self] value in
            Task { @MainActor in self?.state = value }
        }.store(in: &cancellables)
        engine.$profile.receive(on: RunLoop.main).sink { [weak self] value in
            Task { @MainActor in self?.profile = value }
        }.store(in: &cancellables)
        engine.$systemProxyActive.receive(on: RunLoop.main).sink { [weak self] value in
            Task { @MainActor in self?.systemProxyActive = value }
        }.store(in: &cancellables)
    }
}

/// The overview is an index, not a live instrument: state, configuration and
/// entrances to the tools people use most. Live connections and traffic moved
/// to the Capture page's Observation sheet.
///
/// Hierarchy: one primary card (routing, with the policy rail), two secondary
/// cards (ad blocking, capture), and a compact index of the remaining tools.
@MainActor
struct DashboardView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.lpWindowWidth) private var windowWidth
    @StateObject private var model = OverviewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                statusBand

                if windowWidth >= 1100 {
                    HStack(alignment: .top, spacing: 24) {
                        mainColumn.frame(maxWidth: .infinity)
                        sideColumn.frame(width: 300)
                    }
                } else {
                    VStack(spacing: 24) {
                        mainColumn
                        sideColumn
                    }
                }
            }
            .pagePadding()
            .navigationTitle("总览")
        }
    }

    // MARK: - Status

    private var statusBand: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                LPEyebrow("当前配置")

                Text(model.profile.name)
                    .font(LPFont.display(30, weight: .semibold))
                    .tracking(-0.8)
                    .foregroundStyle(LP.text)
                    .lineLimit(1)

                Text(statusLine)
                    .font(.system(size: 14))
                    .foregroundStyle(LP.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(model.state.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LP.textSecondary)
                    Text("·").font(.system(size: 12)).foregroundStyle(LP.textTertiary)
                    Text(model.systemProxyActive ? "系统代理 开" : "系统代理 关")
                        .font(.system(size: 12))
                        .foregroundStyle(LP.textTertiary)
                    Text("·").font(.system(size: 12)).foregroundStyle(LP.textTertiary)
                    Text("127.0.0.1:\(model.profile.general.mixedPort)")
                        .font(LPFont.mono(12))
                        .foregroundStyle(LP.textTertiary)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 12) {
                Button {
                    app.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.state == .running ? "stop.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text(model.state == .running ? "停止代理" : "启动代理")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(width: 112)
                }
                .buttonStyle(LPPrimaryButtonStyle(tint: model.state == .running ? LP.dangerFill : nil))
                .controlSize(.large)

                HStack(spacing: 8) {
                    Text("系统代理")
                        .font(.system(size: 12))
                        .foregroundStyle(LP.textTertiary)
                    LPSwitch(isOn: Binding(
                        get: { model.systemProxyActive },
                        set: { app.engine.toggleSystemProxy($0) }
                    ), width: 30)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .lpGlass(radius: 16, fallbackFill: LP.panel, shadow: 0.06)
    }

    private var statusLine: String {
        if case .failed(let message) = model.state {
            return "启动失败：\(message)"
        }
        if model.state == .starting { return "代理正在启动。" }
        if model.state == .running {
            return model.systemProxyActive
                ? "流量已接管；实时观测在抓包页的「观测」里。"
                : "代理已就绪，系统流量还没经过它。"
        }
        return "代理未启动；先启动，再把系统流量交给它。"
    }

    private var statusColor: Color {
        switch model.state {
        case .running: return LP.mint
        case .starting: return LP.amber
        case .failed: return LP.danger
        case .stopped: return LP.textTertiary
        }
    }

    // MARK: - Main column

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            LPEyebrow("核心").padding(.leading, 2)

            RoutingCard(rules: model.profile.rules,
                        groups: model.profile.groups) {
                app.go(to: .rules)
            }

            if windowWidth >= 1100 {
                HStack(alignment: .top, spacing: 16) {
                    adblockCard
                    captureCard
                }
            } else {
                VStack(spacing: 16) {
                    adblockCard
                    captureCard
                }
            }
        }
    }

    private var adblockCard: some View {
        ToolCard(
            title: "去广告",
            detail: "拦截广告与跟踪器，规则来源与白名单在去广告页管理。",
            status: model.profile.adblock.enabled ? "已开启" : "未开启",
            icon: "hand.raised.fill",
            section: .adblock)
    }

    private var captureCard: some View {
        ToolCard(
            title: "抓包与解密",
            detail: "实时观测、请求详情与 HAR 导出都在抓包页。",
            status: "抓包 \(model.profile.general.captureEnabled ? "开" : "关") · 解密 \(model.profile.general.mitmEnabled ? "开" : "关")",
            icon: "waveform.path.ecg",
            section: .capture)
    }

    // MARK: - Side column

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            LPEyebrow("工具").padding(.leading, 2)

            IndexRow(title: "智能学习", icon: "brain", section: .learn)
            IndexRow(title: "NAS", icon: "externaldrive.connected.to.line.below", section: .nas)
            IndexRow(title: "SSH", icon: "terminal", section: .ssh)

            LPDivider().padding(.vertical, 8)

            LPEyebrow("系统").padding(.leading, 2)

            IndexRow(title: "配置", icon: "doc.on.doc", section: .profiles)
            IndexRow(title: "隐私", icon: "lock.shield", section: .privacy)
            IndexRow(title: "设置", icon: "gearshape", section: .settings)
        }
    }
}

// MARK: - Routing card + policy rail

@MainActor
private struct RoutingCard: View {
    let rules: [Rule]
    let groups: [PolicyGroup]
    let action: () -> Void

    @State private var hovered = false
    @FocusState private var focused: Bool

    private var active: Bool { hovered || focused }

    /// The last rule is the catch-all in a normal ruleset. Showing its policy is
    /// honest data: it is where unmatched traffic actually goes.
    private var exitPolicy: String {
        displayPolicy(rules.last?.policy ?? (groups.first?.name ?? "DIRECT"))
    }

    private func displayPolicy(_ raw: String) -> String {
        switch raw.uppercased() {
        case "PROXY": return "代理"
        case "DIRECT": return "直连"
        case "REJECT": return "拒绝"
        default: return raw
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(LP.textTertiary)
                        .frame(width: 18)
                    Text("分流规则")
                        .font(LPFont.display(18, weight: .semibold))
                        .foregroundStyle(LP.text)
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(active ? LP.accent : LP.textTertiary)
                        .offset(x: active ? 2 : 0)
                }

                Text("按域名、IP、进程或规则集决定每个连接的出口。")
                    .font(.system(size: 14))
                    .foregroundStyle(LP.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    LPDivider()
                    HStack(spacing: 8) {
                        railNode("\(rules.count) 条规则")
                        railLine
                        railNode("\(groups.count) 个策略组")
                        railLine
                        HStack(spacing: 4) {
                            Circle()
                                .fill(active ? LP.accent : LP.textTertiary)
                                .frame(width: 5, height: 5)
                            Text("出口")
                                .font(LPFont.mono(12))
                                .foregroundStyle(LP.textTertiary)
                            Text(exitPolicy)
                                .font(LPFont.mono(12, weight: .medium))
                                .foregroundStyle(active ? LP.accent : LP.textSecondary)
                                .lineLimit(1)
                        }
                        .fixedSize()
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lpGlass(radius: 16, fallbackFill: LP.panel, shadow: 0.05)
            .overlay(alignment: .trailing) {
                // Index tab: a bookmark pulled out of the card edge on hover/focus.
                Capsule()
                    .fill(LP.accent)
                    .frame(width: 2, height: 18)
                    .offset(x: active ? 7 : 1)
                    .opacity(active ? 0.9 : 0)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(LPCardButtonStyle(radius: 16))
        .onHover { hovered = $0 }
        .focused($focused)
        .lpAnimation(LPMotion.standard, value: active)
    }

    private func railNode(_ text: String) -> some View {
        Text(text)
            .font(LPFont.mono(12))
            .foregroundStyle(LP.textTertiary)
            .fixedSize()
    }

    private var railLine: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(LP.strokeStrong.opacity(0.55))
                .frame(height: 1)
            Rectangle()
                .fill(LP.accent)
                .frame(height: 2)
                .scaleEffect(x: active ? 1 : 0.001, anchor: .leading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 2)
    }
}

// MARK: - Secondary card

@MainActor
private struct ToolCard: View {
    @EnvironmentObject private var app: AppModel

    let title: String
    let detail: String
    let status: String
    let icon: String
    let section: AppModel.Section

    @State private var hovered = false
    @FocusState private var focused: Bool

    private var active: Bool { hovered || focused }

    var body: some View {
        Button {
            app.go(to: section)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(LP.textTertiary)
                        .frame(width: 18)
                    Text(title)
                        .font(LPFont.display(18, weight: .semibold))
                        .foregroundStyle(LP.text)
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(active ? LP.accent : LP.textTertiary)
                        .offset(x: active ? 2 : 0)
                }

                Text(detail)
                    .font(.system(size: 14))
                    .foregroundStyle(LP.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(status)
                    .font(LPFont.mono(12))
                    .foregroundStyle(LP.textTertiary)
            }
            .padding(16)
            .frame(minWidth: 240, maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .lpGlass(radius: 16, fallbackFill: LP.panel, shadow: 0.04)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(active ? LP.accent.opacity(0.035) : .clear)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(LPCardButtonStyle(radius: 16))
        .onHover { hovered = $0 }
        .focused($focused)
        .lpAnimation(LPMotion.standard, value: active)
    }
}

// MARK: - Index row

@MainActor
private struct IndexRow: View {
    @EnvironmentObject private var app: AppModel

    let title: String
    let icon: String
    let section: AppModel.Section

    @State private var hovered = false
    @FocusState private var focused: Bool

    private var active: Bool { hovered || focused }

    var body: some View {
        Button {
            app.go(to: section)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(active ? LP.accent : LP.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LP.text)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LP.textTertiary)
                    .offset(x: active ? 2 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lpGlass(radius: 12, fallbackFill: LP.panel, shadow: 0)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active ? LP.accent.opacity(0.045) : .clear)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(LPCardButtonStyle(radius: 12))
        .onHover { hovered = $0 }
        .focused($focused)
        .lpAnimation(LPMotion.quick, value: active)
    }
}

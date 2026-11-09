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
@MainActor
struct DashboardView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model = OverviewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                statusBand

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        mainColumn.frame(minWidth: 420)
                        sideColumn.frame(width: 300)
                    }
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
                LPEyebrow("当前配置 / Active profile")

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(model.profile.name)
                        .font(LPFont.display(30, weight: .semibold))
                        .tracking(-0.8)
                        .foregroundStyle(LP.text)
                        .lineLimit(1)
                    Text("\(model.profile.rules.count) 条规则")
                        .font(LPFont.mono(10, weight: .medium))
                        .foregroundStyle(LP.textTertiary)
                }

                Text(statusLine)
                    .font(LPFont.serif(13))
                    .foregroundStyle(LP.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(model.state.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LP.textSecondary)
                    Text("·").font(.system(size: 10)).foregroundStyle(LP.textTertiary)
                    Text(model.systemProxyActive ? "系统代理 开" : "系统代理 关")
                        .font(.system(size: 10))
                        .foregroundStyle(LP.textTertiary)
                    Text("·").font(.system(size: 10)).foregroundStyle(LP.textTertiary)
                    Text("127.0.0.1:\(model.profile.general.mixedPort)")
                        .font(LPFont.mono(10))
                        .foregroundStyle(LP.textTertiary)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 12) {
                Button {
                    app.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: model.state == .running ? "stop.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text(model.state == .running ? "停止代理" : "启动代理")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(width: 112)
                    .padding(.vertical, 5)
                }
                .buttonStyle(LPPrimaryButtonStyle(tint: model.state == .running ? LP.dangerFill : nil))
                .controlSize(.large)

                HStack(spacing: 6) {
                    Text("系统代理")
                        .font(.system(size: 10))
                        .foregroundStyle(LP.textTertiary)
                    LPSwitch(isOn: Binding(
                        get: { model.systemProxyActive },
                        set: { app.engine.toggleSystemProxy($0) }
                    ), width: 30)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .lpGlass(radius: LPGlass.panelRadius, fallbackFill: LP.panel, shadow: 0.06)
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
            sectionLabel("核心 / Core")

            featureCard(
                eyebrow: "分流规则 / Routing",
                title: "分流规则",
                detail: "按域名、IP、进程或规则集选择出站；每条连接都能解释为什么这样走。",
                status: "\(model.profile.rules.count) 条规则 · \(model.profile.groups.count) 个策略组",
                icon: "arrow.triangle.branch",
                section: .rules)

            featureCard(
                eyebrow: "去广告 / Ad blocking",
                title: model.profile.adblock.enabled ? "去广告已开启" : "去广告已关闭",
                detail: "拦截广告与跟踪器；规则来源和白名单在去广告页管理，代理启动后生效。",
                status: model.profile.adblock.enabled ? "配置已开启" : "未开启",
                icon: "hand.raised.fill",
                section: .adblock)

            featureCard(
                eyebrow: "抓包与解密 / Capture",
                title: "抓包与解密",
                detail: "实时观测、请求详情、HTTPS 解密与 HAR 导出，都在抓包页。",
                status: "抓包 \(model.profile.general.captureEnabled ? "开" : "关") · 解密 \(model.profile.general.mitmEnabled ? "开" : "关")",
                icon: "waveform.path.ecg",
                section: .capture)
        }
    }

    // MARK: - Side column

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("工具 / Tools")

            featureRow("智能学习", "从 App 列表或截图生成规则", icon: "brain", section: .learn)
            featureRow("NAS", "发现并挂载局域网共享", icon: "externaldrive.connected.to.line.below", section: .nas)
            featureRow("SSH", "本地终端会话", icon: "terminal", section: .ssh)

            LPDivider().padding(.vertical, 8)

            sectionLabel("系统 / System")

            featureRow("配置", "导入、导出与切换配置", icon: "doc.on.doc", section: .profiles)
            featureRow("隐私", "健康度、加固清单与跟踪器", icon: "lock.shield", section: .privacy)
            featureRow("设置", "端口、DNS、CA 与日志", icon: "gearshape", section: .settings)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        LPEyebrow(text)
            .padding(.leading, 2)
    }

    private func featureCard(eyebrow: String,
                             title: String,
                             detail: String,
                             status: String,
                             icon: String,
                             section: AppModel.Section) -> some View {
        Button {
            app.go(to: section)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    LPEyebrow(eyebrow)
                    Spacer(minLength: 8)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(LP.textTertiary)
                }
                Text(title)
                    .font(LPFont.display(18, weight: .semibold))
                    .foregroundStyle(LP.text)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(LP.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(status)
                        .font(LPFont.mono(10))
                        .foregroundStyle(LP.textTertiary)
                    Spacer(minLength: 8)
                    Text("打开 →")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LP.accent)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lpGlass(radius: 14, fallbackFill: LP.panel, shadow: 0.04)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func featureRow(_ title: String,
                            _ subtitle: String,
                            icon: String,
                            section: AppModel.Section) -> some View {
        Button {
            app.go(to: section)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LP.textSecondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LP.text)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(LP.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LP.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lpGlass(radius: 10, fallbackFill: LP.panel, shadow: 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
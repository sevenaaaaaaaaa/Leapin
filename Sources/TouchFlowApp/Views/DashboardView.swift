import SwiftUI
import TouchFlowCore
import TouchFlowRuntime
import TouchFlowPolicy
import TouchFlowNet
import TouchFlowIntegrations

struct DashboardView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var engine = TouchFlowEngine.shared
    @State private var probeHost = ""
    @State private var probe: RuleMatch?
    @State private var probeVerdict: BlockVerdict?
    @State private var dismissedHints: Set<String> = []
    @FocusState private var probeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                if let step = nextStep {
                    nextStepCard(step)
                }
                statsGrid
                HStack(alignment: .top, spacing: 16) {
                    endpoints
                    explainer
                }
                recentFlows
            }
            .pagePadding()
        }
        .onChange(of: app.searchFocusRequest) { _, _ in
            probeFocused = true
        }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(spacing: 22) {
            statusOrb
            VStack(alignment: .leading, spacing: 7) {
                Text("当前配置")
                    .font(TFFont.overline)
                    .tracking(1.1)
                    .foregroundStyle(TF.textTertiary)
                Text(engine.profile.name)
                    .font(TFFont.display(21, weight: .bold))
                    .foregroundStyle(TF.text)
                HStack(spacing: 6) {
                    StatusChip(state: engine.state)
                    Badge(text: app.isRunning ? "分流中" : "未接管流量",
                          color: app.isRunning ? TF.mint : TF.textTertiary)
                    if engine.profile.general.mitmEnabled {
                        Badge(text: "HTTPS 解密", color: TF.violet)
                    }
                    if engine.profile.adblock.enabled {
                        Badge(text: "去广告", color: TF.amber)
                    }
                }
                if let error = engine.lastError, engine.state != .running {
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(TF.danger)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 10) {
                Button {
                    app.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: engine.state == .running ? "stop.fill" : "play.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text(engine.state == .running ? "停止代理" : "启动代理")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .frame(width: 104)
                    .padding(.vertical, 4)
                }
                .buttonStyle(TFPrimaryButtonStyle(tint: engine.state == .running ? TF.danger : nil))
                .controlSize(.large)

                HStack(spacing: 14) {
                    toggleChip("去广告", isOn: engine.profile.adblock.enabled) { on in
                        engine.setAdBlockEnabled(on)
                        app.showToast(on ? "去广告已开启" : "去广告已关闭", kind: .info)
                    }
                    toggleChip("HTTPS 解密", isOn: engine.profile.general.mitmEnabled) { on in
                        engine.setMITMEnabled(on)
                        app.showToast(on ? "HTTPS 解密已开启，请确认已信任 CA" : "HTTPS 解密已关闭",
                                      kind: on ? .warning : .info)
                    }
                }
            }
        }
        .padding(22)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(TF.panel)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [TF.accent.opacity(0.16), TF.violet.opacity(0.05), .clear],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(TF.strokeStrong, lineWidth: 1)
            }
        )
        .shadow(color: TF.accent.opacity(0.10), radius: 20, y: 8)
    }

    private var statusOrb: some View {
        ZStack {
            Circle().strokeBorder(TF.accent.opacity(0.10), lineWidth: 1).frame(width: 92, height: 92)
            Circle().strokeBorder(TF.accent.opacity(0.16), lineWidth: 1).frame(width: 72, height: 72)
            Circle()
                .fill(LinearGradient(colors: [TF.accent.opacity(0.22), TF.violet.opacity(0.12)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 54, height: 54)
            Image(systemName: app.isRunning ? "shield.lefthalf.filled" : "shield.slash")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(app.isRunning ? TF.accent : TF.textTertiary)
                .symbolEffect(.pulse, isActive: app.isRunning)
        }
        .frame(width: 92, height: 92)
    }

    private func toggleChip(_ label: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(isOn ? TF.text : TF.textTertiary)
            TFSwitch(isOn: Binding(get: { isOn }, set: set), width: 30)
        }
    }

    // MARK: Next step

    private struct NextStep {
        let id: String
        let icon: String
        let title: String
        let message: String
        let actionTitle: String
        let action: () -> Void
    }

    private var nextStep: NextStep? {
        if case .failed = engine.state {
            return NextStep(id: "retry", icon: "exclamationmark.triangle.fill",
                            title: "上次启动失败",
                            message: engine.lastError ?? "检查端口是否被占用，或查看设置中的日志。",
                            actionTitle: "重试启动", action: { app.toggle() })
        }
        if engine.state == EngineState.running, !engine.systemProxyActive {
            return NextStep(id: "proxy", icon: "network",
                            title: "代理已就绪，但系统流量还没经过它",
                            message: "开启系统代理后，浏览器与 App 的请求会自动走 127.0.0.1:\(engine.profile.general.mixedPort)。",
                            actionTitle: "开启系统代理", action: { engine.toggleSystemProxy(true) })
        }
        if engine.state == EngineState.running, engine.flows.isEmpty {
            return NextStep(id: "verify", icon: "waveform.path.ecg",
                            title: "验证流量确实在走代理",
                            message: "抓包页会逐条显示请求；也可以先用系统代理访问任意网站再回来看。",
                            actionTitle: "打开抓包", action: { app.go(to: .capture) })
        }
        if !app.isRunning {
            return NextStep(id: "start", icon: "play.circle.fill",
                            title: "第一步：启动本地代理",
                            message: "混合端口同时支持 HTTP 与 SOCKS5，启动后即可把任何 App 指向它。",
                            actionTitle: "启动代理", action: { app.toggle() })
        }
        return nil
    }

    @ViewBuilder private func nextStepCard(_ step: NextStep) -> some View {
        if !dismissedHints.contains(step.id) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(TF.accentSoft)
                    Image(systemName: step.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TF.accent)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TF.text)
                    Text(step.message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(TF.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                Button(step.actionTitle, action: step.action)
                    .buttonStyle(TFPrimaryButtonStyle())
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { _ = dismissedHints.insert(step.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(TF.textTertiary)
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("暂时忽略此建议")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(TF.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(TF.stroke))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: Stats

    private var statsGrid: some View {
        HStack(spacing: 12) {
            StatTile(icon: "arrow.left.arrow.right", title: "活动连接",
                     value: "\(engine.activeConnections)", tint: TF.accent)
            StatTile(icon: "hand.raised.fill", title: "已拦截",
                     value: "\(engine.stats.blocked)", tint: TF.danger)
            StatTile(icon: "waveform.path.ecg", title: "抓包请求",
                     value: "\(engine.stats.captures)", tint: TF.violet)
            StatTile(icon: "arrow.up.arrow.down", title: "累计流量",
                     value: Fmt.bytes(engine.stats.bytesIn + engine.stats.bytesOut), tint: TF.mint)
            StatTile(icon: "list.bullet.rectangle", title: "规则",
                     value: "\(engine.ruleCount)", tint: TF.amber)
        }
    }

    // MARK: Endpoints

    private var endpoints: some View {
        Card(title: "本地端点", subtitle: "点击任意一行即可复制", icon: "network") {
            VStack(spacing: 2) {
                endpoint("混合", "HTTP + SOCKS5", "127.0.0.1:\(engine.profile.general.mixedPort)")
                endpoint("HTTP", "明文 / CONNECT", "127.0.0.1:\(engine.profile.general.httpPort)")
                endpoint("SOCKS5", "TCP / UDP 关联", "127.0.0.1:\(engine.profile.general.socksPort)")
                endpoint("DNS",
                         engine.profile.general.dnsHijack ? "DoH / DoT / UDP" : "已关闭",
                         engine.profile.general.dnsHijack ? "127.0.0.1:\(engine.profile.dns.listenPort)" : "—")
                TFDivider().padding(.vertical, 8)
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 11))
                        .foregroundStyle(TF.mint)
                    Text("本机流量不离开 127.0.0.1，除非命中规则")
                        .font(.system(size: 10))
                        .foregroundStyle(TF.textTertiary)
                    Spacer(minLength: 0)
                    Button("安装 CA") { app.installCA() }
                        .buttonStyle(TFGhostButtonStyle())
                }
            }
        }
        .frame(maxWidth: 400)
    }

    private func endpoint(_ tag: String, _ note: String, _ value: String) -> some View {
        let copyable = value != "—"
        return TFRow(accessibilityText: copyable ? "\(tag) \(value)，复制" : "\(tag) 已关闭") {
            if copyable {
                TFClipboard.copy(value)
                app.showToast("已复制 \(value)", kind: .info)
            }
        } content: {
            HStack(spacing: 8) {
                Text(tag)
                    .font(TFFont.mono(9.5, weight: .semibold))
                    .foregroundStyle(copyable ? TF.accent : TF.textTertiary)
                    .frame(width: 46, alignment: .leading)
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(TF.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(value)
                    .font(TFFont.mono(10.5, weight: .medium))
                    .foregroundStyle(copyable ? TF.text : TF.textTertiary)
                    .textSelection(.enabled)
                if copyable {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 8.5))
                        .foregroundStyle(TF.textTertiary)
                }
            }
        }
        .disabled(!copyable)
    }

    // MARK: Explainer

    private var explainer: some View {
        Card(title: "分流解释器", subtitle: "输入域名，查看命中规则与策略", icon: "point.topleft.down.curvedto.point.bottomright.up") {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(probeFocused ? TF.accent : TF.textTertiary)
                    TextField("例如 api.spotify.com", text: $probeHost)
                        .textFieldStyle(.plain)
                        .font(TFFont.mono(11))
                        .focused($probeFocused)
                        .onSubmit(runProbe)
                    if !probeHost.isEmpty {
                        Button {
                            probeHost = ""
                            probe = nil
                            probeVerdict = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 9.5))
                                .foregroundStyle(TF.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除域名")
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(TF.stroke.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(probeFocused ? TF.accent.opacity(0.45) : Color.clear, lineWidth: 1)
                )

                Button("判断", action: runProbe)
                    .buttonStyle(TFPrimaryButtonStyle())
                    .disabled(probeHost.trimmingCharacters(in: .whitespaces).isEmpty || !app.isRunning)
            }

            if let probe {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Badge(text: probe.policy, color: probe.policy.uppercased() == "DIRECT" ? TF.mint : TF.violet)
                        Text(probe.matchedRule?.raw ?? "无规则命中（MATCH 兜底）")
                            .font(TFFont.mono(10))
                            .foregroundStyle(TF.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button {
                            TFClipboard.copy(probe.policy)
                            app.showToast("已复制策略 \(probe.policy)", kind: .info)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 9))
                                .foregroundStyle(TF.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("复制命中策略")
                    }
                    if let verdict = probeVerdict, verdict.blocked {
                        HStack(spacing: 5) {
                            Image(systemName: "nosign").font(.system(size: 9, weight: .bold))
                            Text("去广告拦截：\(verdict.reason ?? "")")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(TF.danger)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(probe.trace.enumerated()), id: \.offset) { _, line in
                            HStack(spacing: 6) {
                                Rectangle().fill(TF.strokeStrong).frame(width: 3, height: 3)
                                Text(line)
                                    .font(TFFont.mono(9.5))
                                    .foregroundStyle(TF.textTertiary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TF.stroke.opacity(0.35), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else if !app.isRunning {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 10))
                    Text("启动代理后可用").font(.system(size: 10.5))
                }
                .foregroundStyle(TF.textTertiary)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "return").font(.system(size: 9))
                    Text("输入后按 ↩ 立即判断").font(.system(size: 10.5))
                }
                .foregroundStyle(TF.textTertiary)
            }
        }
    }

    // MARK: Recent flows

    private var recentFlows: some View {
        Card(title: "最近连接",
             subtitle: engine.flows.isEmpty ? nil : "最近 \(min(engine.flows.count, 10)) 条",
             icon: "clock.arrow.circlepath") {
            if engine.flows.isEmpty {
                EmptyHint(icon: "tray", text: "还没有连接记录\n启动代理并把系统代理指向 127.0.0.1:\(engine.profile.general.mixedPort)")
                    .frame(height: 130)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(engine.flows.suffix(10).reversed())) { flow in
                        FlowRow(flow: flow)
                        if flow.id != engine.flows.suffix(10).first?.id {
                            TFDivider().opacity(0.6)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("查看全部 \(engine.flows.count) 条") { app.go(to: .capture) }
                            .buttonStyle(TFGhostButtonStyle())
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    private func runProbe() {
        let host = probeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        probe = engine.explain(host: host, port: 443)
        probeVerdict = engine.adblockVerdict(domain: host)
        if probe == nil {
            app.showToast("无法解释 \(host)，请确认代理已启动", kind: .warning)
        }
    }
}

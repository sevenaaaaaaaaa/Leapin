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

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                statsGrid
                HStack(alignment: .top, spacing: 16) {
                    endpoints
                    explainer
                }
                recentFlows
            }
            .pagePadding()
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
                    toggleChip("去广告", isOn: engine.profile.adblock.enabled) { engine.setAdBlockEnabled($0) }
                    toggleChip("HTTPS 解密", isOn: engine.profile.general.mitmEnabled) { engine.setMITMEnabled($0) }
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
            Toggle("", isOn: Binding(get: { isOn }, set: set))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
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
        Card(title: "本地端点", subtitle: "Clash / Surge 兼容", icon: "network") {
            VStack(spacing: 2) {
                endpoint("混合", "HTTP + SOCKS5", "127.0.0.1:\(engine.profile.general.mixedPort)")
                endpoint("HTTP", "明文 / CONNECT", "127.0.0.1:\(engine.profile.general.httpPort)")
                endpoint("SOCKS5", "TCP / UDP 关联", "127.0.0.1:\(engine.profile.general.socksPort)")
                endpoint("DNS", engine.profile.general.dnsHijack ? "DoH / DoT / UDP" : "已关闭",
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
        HStack(spacing: 10) {
            Text(tag)
                .font(TFFont.mono(9.5, weight: .semibold))
                .foregroundStyle(TF.accent)
                .frame(width: 46, alignment: .leading)
            Text(note)
                .font(.system(size: 10.5))
                .foregroundStyle(TF.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(TFFont.mono(10.5, weight: .medium))
                .foregroundStyle(TF.text)
                .textSelection(.enabled)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(TF.stroke.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // MARK: Explainer

    private var explainer: some View {
        Card(title: "分流解释器", subtitle: "输入域名，查看命中规则与策略", icon: "point.topleft.down.curvedto.point.bottomright.up") {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(TF.textTertiary)
                    TextField("例如 api.spotify.com", text: $probeHost)
                        .textFieldStyle(.plain)
                        .font(TFFont.mono(11))
                        .onSubmit(runProbe)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(TF.stroke.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

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
                }
            }
        }
    }

    private func runProbe() {
        let host = probeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        probe = engine.explain(host: host, port: 443)
        probeVerdict = engine.adblockVerdict(domain: host)
    }
}

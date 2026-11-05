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
                header
                statsGrid
                HStack(alignment: .top, spacing: 16) {
                    endpoints
                    explainer
                }
                recentFlows
            }
            .pagePadding()
        }
        .navigationTitle("总览")
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(engine.state == .running ? Color.green.opacity(0.18) : Color.gray.opacity(0.15))
                    .frame(width: 54, height: 54)
                Image(systemName: engine.state == .running ? "shield.lefthalf.filled" : "shield.slash")
                    .font(.system(size: 24))
                    .foregroundStyle(engine.state == .running ? .green : .secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(engine.profile.name).font(.title2.weight(.semibold))
                Text(engine.state.label).font(.callout).foregroundStyle(.secondary)
                if let error = engine.lastError, engine.state != .running {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    app.toggle()
                } label: {
                    Label(engine.state == .running ? "停止" : "启动",
                          systemImage: engine.state == .running ? "stop.fill" : "play.fill")
                        .frame(width: 76)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(engine.state == .running ? .red : .accentColor)

                Toggle("系统代理", isOn: Binding(
                    get: { engine.systemProxyActive },
                    set: { engine.toggleSystemProxy($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!app.isRunning && !engine.systemProxyActive)
            }
        }
        .padding(18)
        .background(
            LinearGradient(colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0.03)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private var statsGrid: some View {
        HStack(spacing: 12) {
            StatTile(icon: "arrow.left.arrow.right", title: "活动连接",
                     value: "\(engine.activeConnections)", tint: .blue)
            StatTile(icon: "hand.raised.fill", title: "已拦截",
                     value: "\(engine.stats.blocked)", tint: .red)
            StatTile(icon: "waveform.path.ecg", title: "抓包请求",
                     value: "\(engine.stats.captures)", tint: .purple)
            StatTile(icon: "arrow.up.arrow.down", title: "累计流量",
                     value: Fmt.bytes(engine.stats.bytesIn + engine.stats.bytesOut), tint: .green)
            StatTile(icon: "list.bullet.rectangle", title: "规则",
                     value: "\(engine.ruleCount)", tint: .orange)
        }
    }

    private var endpoints: some View {
        Card(title: "本地端点", subtitle: "Clash / Surge 兼容", icon: "network") {
            VStack(spacing: 8) {
                endpoint("混合端口（HTTP + SOCKS5）", "127.0.0.1:\(engine.profile.general.mixedPort)")
                endpoint("HTTP 代理", "127.0.0.1:\(engine.profile.general.httpPort)")
                endpoint("SOCKS5", "127.0.0.1:\(engine.profile.general.socksPort)")
                endpoint("DNS", engine.profile.general.dnsHijack ? "127.0.0.1:\(engine.profile.dns.listenPort)" : "未启用")
                Divider().padding(.vertical, 2)
                HStack(spacing: 8) {
                    Toggle("去广告", isOn: Binding(
                        get: { engine.profile.adblock.enabled },
                        set: { engine.setAdBlockEnabled($0) }
                    )).toggleStyle(.switch).controlSize(.mini)
                    Toggle("HTTPS 解密", isOn: Binding(
                        get: { engine.profile.general.mitmEnabled },
                        set: { engine.setMITMEnabled($0) }
                    )).toggleStyle(.switch).controlSize(.mini)
                    Spacer()
                    Button("安装 CA") { app.installCA() }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
        .frame(maxWidth: 380)
    }

    private func endpoint(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private var explainer: some View {
        Card(title: "分流解释器", subtitle: "输入域名查看命中规则", icon: "questionmark.circle") {
            HStack(spacing: 8) {
                TextField("例如 api.spotify.com", text: $probeHost)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(runProbe)
                Button("判断", action: runProbe)
                    .disabled(probeHost.trimmingCharacters(in: .whitespaces).isEmpty || !app.isRunning)
            }
            if let probe {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Badge(text: probe.policy, color: .accentColor)
                        Text(probe.matchedRule?.raw ?? "无规则命中（MATCH 兜底）")
                            .font(.caption.monospaced()).lineLimit(1)
                    }
                    if let verdict = probeVerdict, verdict.blocked {
                        Text("去广告拦截：\(verdict.reason ?? "")").font(.caption).foregroundStyle(.red)
                    }
                    ForEach(Array(probe.trace.enumerated()), id: \.offset) { _, line in
                        Text("· \(line)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            } else if !app.isRunning {
                Text("启动代理后可用").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var recentFlows: some View {
        Card(title: "最近连接", subtitle: engine.flows.isEmpty ? nil : "\(engine.flows.count) 条", icon: "clock.arrow.circlepath") {
            if engine.flows.isEmpty {
                EmptyHint(icon: "tray", text: "还没有连接记录。启动代理并把系统代理指向 127.0.0.1:\(engine.profile.general.mixedPort)")
                    .frame(height: 120)
            } else {
                VStack(spacing: 0) {
                    ForEach(engine.flows.suffix(10).reversed()) { flow in
                        FlowRow(flow: flow)
                        Divider().opacity(0.4)
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

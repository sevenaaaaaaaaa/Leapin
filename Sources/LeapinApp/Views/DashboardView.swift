import SwiftUI
import LeapinCore
import LeapinRuntime
import LeapinPolicy
import LeapinNet
import LeapinIntegrations

struct DashboardView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var engine = LeapinEngine.shared
    @State private var probeHost = ""
    @State private var probe: RuleMatch?
    @State private var probeVerdict: BlockVerdict?
    @State private var dismissedHints: Set<String> = []
    @State private var rateIn: [Double] = Array(repeating: 0, count: 60)
    @State private var rateOut: [Double] = Array(repeating: 0, count: 60)
    @State private var lastSampleIn: Int = -1
    @State private var lastSampleOut: Int = -1
    @State private var rateCeiling: Double = 0
    @FocusState private var probeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                hero.lpAppear(0)
                // 首屏只留「现在在发生什么」：状态 + 计数 + 最近的连接。
                // 引导条仅在 hero 推断不出下一步时出现（启动失败 / 已启动但系统代理未接管）。
                if let step = nextStep, step.id != "start" && step.id != "verify" {
                    nextStepCard(step).lpAppear(0.04)
                }
                instrumentPanel.lpAppear(0.08)
                recentFlows.lpAppear(0.12)
                HStack(alignment: .top, spacing: 24) {
                    endpoints
                    explainer
                }
                .lpAppear(0.16)
            }
            .pagePadding()
            .navigationTitle("总览")
        }
        .onChange(of: app.searchFocusRequest) { _, _ in
            probeFocused = true
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            sampleTraffic()
        }
    }

    /// 每秒取一次累计字节差值，分别喂给上行/下行两条 60 秒轨迹。
    private func sampleTraffic() {
        let inNow = engine.stats.bytesIn
        let outNow = engine.stats.bytesOut
        if lastSampleIn < 0 {
            lastSampleIn = inNow; lastSampleOut = outNow; return
        }
        let dIn = max(0, Double(inNow - lastSampleIn))
        let dOut = max(0, Double(outNow - lastSampleOut))
        lastSampleIn = inNow; lastSampleOut = outNow
        rateIn.removeFirst(); rateIn.append(dIn)
        rateOut.removeFirst(); rateOut.append(dOut)
        // 纵轴上限缓慢衰减（每秒 6%）：尖峰进出窗口时曲线不会整体缩放抖动。
        let peak = (rateIn + rateOut).max() ?? 0
        rateCeiling = max(peak, rateCeiling * 0.94)
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 0) {
                LPEyebrow(text: "当前配置 / Active profile")
                    .padding(.bottom, 8)

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(engine.profile.name)
                        .font(LPFont.display(34, weight: .semibold))
                        .tracking(-1.1)
                        .foregroundStyle(LP.text)
                        .lineLimit(1)
                    Text("v1.1")
                        .font(LPFont.mono(10, weight: .medium))
                        .foregroundStyle(LP.textTertiary)
                }

                Text(statusLine)
                    .font(LPFont.serif(13.5))
                    .foregroundStyle(LP.textSecondary)
                    .padding(.top, 8)

                HStack(spacing: 6) {
                    StatusChip(state: engine.state, plain: true)
                    dividerDot
                    Badge(text: app.isRunning ? "分流中" : "未接管流量",
                          color: app.isRunning ? LP.mint : LP.textTertiary)
                    if engine.profile.general.mitmEnabled {
                        Badge(text: "HTTPS 解密", color: LP.violet)
                    }
                    if engine.profile.adblock.enabled {
                        Badge(text: "去广告", color: LP.amber)
                    }
                }
                .padding(.top, 12)

                if case .failed = engine.state {
                    Text(engine.lastError.map(friendlyError) ?? "端口可能被占用，查看设置中的日志后重试。")
                        .font(LPFont.mono(10))
                        .foregroundStyle(LP.danger)
                        .lineLimit(2)
                        .padding(.top, 8)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 12) {
                Button {
                    app.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: engine.state == .running ? "stop.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text(engine.state == .running ? "停止代理" : "启动代理")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(width: 112)
                    .padding(.vertical, 5)
                }
                .buttonStyle(LPPrimaryButtonStyle(tint: engine.state == .running ? LP.dangerFill : nil))
                .controlSize(.large)

                HStack(spacing: 16) {
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
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .lpGlass(radius: LPGlass.panelRadius,
                 fallbackFill: LP.panel,
                 shadow: 0.08)
        .overlay(alignment: .topLeading) {
            // A 2pt signal rule instead of a glow: the brand appears once, quietly.
            Capsule()
                .fill(LP.accent)
                .frame(width: 44, height: 2)
                .padding(.leading, 24)
        }
        .shadow(color: .black.opacity(0.04), radius: 18, y: 8)
    }

    private var statusLine: String {
        if case .failed = engine.state { return "上一次启动没有成功，错误信息留在下面。" }
        if app.isRunning {
            return "流量已接管，每条连接都能追到具体规则。"
        }
        return "代理尚未启动，本机流量仍走系统默认路径。"
    }

    /// Runtime errors are English-y and prefixed; keep the page sentence-sized and human.
    private func friendlyError(_ raw: String) -> String {
        let trimmed = raw
            .replacingOccurrences(of: "Invalid configuration: ", with: "")
            .replacingOccurrences(of: "Invalid configuration", with: "配置无效")
        return trimmed.isEmpty ? "启动失败，查看设置中的日志后重试。" : trimmed
    }

    private var dividerDot: some View {
        Circle().fill(LP.strokeStrong).frame(width: 2.5, height: 2.5)
    }

    private func toggleChip(_ label: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(isOn ? LP.textSecondary : LP.textTertiary)
            LPSwitch(isOn: Binding(get: { isOn }, set: set), width: 32)
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
            HStack(spacing: 14) {
                Rectangle()
                    .fill(LP.accent)
                    .frame(width: 2, height: 26)

                Image(systemName: step.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LP.accent)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LP.text)
                    Text(step.message)
                        .font(.system(size: 10))
                        .foregroundStyle(LP.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                Button(step.actionTitle, action: step.action)
                    .buttonStyle(LPGhostButtonStyle())
                Button {
                    LPMotion.run(LPMotion.quick) { _ = dismissedHints.insert(step.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(LP.textTertiary)
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("暂时忽略此建议")
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                Rectangle().fill(LP.stroke.opacity(0.7)).frame(height: 0.5)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: Instrument strip

    private var probeReady: Bool {
        !probeHost.trimmingCharacters(in: .whitespaces).isEmpty && app.isRunning
    }

    private var instrumentPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // 一条主指标 + 四条从指标：首屏需要一个「正在工作的数字」当主角。
                metric("活动连接", "\(engine.activeConnections)", primary: true)
                stripDivider
                metric("已拦截", "\(engine.stats.blocked)")
                stripDivider
                metric("抓包请求", "\(engine.stats.captures)")
                stripDivider
                metric("累计流量", Fmt.bytes(engine.stats.bytesIn + engine.stats.bytesOut))
                stripDivider
                metric("规则", "\(engine.ruleCount)")
            }
            .padding(.vertical, 2)

            LPDivider()

            trafficSeismograph
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
        }
        .lpPanel(padding: 0)
        .lpHoverLift()
    }

    /// 签名器件：最近 60 秒的上行/下行轨迹（下载在基准线上方、上传在下方）。
    /// 空闲时只留基准线与零位游标，跑起来才有形状——不画一条假的平线。
    private var trafficSeismograph: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                LPEyebrow(text: "流量 / 60s")
                HStack(spacing: 14) {
                    legend(color: LP.text.opacity(0.85), dashed: false, text: "↓ \(rateInText)")
                    legend(color: LP.textTertiary, dashed: true, text: "↑ \(rateOutText)")
                }
            }
            .frame(width: 216, alignment: .leading)

            VStack(spacing: 3) {
                Canvas { context, size in
                    let mid = size.height / 2
                    var baseline = Path()
                    baseline.move(to: CGPoint(x: 0, y: mid + 0.5))
                    baseline.addLine(to: CGPoint(x: size.width, y: mid + 0.5))
                    context.stroke(baseline, with: .color(LP.stroke.opacity(0.8)), lineWidth: 1)

                    let rawPeak = (rateIn + rateOut).max() ?? 0
                    guard rateIn.count > 1, rawPeak > 0.5 else {
                        var tick = Path()
                        tick.move(to: CGPoint(x: size.width - 1, y: mid - 5))
                        tick.addLine(to: CGPoint(x: size.width - 1, y: mid + 5))
                        context.stroke(tick, with: .color(LP.accent), lineWidth: 2)
                        return
                    }
                    let peak = max(rateCeiling, rawPeak)
                    // sqrt 映射：小流量也看得出起伏，大尖峰不至于把其余压成直线。
                    func path(_ series: [Double], mirrored: Bool) -> Path {
                        var p = Path()
                        for (i, v) in series.enumerated() {
                            let x = size.width * CGFloat(i) / CGFloat(series.count - 1)
                            let ratio = CGFloat((max(v, 0) / peak).squareRoot())
                            let y = mirrored ? mid + (mid - 2) * ratio : mid - (mid - 2) * ratio
                            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                            else { p.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        return p
                    }
                    context.stroke(path(rateIn, mirrored: false),
                                   with: .color(LP.text.opacity(0.85)), lineWidth: 1)
                    context.stroke(path(rateOut, mirrored: true),
                                   with: .color(LP.textTertiary),
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

                    if let lastIn = rateIn.last, let lastOut = rateOut.last {
                        let x = size.width
                        let yIn = mid - (mid - 2) * CGFloat((max(lastIn, 0) / peak).squareRoot())
                        var cursor = Path()
                        cursor.move(to: CGPoint(x: x - 1, y: 1))
                        cursor.addLine(to: CGPoint(x: x - 1, y: size.height - 1))
                        context.stroke(cursor, with: .color(LP.accent.opacity(0.55)), lineWidth: 1)
                        context.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: yIn - 3, width: 6, height: 6)),
                                     with: .color(LP.accent))
                        let yOut = mid + (mid - 2) * CGFloat((max(lastOut, 0) / peak).squareRoot())
                        context.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: yOut - 2.5, width: 5, height: 5)),
                                     with: .color(LP.textTertiary))
                    }
                }
                .frame(height: 34)

                HStack(spacing: 8) {
                    Text("60 秒前").font(LPFont.mono(10)).foregroundStyle(LP.textTertiary)
                    Spacer()
                    Text("峰值 \(Fmt.bytes(Int(rateCeiling)))/s")
                        .font(LPFont.mono(10))
                        .foregroundStyle(LP.textTertiary)
                    Spacer()
                    Text("现在").font(LPFont.mono(10)).foregroundStyle(LP.textTertiary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("最近 60 秒上行与下行流量轨迹")
        }
    }

    private func legend(color: Color, dashed: Bool, text: String) -> some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                if dashed {
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle().fill(color).frame(width: 3, height: 1)
                    }
                } else {
                    Rectangle().fill(color).frame(width: 13, height: 1)
                }
            }
            .frame(width: 13, alignment: .leading)
            Text(text)
                .font(LPFont.num(10, weight: .medium))
                .foregroundStyle(LP.textSecondary)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
    }

    private var rateInText: String { rateLabel(rateIn) }
    private var rateOutText: String { rateLabel(rateOut) }

    private func rateLabel(_ series: [Double]) -> String {
        let samples = series.suffix(5)
        let avg = samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)
        return avg < 1 ? "0 B/s" : Fmt.bytes(Int(avg)) + "/s"
    }

    private var stripDivider: some View {
        Rectangle().fill(LP.stroke).frame(width: 1, height: 44)
    }

    private func metric(_ label: String, _ value: String, primary: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: primary ? 8 : 7) {
            LPEyebrow(text: label, tint: primary ? LP.textSecondary : LP.textTertiary)
            Text(value)
                .font(LPFont.num(primary ? 28 : 21, weight: primary ? .medium : .regular))
                .foregroundStyle(LP.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.numericText())
                .lpAnimation(LPMotion.emphasized, value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    // MARK: Endpoints

    private var endpoints: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                LPEyebrow(text: "本地端点 / Endpoints")
                Spacer()
                Text("点击复制")
                    .font(LPFont.mono(10))
                    .foregroundStyle(LP.textTertiary)
            }
            .padding(.bottom, 10)

            endpoint("MIX", "HTTP + SOCKS5", "127.0.0.1:\(engine.profile.general.mixedPort)")
            rowRule
            endpoint("HTTP", "明文 / CONNECT", "127.0.0.1:\(engine.profile.general.httpPort)")
            rowRule
            endpoint("SOCKS", "TCP / UDP 关联", "127.0.0.1:\(engine.profile.general.socksPort)")
            rowRule
            endpoint("DNS",
                     engine.profile.general.dnsHijack ? "DoH / DoT / UDP" : "已关闭",
                     engine.profile.general.dnsHijack ? "127.0.0.1:\(engine.profile.dns.listenPort)" : "—")

            LPDivider().padding(.vertical, 12)

            HStack(spacing: 9) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 12))
                    .foregroundStyle(LP.mint)
                Text("本机流量不离开 127.0.0.1，除非命中规则")
                    .font(.system(size: 10))
                    .foregroundStyle(LP.textTertiary)
                Spacer(minLength: 0)
                Button("安装 CA") { app.installCA() }
                    .buttonStyle(LPGhostButtonStyle())
            }
        }
        .frame(maxWidth: 430)
        .lpPanel(padding: 18)
    }

    private var rowRule: some View {
        Rectangle().fill(LP.stroke.opacity(0.7)).frame(height: 1)
    }

    private func endpoint(_ tag: String, _ note: String, _ value: String) -> some View {
        let copyable = value != "—"
        return LPRow(accessibilityText: copyable ? "\(tag) \(value)，复制" : "\(tag) 已关闭") {
            if copyable { LPClipboard.copy(value) }
        } content: {
            HStack(spacing: 10) {
                Text(tag)
                    .font(LPFont.mono(10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(copyable ? LP.textSecondary : LP.textTertiary)
                    .frame(width: 42, alignment: .leading)
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(LP.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(value)
                    .font(LPFont.mono(12, weight: .medium))
                    .foregroundStyle(copyable ? LP.text : LP.textTertiary)
                    .textSelection(.enabled)
                if copyable {
                    LPCopyButton(value: value, accessibility: "复制 \(tag) 端点")
                }
            }
            .padding(.vertical, 2)
        }
        .disabled(!copyable)
    }

    // MARK: Explainer

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                LPEyebrow(text: "分流解释器 / Resolve")
                Spacer()
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.system(size: 12))
                    .foregroundStyle(LP.textTertiary)
            }

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(probeFocused ? LP.accent : LP.textTertiary)
                TextField("例如 api.spotify.com", text: $probeHost)
                    .textFieldStyle(.plain)
                    .font(LPFont.mono(12))
                    .focused($probeFocused)
                    .onSubmit(runProbe)
                if !probeHost.isEmpty {
                    Button {
                        probeHost = ""
                        probe = nil
                        probeVerdict = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(LP.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除域名")
                }
                Button(action: runProbe) {
                    HStack(spacing: 4) {
                        Text("判断").font(.system(size: 12, weight: .semibold))
                        Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(probeReady ? LP.accent : LP.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(!probeReady)
                .help("在本地按当前规则判断该域名")
            }
            .padding(.bottom, 7)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(probeFocused ? LP.accent : LP.stroke)
                    .frame(height: 1)
                    .lpAnimation(LPMotion.quick, value: probeFocused)
            }

            if probe == nil {
                VStack(alignment: .leading, spacing: 7) {
                    LPEyebrow(text: "快速样例 / Sample")
                    HStack(spacing: 6) {
                        sample("api.spotify.com")
                        sample("github.com")
                        sample("doubleclick.net")
                    }
                }
                .padding(.top, 2)
            }

            if let probe {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Badge(text: probe.policy,
                              color: probe.policy.uppercased() == "REJECT" ? LP.danger : LP.textSecondary)
                        Text(probe.matchedRule?.raw ?? "无规则命中（MATCH 兜底）")
                            .font(LPFont.mono(10))
                            .foregroundStyle(LP.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        LPCopyButton(value: probe.policy, accessibility: "复制命中策略")
                    }
                    if let verdict = probeVerdict, verdict.blocked {
                        HStack(spacing: 5) {
                            Image(systemName: "nosign").font(.system(size: 12, weight: .bold))
                            Text("去广告拦截：\(verdict.reason ?? "")")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(LP.danger)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(probe.trace.enumerated()), id: \.offset) { _, line in
                            HStack(spacing: 6) {
                                Rectangle().fill(LP.strokeStrong).frame(width: 3, height: 3)
                                Text(line)
                                    .font(LPFont.mono(10))
                                    .foregroundStyle(LP.textTertiary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LP.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(LP.stroke)
                )
                .transition(.opacity.combined(with: .offset(y: 4)))
                Spacer(minLength: 0)
            } else if !app.isRunning {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 12))
                    Text("启动代理后可用；判断在本地完成，不会发出请求。")
                        .font(.system(size: 10))
                }
                .foregroundStyle(LP.textTertiary)
                Spacer(minLength: 0)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "return").font(.system(size: 12))
                    Text("输入后按 ↩ 立即判断，只在本地计算。")
                        .font(.system(size: 10))
                }
                .foregroundStyle(LP.textTertiary)
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            Rectangle().fill(LP.stroke.opacity(0.8)).frame(height: 1)

            HStack(spacing: 6) {
                Text("RULE → RULE-SET → GEOIP → MATCH")
                    .font(LPFont.mono(10))
                    .tracking(0.8)
                    .foregroundStyle(LP.textTertiary)
                Spacer()
                Text("按首次命中裁决")
                    .font(.system(size: 9))
                    .foregroundStyle(LP.textTertiary.opacity(0.9))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 196, alignment: .leading)
        .lpPanel(padding: 18)
    }

    private func sample(_ host: String) -> some View {
        Button {
            probeHost = host
            runProbe()
        } label: {
            Text(host)
                .font(LPFont.mono(10))
                .foregroundStyle(LP.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(LP.bg.opacity(0.7), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(LP.stroke))
        }
        .buttonStyle(.plain)
        .disabled(!app.isRunning)
    }

    // MARK: Recent flows

    private var recentFlows: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                LPEyebrow(text: "最近连接 / Recent")
                Spacer()
                if !engine.flows.isEmpty {
                    Button("打开抓包") { app.go(to: .capture) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(LP.textSecondary)
                }
            }
            .padding(.bottom, 12)

            // 表头常驻：即便没有数据，也要说明这张表会记录什么。
            HStack(spacing: 10) {
                Text("时间").frame(width: 58, alignment: .leading)
                Text("主机 / 规则").frame(maxWidth: .infinity, alignment: .leading)
                Text("流量").frame(width: 120, alignment: .trailing)
            }
            .font(LPFont.mono(10, weight: .medium))
            .tracking(1)
            .foregroundStyle(LP.textTertiary)
            .padding(.bottom, 7)

            LPDivider()

            if engine.flows.isEmpty {
                HStack(spacing: 10) {
                    Text(app.isRunning
                         ? "代理已接管，第一条请求出现后这里会逐条记录。"
                         : "代理未启动，把系统流量指向 127.0.0.1:\(engine.profile.general.mixedPort) 后即可记录。")
                        .font(.system(size: 12))
                        .foregroundStyle(LP.textTertiary)
                    Spacer(minLength: 8)
                    if app.isRunning {
                        Button("去抓包") { app.go(to: .capture) }
                            .buttonStyle(LPGhostButtonStyle())
                    }
                }
                .padding(.vertical, 18)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(engine.flows.suffix(10).reversed())) { flow in
                        FlowRow(flow: flow)
                        if flow.id != engine.flows.suffix(10).first?.id {
                            LPDivider().opacity(0.55)
                        }
                    }
                }
            }
        }
        .lpPanel(padding: 18)
    }

    private func runProbe() {
        let host = probeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        LPMotion.run(LPMotion.standard) {
            probe = engine.explain(host: host, port: 443)
            probeVerdict = engine.adblockVerdict(domain: host)
        }
        if probe == nil {
            app.showToast("无法解释 \(host)，请确认代理已启动", kind: .warning)
        }
    }
}

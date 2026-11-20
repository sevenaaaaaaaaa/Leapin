import SwiftUI
import AppKit
import CoreImage
import LeapinCore
import LeapinRuntime
import LeapinIntegrations
import LeapinPolicy
import LeapinNet

@MainActor
struct SettingsView: View {
    @ObservedObject private var engine = LeapinEngine.shared
    @EnvironmentObject private var app: AppModel
    @Environment(\.lpWindowWidth) private var windowWidth

    @State private var mixedPort = ""
    @State private var httpPort = ""
    @State private var socksPort = ""
    @State private var allowLAN = false
    @State private var dnsMode: DNSMode = .doh
    @State private var dnsPort = ""
    @State private var upstreams = ""
    @State private var cacheTTL = ""
    @State private var bypass = ""
    @State private var captureEnabled = true
    @State private var mitmHosts = ""
    @State private var logLevel: LogLevel = .info
    @State private var dnsHijack = true
    @State private var loaded = false
    @State private var showResetConfirm = false
    @State private var pairing: PhonePairing?

    var body: some View {
        Form {
            VStack(spacing: 16) {
                VStack(spacing: 18) {
                    proxySection
                    dnsSection
                    pairingSection
                    launchSection
                    captureSection
                    advancedSection
                    saveBar
                }
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity)
            .pagePadding()
            .navigationTitle("设置")
            .formStyle(.grouped)
        }
        .onAppear {
            load()
            pairing = engine.phonePairing()
        }
        .onChange(of: engine.profile.id) { _, _ in
            // 配置在别处被切换/导入：未修改时直接同步，已修改时保留草稿并提示。
            if isDirty {
                app.showToast("配置已切换，当前未保存的修改仍保留", kind: .warning)
            } else {
                loaded = false
                load()
            }
        }
        .lpConfirm("恢复默认设置？",
                   message: "端口、DNS、抓包与高级选项会回到初始值，分流规则和配置不受影响。",
                   isPresented: $showResetConfirm,
                   confirmTitle: "恢复默认") {
            let defaults = ProfileDefaults.make()
            mixedPort = "\(defaults.general.mixedPort)"
            httpPort = "\(defaults.general.httpPort)"
            socksPort = "\(defaults.general.socksPort)"
            allowLAN = defaults.general.allowLAN
            dnsMode = defaults.dns.mode
            dnsPort = "\(defaults.dns.listenPort)"
            upstreams = defaults.dns.upstreams.joined(separator: ", ")
            cacheTTL = "\(defaults.dns.cacheTTL)"
            bypass = defaults.general.bypass.joined(separator: ", ")
            captureEnabled = defaults.general.captureEnabled
            mitmHosts = defaults.general.mitmHosts.joined(separator: ", ")
            logLevel = defaults.general.logLevel
            dnsHijack = defaults.general.dnsHijack
            app.showToast("已填入默认值，保存后生效", kind: .info)
        }
    }

    // MARK: Sections

    private var launchSection: some View {
        Card(title: "启动与常驻", subtitle: "登录项、默认页面与常驻行为", icon: "power") {
            VStack(spacing: 8) {
                ToggleRow(label: "登录时自动启动", subtitle: LaunchAtLogin.statusText,
                          isOn: Binding(get: { app.launchAtLogin },
                                        set: { app.setLaunchAtLogin($0) }))
                ToggleRow(label: "启动后自动开启代理", subtitle: "不用每次手动点启动",
                          isOn: Binding(get: { app.autostartProxy },
                                        set: { app.setAutostartProxy($0) }))
                FieldRow(label: "启动时打开", hint: "下次启动生效") {
                    LPSelectField(value: Binding(get: { app.startSectionPref },
                                               set: { app.setStartSection($0) }),
                                options: AppModel.Section.allCases.map { ($0, $0.title) })
                }
                VStack(alignment: .leading, spacing: 4) {
                    shortcutLine("⌘⇧Space", "在任意 App 里唤起命令面板")
                    shortcutLine("⌘K", "命令面板 · ⌘F 搜索当前页面")
                    shortcutLine("⌘⇧P", "启动 / 停止代理")
                    shortcutLine("⌘1 – ⌘0", "直接跳到十个页面")
                }
                .padding(.top, 4)
                Text("关闭主窗口不会退出：App 常驻菜单栏，可随时从图标或 Dock 菜单操作。")
                    .font(.system(size: 9))
                    .foregroundStyle(LP.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
        }
    }

    private func shortcutLine(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            LPKeyCap(keys: keys)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(LP.textSecondary)
            Spacer(minLength: 0)
        }
    }

    private var proxySection: some View {
        Card(title: "代理端口", subtitle: "本地监听，修改后需重启代理", icon: "network") {
            VStack(spacing: 8) {
                FieldRow(label: "混合端口", hint: "HTTP + SOCKS5") {
                    NumField(text: $mixedPort, placeholder: "7890")
                }
                FieldRow(label: "HTTP 端口", hint: "仅 HTTP") {
                    NumField(text: $httpPort, placeholder: "7891")
                }
                FieldRow(label: "SOCKS5 端口", hint: "仅 SOCKS5") {
                    NumField(text: $socksPort, placeholder: "7892")
                }
                ToggleRow(label: "允许局域网设备连接", subtitle: "绑定 0.0.0.0，其他设备可显式指向本机", isOn: $allowLAN)
                    .padding(.top, 2)
            }
        }
    }

    private var dnsSection: some View {
        Card(title: "DNS", subtitle: "解析策略与缓存", icon: "globe.asia.australia") {
            if engine.executionKernel == .mihomo {
                VStack(alignment: .leading, spacing: 12) {
                    Text("当前 DNS 使用 Mihomo 来源策略，并由运行中的内核解析。修改 nameserver-policy 等策略时，请重新导入来源配置。")
                        .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                    Button("查看来源方案") { app.go(to: .profiles) }.buttonStyle(LPGhostButtonStyle())
                }
            } else {
            VStack(spacing: 8) {
                FieldRow(label: "模式") {
                    LPSelectField(value: $dnsMode, options: [(DNSMode.system, "系统 DNS"),
                                                           (DNSMode.doh, "DoH"),
                                                           (DNSMode.dot, "DoT"),
                                                           (DNSMode.fakeIP, "Fake-IP")])
                }
                FieldRow(label: "监听端口") { NumField(text: $dnsPort, placeholder: "5354") }
                FieldRow(label: "上游", hint: "逗号分隔") {
                    PlainField(text: $upstreams, placeholder: "https://1.1.1.1/dns-query")
                }
                FieldRow(label: "缓存 TTL", hint: "秒") { NumField(text: $cacheTTL, placeholder: "300") }
                ToggleRow(label: "劫持 53 端口查询", subtitle: "拦截发往本地 53 的明文查询", isOn: $dnsHijack)
                    .padding(.top, 2)
            }
            }
        }
    }

    private var captureSection: some View {
        Card(title: "抓包与解密", subtitle: "MITM 仅对匹配主机生效", icon: "waveform.path.ecg") {
            VStack(spacing: 8) {
                ToggleRow(label: "启用 HTTP 抓包", subtitle: "记录请求/响应头与可读 body", isOn: $captureEnabled)
                FieldRow(label: "MITM 主机", hint: "* 表示全部") {
                    PlainField(text: $mitmHosts, placeholder: "*.example.com, api.test.com")
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: "key.horizontal")
                            .font(.system(size: 10))
                            .foregroundStyle(LP.amber)
                        Text("根证书位置")
                            .font(.system(size: 12))
                            .foregroundStyle(LP.textSecondary)
                        Spacer()
                        Button("打开 CA") { app.installCA() }
                            .buttonStyle(LPGhostButtonStyle())
                    }
                    Text(engine.store.root.appendingPathComponent("ca/ca.pem").path)
                        .font(LPFont.mono(10))
                        .foregroundStyle(LP.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
                .padding(11)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous)
                        .strokeBorder(LP.stroke, lineWidth: 1)
                )
            }
        }
    }

    private var advancedSection: some View {
        Card(title: "高级", subtitle: "日志与系统代理", icon: "slider.horizontal.3") {
            VStack(spacing: 8) {
                FieldRow(label: "日志级别") {
                    LPSelectField(value: $logLevel, options: LogLevel.allCases.map { ($0, $0.rawValue) })
                }
                FieldRow(label: "代理绕过", hint: "逗号分隔") {
                    PlainField(text: $bypass, placeholder: "*.local, 169.254/16")
                }
                HStack(spacing: 6) {
                    Text("数据目录")
                        .font(.system(size: 12))
                        .foregroundStyle(LP.textSecondary)
                    Spacer()
                    Button("在 Finder 中打开") {
                        NSWorkspace.shared.open(engine.store.root)
                    }
                    .buttonStyle(LPGhostButtonStyle())
                }
                .padding(.top, 2)
                Text(engine.store.root.path)
                    .font(LPFont.mono(10))
                    .foregroundStyle(LP.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private var pairingSection: some View {
        PhonePairingCard(pairing: pairing,
                         lanEnabled: engine.profile.general.controlAllowLAN,
                         onToggleLAN: { enabled in
                             engine.setControlLAN(enabled)
                             pairing = engine.phonePairing()
                         })
    }

    private var saveBar: some View {
        HStack(spacing: 12) {
            Image(systemName: validationError == nil ? "info.circle" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(validationError == nil ? LP.textTertiary : LP.amber)
            Text(validationError ?? "保存后如代理正在运行会自动重启以应用新设置。")
                .font(.system(size: 10))
                .foregroundStyle(validationError == nil ? LP.textTertiary : LP.amber)
                .lineLimit(2)
            Spacer()
            Button("恢复默认值") { showResetConfirm = true }
                .buttonStyle(LPGhostButtonStyle())
                .disabled(!loaded)
            Button("保存并重启代理") { save() }
                .buttonStyle(LPPrimaryButtonStyle())
                .disabled(!loaded || validationError != nil)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    /// 端口 / TTL / 上游的轻量校验：只要有非法值就禁用保存，避免保存后代理起不来。
    private var validationError: String? {
        let ports: [(String, String)] = [("混合端口", mixedPort), ("HTTP 端口", httpPort),
                                         ("SOCKS5 端口", socksPort), ("DNS 端口", dnsPort)]
        var values: [String: UInt16] = [:]
        for (label, text) in ports {
            guard let value = UInt16(text), value > 0 else { return "\(label)必须是 1–65535 之间的数字" }
            values[label] = value
        }
        if Set(values.values).count != values.count { return "端口不能重复，请给 HTTP / SOCKS5 / DNS 分配不同端口" }
        if let ttl = Int(cacheTTL), ttl < 0 { return "缓存 TTL 不能为负数" }
        for upstream in list(upstreams) {
            let ok = upstream.hasPrefix("https://") || upstream.hasPrefix("tls://")
                || upstream.hasPrefix("http://") || upstream.hasPrefix("udp://")
                || upstream.split(separator: ".").count == 4
            if !ok { return "上游需是 https:// / tls:// / http:// / udp:// 地址或 IP" }
        }
        return nil
    }

    // MARK: Load / save

    /// 草稿是否与当前配置不一致（用于切换配置时不静默覆盖用户输入）。
    private var isDirty: Bool {
        let p = engine.profile
        return mixedPort != "\(p.general.mixedPort)"
            || httpPort != "\(p.general.httpPort)"
            || socksPort != "\(p.general.socksPort)"
            || dnsPort != "\(p.dns.listenPort)"
            || allowLAN != p.general.allowLAN
            || dnsMode != p.dns.mode
            || captureEnabled != p.general.captureEnabled
            || dnsHijack != p.general.dnsHijack
            || logLevel != p.general.logLevel
            || upstreams != p.dns.upstreams.joined(separator: ", ")
            || bypass != p.general.bypass.joined(separator: ", ")
            || mitmHosts != p.general.mitmHosts.joined(separator: ", ")
            || cacheTTL != "\(p.dns.cacheTTL)"
    }

    private func load() {
        guard !loaded else { return }
        let p = engine.profile
        mixedPort = "\(p.general.mixedPort)"
        httpPort = "\(p.general.httpPort)"
        socksPort = "\(p.general.socksPort)"
        allowLAN = p.general.allowLAN
        dnsMode = p.dns.mode
        dnsPort = "\(p.dns.listenPort)"
        upstreams = p.dns.upstreams.joined(separator: ", ")
        cacheTTL = "\(p.dns.cacheTTL)"
        bypass = p.general.bypass.joined(separator: ", ")
        captureEnabled = p.general.captureEnabled
        mitmHosts = p.general.mitmHosts.joined(separator: ", ")
        logLevel = p.general.logLevel
        dnsHijack = p.general.dnsHijack
        loaded = true
    }

    private func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func save() {
        var next = engine.profile
        next.general.mixedPort = UInt16(mixedPort) ?? next.general.mixedPort
        next.general.httpPort = UInt16(httpPort) ?? next.general.httpPort
        next.general.socksPort = UInt16(socksPort) ?? next.general.socksPort
        next.general.allowLAN = allowLAN
        next.general.captureEnabled = captureEnabled
        next.general.mitmHosts = list(mitmHosts)
        next.general.bypass = list(bypass)
        next.general.logLevel = logLevel
        next.general.dnsHijack = dnsHijack
        next.dns.mode = dnsMode
        next.dns.listenPort = UInt16(dnsPort) ?? next.dns.listenPort
        next.dns.upstreams = list(upstreams)
        next.dns.cacheTTL = Int(cacheTTL) ?? next.dns.cacheTTL

        let wasRunning = engine.state == .running
        if wasRunning { engine.stop() }
        engine.updateProfile(restart: false) { p in
            p.general = next.general
            p.dns = next.dns
        }
        if wasRunning {
            // Report what really happened. A failed restart must not be dressed up
            // as "saved" while the proxy is actually down.
            Task { @MainActor in
                await engine.start()
                if engine.state == .running {
                    app.showToast("设置已保存，代理已重启", kind: .success)
                } else {
                    let reason = engine.lastError ?? "代理未能启动"
                    app.showToast("设置已保存，但代理启动失败：\(reason)", kind: .error,
                                  actionTitle: "重试") {
                        Task { @MainActor in await engine.start() }
                    }
                }
            }
        } else {
            app.showToast("设置已保存", kind: .success)
        }
    }
}

// MARK: - Row primitives

private struct FieldRow<Content: View>: View {
    let label: String
    var hint: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(LP.text)
                    .lineLimit(1)
                    .frame(width: 88, alignment: .leading)
                if let hint {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(LP.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            content()
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LP.stroke.opacity(0.55)).frame(height: 0.5)
        }
    }
}

private struct ToggleRow: View {
    let label: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(LP.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(LP.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            LPSwitch(isOn: $isOn, width: 32)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LP.stroke.opacity(0.55)).frame(height: 0.5)
        }
    }
}

/// Underlined numeric field — a ruled form line, not a gray pill.
private struct NumField: View {
    @Binding var text: String
    var placeholder: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(LP.textTertiary))
            .textFieldStyle(.plain)
            .focused($focused)
            .font(LPFont.mono(12, weight: .medium))
            .multilineTextAlignment(.trailing)
            .frame(width: 92)
            .padding(.vertical, 3)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(focused ? LP.accent : LP.strokeStrong.opacity(0.8))
                    .frame(height: focused ? 1.5 : 1)
                    .lpAnimation(LPMotion.quick, value: focused)
            }
    }
}

private struct PlainField: View {
    @Binding var text: String
    var placeholder: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(LP.textTertiary))
            .textFieldStyle(.plain)
            .focused($focused)
            .font(LPFont.mono(12))
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: 0, maxWidth: 228, alignment: .trailing)
            .padding(.vertical, 3)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(focused ? LP.accent : LP.strokeStrong.opacity(0.8))
                    .frame(height: focused ? 1.5 : 1)
                    .lpAnimation(LPMotion.quick, value: focused)
            }
    }
}

/// One label/value row with an optional copy button, used by the pairing card.
private struct LabeledLine: View {
    var label: String
    var value: String
    var copy: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(LP.textTertiary)
                .frame(width: 30, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(LP.text)
                .textSelection(.enabled)
            if let copy {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copy, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LP.textTertiary)
                .help("复制完整令牌")
            }
        }
    }
}

/// Pairing card: a QR the phone can scan, the token, and the toggle that decides
/// whether the phone can reach this Mac at all. Kept as its own view so the
/// settings body stays a plain list of sections.
private struct PhonePairingCard: View {
    var pairing: PhonePairing?
    var lanEnabled: Bool
    var onToggleLAN: (Bool) -> Void

    var body: some View {
        Card(title: "手机连接", subtitle: "iOS / Android 控制台读这台 Mac 的状态与策略", icon: "qrcode") {
            if let pairing {
                pairedBody(pairing)
            } else {
                Text("控制面还没有生成令牌。先在设置里保持控制面开启，再回到这里。")
                    .font(.system(size: 10))
                    .foregroundStyle(LP.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func pairedBody(_ pairing: PhonePairing) -> some View {
        HStack(alignment: .top, spacing: 14) {
            QRCodeImage(text: pairing.pairingURL)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("地址")
                        .font(.system(size: 10))
                        .foregroundStyle(LP.textTertiary)
                        .frame(width: 30, alignment: .leading)
                    Text("\(pairing.host):\(pairing.port)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LP.text)
                        .textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    Text("令牌")
                        .font(.system(size: 10))
                        .foregroundStyle(LP.textTertiary)
                        .frame(width: 30, alignment: .leading)
                    Text(String(pairing.token.prefix(12)) + "…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LP.text)
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pairing.token, forType: .string)
                    }
                    .buttonStyle(LPGhostButtonStyle())
                }
                Toggle("允许局域网访问", isOn: Binding(get: { lanEnabled }, set: onToggleLAN))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
        if pairing.blockers.isEmpty {
            Text("手机上打开 Leapin →「工具」→ 扫码配对，状态 / 连接 / 策略 / 诊断四个页面立刻可用。")
                .font(.system(size: 10))
                .foregroundStyle(LP.textTertiary)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(pairing.blockers, id: \.self) { reason in
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(LP.amber)
                }
            }
        }
    }
}

/// Renders a pairing payload as a crisp QR image.
private struct QRCodeImage: View {
    var text: String

    var body: some View {
        Group {
            if let image = Self.make(text) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("手机配对二维码")
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LP.panelRaised)
                    .frame(width: 128, height: 128)
            }
        }
    }

    private static func make(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

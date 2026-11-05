import SwiftUI
import AppKit
import TouchFlowCore
import TouchFlowRuntime
import TouchFlowIntegrations
import TouchFlowPolicy
import TouchFlowNet

@MainActor
struct SettingsView: View {
    @ObservedObject private var engine = TouchFlowEngine.shared
    @EnvironmentObject private var app: AppModel

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

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        proxySection
                        dnsSection
                    }
                    VStack(spacing: 16) {
                        launchSection
                        captureSection
                        advancedSection
                    }
                }
                saveBar
            }
            .pagePadding()
        }
        .onAppear(perform: load)
        .onChange(of: engine.profile.id) { _, _ in
            // 配置在别处被切换/导入：未修改时直接同步，已修改时保留草稿并提示。
            if isDirty {
                app.showToast("配置已切换，当前未保存的修改仍保留", kind: .warning)
            } else {
                loaded = false
                load()
            }
        }
        .tfConfirm("恢复默认设置？",
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
                    Picker("", selection: Binding(get: { app.startSectionPref },
                                                  set: { app.setStartSection($0) })) {
                        ForEach(AppModel.Section.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    shortcutLine("⌘⇧Space", "在任意 App 里唤起命令面板")
                    shortcutLine("⌘K", "命令面板 · ⌘F 搜索当前页面")
                    shortcutLine("⌘⇧P", "启动 / 停止代理")
                    shortcutLine("⌘1 – ⌘0", "直接跳到十个页面")
                }
                .padding(.top, 4)
                Text("关闭主窗口不会退出：App 常驻菜单栏，可随时从图标或 Dock 菜单操作。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(TF.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
        }
    }

    private func shortcutLine(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            TFKeyCap(keys: keys)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(TF.textSecondary)
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
            VStack(spacing: 8) {
                FieldRow(label: "模式") {
                    Picker("", selection: $dnsMode) {
                        Text("系统 DNS").tag(DNSMode.system)
                        Text("DoH").tag(DNSMode.doh)
                        Text("DoT").tag(DNSMode.dot)
                        Text("Fake-IP").tag(DNSMode.fakeIP)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
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
                            .foregroundStyle(TF.amber)
                        Text("根证书位置")
                            .font(.system(size: 11))
                            .foregroundStyle(TF.textSecondary)
                        Spacer()
                        Button("打开 CA") { app.installCA() }
                            .buttonStyle(TFGhostButtonStyle())
                    }
                    Text(engine.store.root.appendingPathComponent("ca/touchflow-ca.pem").path)
                        .font(TFFont.mono(9.5))
                        .foregroundStyle(TF.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(TF.stroke.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var advancedSection: some View {
        Card(title: "高级", subtitle: "日志与系统代理", icon: "slider.horizontal.3") {
            VStack(spacing: 8) {
                FieldRow(label: "日志级别") {
                    Picker("", selection: $logLevel) {
                        ForEach(LogLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                }
                FieldRow(label: "代理绕过", hint: "逗号分隔") {
                    PlainField(text: $bypass, placeholder: "*.local, 169.254/16")
                }
                HStack(spacing: 6) {
                    Text("数据目录")
                        .font(.system(size: 11))
                        .foregroundStyle(TF.textSecondary)
                    Spacer()
                    Button("在 Finder 中打开") {
                        NSWorkspace.shared.open(engine.store.root)
                    }
                    .buttonStyle(TFGhostButtonStyle())
                }
                .padding(.top, 2)
                Text(engine.store.root.path)
                    .font(TFFont.mono(9.5))
                    .foregroundStyle(TF.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private var saveBar: some View {
        HStack(spacing: 12) {
            Image(systemName: validationError == nil ? "info.circle" : "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(validationError == nil ? TF.textTertiary : TF.amber)
            Text(validationError ?? "保存后如代理正在运行会自动重启以应用新设置。")
                .font(.system(size: 10.5))
                .foregroundStyle(validationError == nil ? TF.textTertiary : TF.amber)
                .lineLimit(2)
            Spacer()
            Button("恢复默认值") { showResetConfirm = true }
                .buttonStyle(TFGhostButtonStyle())
                .disabled(!loaded)
            Button("保存并重启代理") { save() }
                .buttonStyle(TFPrimaryButtonStyle())
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
            Task { await engine.start() }
            app.showToast("设置已保存，正在重启代理", kind: .info)
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
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(TF.text)
                if let hint {
                    Text(hint)
                        .font(.system(size: 9.5))
                        .foregroundStyle(TF.textTertiary)
                }
            }
            Spacer(minLength: 12)
            content()
        }
        .padding(.vertical, 3)
    }
}

private struct ToggleRow: View {
    let label: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(TF.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(TF.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            TFSwitch(isOn: $isOn, width: 34)
        }
        .padding(.vertical, 3)
    }
}

private struct NumField: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(TF.textTertiary))
            .textFieldStyle(.plain)
            .font(TFFont.mono(11.5, weight: .medium))
            .multilineTextAlignment(.trailing)
            .frame(width: 86)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(TF.stroke.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct PlainField: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(TF.textTertiary))
            .textFieldStyle(.plain)
            .font(TFFont.mono(10.5))
            .multilineTextAlignment(.trailing)
            .frame(minWidth: 160, maxWidth: 260)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(TF.stroke.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

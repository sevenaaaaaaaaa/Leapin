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

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        proxySection
                        dnsSection
                    }
                    VStack(spacing: 16) {
                        captureSection
                        advancedSection
                    }
                }
                saveBar
            }
            .pagePadding()
        }
        .onAppear(perform: load)
    }

    // MARK: Sections

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
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(TF.textTertiary)
            Text("保存后如代理正在运行会自动重启以应用新设置。")
                .font(.system(size: 10.5))
                .foregroundStyle(TF.textTertiary)
            Spacer()
            Button("保存并重启代理") { save() }
                .buttonStyle(TFPrimaryButtonStyle())
                .disabled(!loaded)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    // MARK: Load / save

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
        }
        app.toast = "设置已保存"
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

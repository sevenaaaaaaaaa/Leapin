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
        Form {
            Section("代理端口") {
                TextField("混合端口", text: $mixedPort)
                TextField("HTTP 端口", text: $httpPort)
                TextField("SOCKS5 端口", text: $socksPort)
                Toggle("允许局域网设备连接（0.0.0.0）", isOn: $allowLAN)
            }
            Section("DNS") {
                Picker("模式", selection: $dnsMode) {
                    Text("系统 DNS").tag(DNSMode.system)
                    Text("DNS over HTTPS").tag(DNSMode.doh)
                    Text("DNS over TLS").tag(DNSMode.dot)
                    Text("Fake-IP").tag(DNSMode.fakeIP)
                }
                TextField("监听端口", text: $dnsPort)
                TextField("上游（逗号分隔）", text: $upstreams)
                TextField("缓存 TTL（秒）", text: $cacheTTL)
                Toggle("劫持 53 端口查询到本地 DNS", isOn: $dnsHijack)
            }
            Section("抓包与解密") {
                Toggle("启用 HTTP 抓包", isOn: $captureEnabled)
                TextField("MITM 主机（逗号分隔，* 为全部）", text: $mitmHosts)
                HStack {
                    Text("CA 证书：\(engine.store.root.appendingPathComponent("ca/touchflow-ca.pem").path)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("打开 CA") { app.installCA() }.controlSize(.small)
                }
            }
            Section("高级") {
                Picker("日志级别", selection: $logLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                TextField("系统代理绕过（逗号分隔）", text: $bypass)
                HStack {
                    Text("数据目录：\(engine.store.root.path)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("打开") { NSWorkspace.shared.open(engine.store.root) }.controlSize(.small)
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("保存并重启代理") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!loaded)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .onAppear(perform: load)
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
        }
        app.toast = "设置已保存"
    }
}

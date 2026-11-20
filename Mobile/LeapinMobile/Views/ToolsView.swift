import SwiftUI
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Things the phone can do on its own.
///
/// The console tabs need a paired Mac, but requiring that before anything works made
/// the app useless on first launch. This page is the default tab: network facts, DNS
/// and HTTP checks run entirely on the device.
struct ToolsView: View {
    @Environment(ConsoleStore.self) private var store

    @State private var localAddress: String?
    @State private var publicAddress: String?
    @State private var loadingPublic = false
    @State private var publicError: String?

    @State private var host = ""
    @State private var dnsResult: [String] = []
    @State private var dnsError: String?
    @State private var dnsElapsed: Double?
    @State private var checkingDNS = false

    @State private var url = "https://example.com"
    @State private var probeStatus: Int?
    @State private var probeElapsed: Double?
    @State private var probeError: String?
    @State private var probing = false

    @State private var localProxy = LocalProxyEngine()
    private var tunnel: TunnelManager { .shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    LPSection(header: "本机", footer: localProxy.lastCheck ?? "代理在本机监听回环端口；系统接管需要付费开发者账号的 network-extension 权限。") {
                        LPListRow(title: "代理",
                                  subtitle: localProxy.isRunning ? "127.0.0.1:" + String(localProxy.port) : "未启动") {
                            Toggle("", isOn: Binding(
                                get: { localProxy.isRunning },
                                set: { on in if on { localProxy.start() } else { localProxy.stop() } }
                            ))
                            .labelsHidden()
                            .tint(LP.accent)
                        }

                        LPListRow(title: "系统接管",
                                  subtitle: tunnel.lastError ?? (tunnel.isInstalled ? nil : "需要 network-extension 权限"),
                                  value: nil, isLast: true) {
                            Toggle("", isOn: Binding(
                                get: { tunnel.status == .connected },
                                set: { on in
                                    if on { Task { await tunnel.start() } } else { tunnel.stop() }
                                }
                            ))
                            .labelsHidden()
                            .tint(LP.accent)
                        }
                    }

                    LPSection(header: "网络") {
                        LPListRow(title: "局域网地址", value: localAddress ?? "读取中…", mono: true)
                        LPListRow(title: "公网出口",
                                  value: publicAddress ?? (loadingPublic ? "查询中…" : "未获取"),
                                  mono: true, isLast: publicError == nil) {
                            Button(loadingPublic ? "…" : "刷新") {
                                Task { await loadPublicAddress() }
                            }
                            .font(.system(size: 15))
                            .foregroundStyle(LP.accent)
                            .buttonStyle(.plain)
                            .disabled(loadingPublic)
                        }
                        if let publicError {
                            LPListRow(title: publicError, isLast: true) { EmptyView() }
                        }
                    }

                    LPSection(header: "DNS 解析", footer: dnsFooter) {
                        LPListRow(title: "域名", isLast: dnsResult.isEmpty) {
                            TextField("example.com", text: $host)
                                .font(.system(size: 15, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .multilineTextAlignment(.trailing)
                            Button(checkingDNS ? "…" : "解析") { Task { await resolve() } }
                                .font(.system(size: 15))
                                .foregroundStyle(LP.accent)
                                .buttonStyle(.plain)
                                .disabled(checkingDNS)
                        }
                        if !dnsResult.isEmpty {
                            ForEach(Array(dnsResult.enumerated()), id: \.offset) { index, ip in
                                LPListRow(title: ip, mono: true,
                                          isLast: index == dnsResult.count - 1) { EmptyView() }
                            }
                        }
                    }

                    LPSection(header: "HTTP 探测", footer: probeFooter) {
                        LPListRow(title: "地址", isLast: probeStatus == nil) {
                            TextField("https://…", text: $url)
                                .font(.system(size: 15, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .multilineTextAlignment(.trailing)
                            Button(probing ? "…" : "探测") { Task { await probe() } }
                                .font(.system(size: 15))
                                .foregroundStyle(LP.accent)
                                .buttonStyle(.plain)
                                .disabled(probing)
                        }
                        if let probeStatus {
                            LPListRow(title: "结果",
                                      value: probeElapsed.map { String(format: "%d · %.0f ms", probeStatus, $0 * 1000) }
                                        ?? "\(probeStatus)",
                                      mono: true, isLast: true) { EmptyView() }
                        }
                    }

                    if store.endpoint == nil {
                        LPSection(header: "Mac", footer: "控制台页可以从 Mac 读取分流、连接与抓包；工具不依赖它。") {
                            LPListRow(title: "连接 Mac", showsChevron: true, isLast: true) {
                                EmptyView()
                            }
                            .onTapGesture { store.pairingSheetShown = true }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(LP.groupedBackground)
            .contentMargins(.bottom, 84, for: .scrollContent)
            .navigationTitle("工具")
            .navigationBarTitleDisplayMode(.large)
            .task {
                localAddress = Self.wifiAddress()
                if publicAddress == nil { await loadPublicAddress() }
            }
        }
    }

    private var dnsFooter: String? {
        guard let dnsElapsed else { return dnsError }
        return String(format: "%.0f ms · %d 条", dnsElapsed * 1000, dnsResult.count)
    }

    private var probeFooter: String? { probeError }

    // MARK: - Pieces

    private func field(text: Binding<String>, placeholder: String, keyboard: UIKeyboardType) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 13, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboard)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(LP.panelRaised, in: RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous)
                    .strokeBorder(LP.stroke, lineWidth: 1)
            )
    }


    /// One capability line: state dot, name, detail, and a quiet text action.
    /// Two big cards with two big buttons made the page feel like a control panel
    /// with no priority; this keeps the same facts in half the space.
    @ViewBuilder
    private func engineRow(title: String, detail: String, active: Bool,
                           action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(active ? LP.mint : LP.textTertiary.opacity(0.45))
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LP.text)
            Text(detail)
                .font(LPFont.mono(11))
                .foregroundStyle(active ? LP.mint : LP.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action) { perform() }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LP.accent)
                .buttonStyle(.plain)
        }
    }

    private func actionButton(title: String, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy { ProgressView().tint(.white).scaleEffect(0.7) }
                Text(busy ? "处理中…" : title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(LPButtonStyle())
        .disabled(busy)
    }

    // MARK: - Actions

    private func loadPublicAddress() async {
        loadingPublic = true
        publicError = nil
        defer { loadingPublic = false }
        do {
            // Several endpoints, because one unreachable host made this page look
            // broken on the very networks the app is meant for.
            publicAddress = try await PublicAddress.fetch()
        } catch {
            publicError = "公网地址查询失败：\(error.localizedDescription)"
        }
    }

    private func resolve() async {
        let name = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            dnsError = "请输入域名"
            return
        }
        checkingDNS = true
        dnsError = nil
        dnsResult = []
        dnsElapsed = nil
        defer { checkingDNS = false }

        struct LookupError: Error {}
        let started = Date()
        do {
            let addresses: [String] = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                                         ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                                         ai_addr: nil, ai_next: nil)
                    var result: UnsafeMutablePointer<addrinfo>?
                    let status = getaddrinfo(name, nil, &hints, &result)
                    guard status == 0, let head = result else {
                        continuation.resume(throwing: LookupError())
                        return
                    }
                    defer { freeaddrinfo(head) }
                    var seen = Set<String>()
                    var out: [String] = []
                    var node: UnsafeMutablePointer<addrinfo>? = head
                    while let current = node {
                        defer { node = current.pointee.ai_next }
                        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen,
                                       &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                            let ip = String(cString: buffer)
                            if seen.insert(ip).inserted { out.append(ip) }
                        }
                    }
                    continuation.resume(returning: out)
                }
            }
            dnsElapsed = Date().timeIntervalSince(started)
            dnsResult = addresses
            if addresses.isEmpty { dnsError = "没有解析结果" }
        } catch {
            dnsError = "解析失败，检查域名或网络"
        }
    }

    private func probe() async {
        let target = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: target), parsed.scheme != nil else {
            probeError = "请输入完整 URL"
            return
        }
        probing = true
        probeError = nil
        probeStatus = nil
        probeElapsed = nil
        defer { probing = false }

        var request = URLRequest(url: parsed)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        let started = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            probeElapsed = Date().timeIntervalSince(started)
            probeStatus = (response as? HTTPURLResponse)?.statusCode
        } catch {
            probeError = "请求失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Local address

    /// IPv4 address of the active Wi-Fi/Ethernet interface, read from getifaddrs.
    static func wifiAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var fallback: String?
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let current = node {
            defer { node = current.pointee.ifa_next }
            let interface = current.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if name == "en0" { return ip }
            if fallback == nil, !ip.hasPrefix("127.") { fallback = ip }
        }
        return fallback
    }
}

/// Explains the optional Mac link without blocking anything on this page.
private struct MacLinkCard: View {
    @Environment(ConsoleStore.self) private var store
    @State private var showSetup = false

    var body: some View {
        LPCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: store.endpoint == nil ? "desktopcomputer" : "checkmark.seal.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(store.endpoint == nil ? LP.textTertiary : LP.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.endpoint == nil ? "未连接 Mac" : "已连接 \(store.endpoint?.displayAddress ?? "")")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LP.text)
                    Text(store.endpoint == nil
                         ? "连接后可查看 Mac 的分流、连接与抓包；下面这些工具不需要连接。"
                         : "状态、连接、策略、诊断四个页面可用。")
                        .font(.system(size: 11))
                        .foregroundStyle(LP.textTertiary)
                }
                Spacer(minLength: 0)
                if store.endpoint == nil {
                    Button("连接") { showSetup = true }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LP.accent)
                }
            }
        }
        .sheet(isPresented: $showSetup) {
            NavigationStack {
                SetupView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("关闭") { showSetup = false }
                        }
                    }
            }
            .onChange(of: store.endpoint) { _, value in
                if value != nil { showSetup = false }
            }
        }
    }
}
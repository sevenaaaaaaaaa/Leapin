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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    MacLinkCard()

                    LPCard(title: "本机网络", subtitle: "不需要连接 Mac") {
                        VStack(spacing: 7) {
                            LPRow(key: "局域网地址", value: localAddress ?? "读取中…", mono: true)
                            LPRow(key: "公网出口", value: publicAddress ?? (loadingPublic ? "查询中…" : "未获取"),
                                  mono: true)
                            if let publicError {
                                Text(publicError).font(.system(size: 11)).foregroundStyle(LP.danger)
                            }
                        }
                        Button {
                            Task { await loadPublicAddress() }
                        } label: {
                            Text(loadingPublic ? "查询中…" : "刷新公网地址")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(LP.accent)
                        .disabled(loadingPublic)
                    }

                    LPCard(title: "DNS 解析", subtitle: "直接在本机解析，不经 Mac") {
                        field(text: $host, placeholder: "example.com", keyboard: .URL)
                        actionButton(title: "解析", busy: checkingDNS) {
                            Task { await resolve() }
                        }
                        if let dnsError {
                            Text(dnsError).font(.system(size: 11)).foregroundStyle(LP.danger)
                        }
                        if !dnsResult.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                if let dnsElapsed {
                                    Text(String(format: "%.0f ms · %d 条", dnsElapsed * 1000, dnsResult.count))
                                        .font(.system(size: 10))
                                        .foregroundStyle(LP.textTertiary)
                                }
                                ForEach(dnsResult, id: \.self) { ip in
                                    Text(ip).font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(LP.textSecondary)
                                }
                            }
                        }
                    }

                    LPCard(title: "HTTP 探测", subtitle: "从手机直接发请求") {
                        field(text: $url, placeholder: "https://…", keyboard: .URL)
                        actionButton(title: "探测", busy: probing) {
                            Task { await probe() }
                        }
                        if let probeError {
                            Text(probeError).font(.system(size: 11)).foregroundStyle(LP.danger)
                        }
                        if let probeStatus {
                            HStack(spacing: 8) {
                                LPPill(text: "\(probeStatus)",
                                       tint: (200..<400).contains(probeStatus) ? LP.mint : LP.amber,
                                       filled: true)
                                if let probeElapsed {
                                    Text(String(format: "%.0f ms", probeElapsed * 1000))
                                        .font(.system(size: 11))
                                        .foregroundStyle(LP.textTertiary)
                                }
                            }
                        }
                    }

                    Text("需要查看 Mac 的分流、连接与抓包时，再在下方连接一次即可。工具页始终可用。")
                        .font(.system(size: 11))
                        .foregroundStyle(LP.textTertiary)
                        .padding(.horizontal, 2)
                }
                .lpPage()
            }
            .background(LP.canvas)
            .navigationTitle("工具")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                localAddress = Self.wifiAddress()
                if publicAddress == nil { await loadPublicAddress() }
            }
        }
    }

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
            var request = URLRequest(url: URL(string: "https://api.ipify.org")!)
            request.timeoutInterval = 8
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) else {
                throw URLError(.cannotParseResponse)
            }
            publicAddress = text.trimmingCharacters(in: .whitespacesAndNewlines)
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

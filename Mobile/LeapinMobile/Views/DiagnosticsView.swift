import SwiftUI
import LeapinCore
import LeapinControl

struct DiagnosticsView: View {
    @Environment(ConsoleStore.self) private var store

    private enum Tool: String, CaseIterable {
        case ruleMatch = "分流判定"
        case dns = "DNS 追踪"
        case http = "HTTP 探测"
    }

    @State private var tool: Tool = .ruleMatch
    @State private var hostInput = ""
    @State private var portInput = "443"
    @State private var urlInput = "https://example.com"
    @State private var isRunning = false

    @State private var explain: ControlExplainResult?
    @State private var trace: DNSTrace?
    @State private var probe: HTTPProbeResult?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("工具", selection: $tool) {
                        ForEach(Tool.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: tool) { _, _ in reset() }

                    inputCard

                    Button {
                        Task { await run() }
                    } label: {
                        HStack(spacing: 8) {
                            if isRunning { ProgressView().tint(.white).scaleEffect(0.8) }
                            Text(isRunning ? "正在执行…" : "执行")
                        }
                    }
                    .buttonStyle(LPButtonStyle())
                    .disabled(isRunning)

                    if let failure {
                        LPCard {
                            Text(failure)
                                .font(LPFont.caption)
                                .foregroundStyle(LP.danger)
                        }
                    }

                    resultSection
                }
                .lpPage()
            }
            .background(LP.canvas)
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var inputCard: some View {
        LPCard(title: tool.rawValue, subtitle: subtitleForTool) {
            VStack(spacing: 10) {
                switch tool {
                case .ruleMatch, .dns:
                    HStack(spacing: 10) {
                        TextField("域名，如 www.example.com", text: $hostInput)
                            .font(LPFont.mono(13))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 10)
                    .background(LP.panelRaised, in: RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous)
                        .strokeBorder(LP.stroke, lineWidth: 1))

                    if tool == .ruleMatch {
                        HStack(spacing: 10) {
                            Text("端口")
                                .font(LPFont.caption)
                                .foregroundStyle(LP.textTertiary)
                            TextField("443", text: $portInput)
                                .font(LPFont.mono(13))
                                .keyboardType(.numberPad)
                            Spacer()
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 10)
                        .background(LP.panelRaised, in: RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous)
                            .strokeBorder(LP.stroke, lineWidth: 1))
                    }

                case .http:
                    TextField("https://…", text: $urlInput)
                        .font(LPFont.mono(13))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 10)
                        .background(LP.panelRaised, in: RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous)
                            .strokeBorder(LP.stroke, lineWidth: 1))
                }
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        switch tool {
        case .ruleMatch:
            if let explain { explainCard(explain) }
        case .dns:
            if let trace { traceCard(trace) }
        case .http:
            if let probe { probeCard(probe) }
        }
    }

    private func explainCard(_ result: ControlExplainResult) -> some View {
        LPCard(title: "判定结果", subtitle: "\(result.host):\(result.port)") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    LPPill(text: result.policy.isEmpty ? "未知" : result.policy,
                           tint: result.isBlocked ? LP.danger : LP.accent, filled: true)
                    if !result.outbound.isEmpty {
                        Text("→ \(result.outbound)")
                            .font(LPFont.mono(11))
                            .foregroundStyle(LP.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                if !result.matchedRule.isEmpty {
                    LPRow(key: "命中规则", value: result.matchedRule, mono: true)
                }
                if !result.chainSummary.isEmpty {
                    LPRow(key: "链路", value: result.chainSummary, mono: true)
                }
                if !result.trace.isEmpty {
                    Divider().overlay(LP.stroke)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(result.trace.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(LPFont.mono(10))
                                .foregroundStyle(LP.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if !result.diagnostics.isEmpty {
                    Divider().overlay(LP.stroke)
                    Text("规则诊断")
                        .font(LPFont.micro)
                        .foregroundStyle(LP.textTertiary)
                    ForEach(Array(result.diagnostics.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.raw)
                                .font(LPFont.mono(10))
                                .foregroundStyle(LP.textSecondary)
                            Text(item.reason)
                                .font(LPFont.micro)
                                .foregroundStyle(LP.amber)
                        }
                    }
                }
            }
        }
    }

    private func traceCard(_ result: DNSTrace) -> some View {
        LPCard(title: "DNS 解析", subtitle: result.host) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    LPPill(text: sourceLabel(result.source.rawValue), tint: LP.violet)
                    Text(LPFormat.milliseconds(result.elapsedMs))
                        .font(LPFont.mono(11))
                        .foregroundStyle(LP.textTertiary)
                    Spacer(minLength: 0)
                }
                if let upstream = result.upstream, !upstream.isEmpty {
                    LPRow(key: "上游", value: upstream, mono: true)
                }
                if !result.resolved.isEmpty {
                    LPRow(key: "结果", value: result.resolved.joined(separator: "\n"), mono: true)
                }
                if let error = result.error, !error.isEmpty {
                    Text(error)
                        .font(LPFont.caption)
                        .foregroundStyle(LP.danger)
                }
                if !result.steps.isEmpty {
                    Divider().overlay(LP.stroke)
                    ForEach(Array(result.steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text(step.stage)
                                .font(LPFont.micro)
                                .foregroundStyle(LP.accent)
                                .frame(width: 76, alignment: .leading)
                            Text(step.detail)
                                .font(LPFont.mono(10))
                                .foregroundStyle(LP.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(LPFormat.milliseconds(step.elapsedMs))
                                .font(LPFont.mono(9))
                                .foregroundStyle(LP.textTertiary)
                        }
                    }
                }
            }
        }
    }

    private func probeCard(_ result: HTTPProbeResult) -> some View {
        LPCard(title: "HTTP 探测", subtitle: result.url) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    if let code = result.statusCode {
                        LPPill(text: "\(code)", tint: (200..<400).contains(code) ? LP.mint : LP.amber, filled: true)
                    }
                    if result.tls {
                        LPPill(text: "TLS", tint: LP.mint)
                    }
                    if let version = result.httpVersion {
                        LPPill(text: version, tint: LP.violet)
                    }
                    Spacer(minLength: 0)
                    Text(LPFormat.milliseconds(result.elapsedMs))
                        .font(LPFont.mono(11))
                        .foregroundStyle(LP.textTertiary)
                }
                if let address = result.remoteAddress {
                    LPRow(key: "远端", value: address, mono: true)
                }
                LPRow(key: "头/体", value: "\(LPFormat.bytes(Int64(result.headerBytes))) / \(LPFormat.bytes(Int64(result.bodyBytes)))", mono: true)
                if result.redirects > 0 {
                    LPRow(key: "跳转", value: "\(result.redirects) 次")
                }
                if let error = result.error, !error.isEmpty {
                    Text(error)
                        .font(LPFont.caption)
                        .foregroundStyle(LP.danger)
                }
            }
        }
    }

    private var subtitleForTool: String {
        switch tool {
        case .ruleMatch: return "这个域名会走哪条策略"
        case .dns: return "解析过程与上游"
        case .http: return "从 Mac 发起请求，看真实结果"
        }
    }

    private func sourceLabel(_ raw: String) -> String {
        switch raw {
        case "cache": return "缓存"
        case "fakeip": return "FakeIP"
        case "upstream": return "上游"
        case "system": return "系统"
        default: return raw
        }
    }

    private func reset() {
        explain = nil
        trace = nil
        probe = nil
        failure = nil
    }

    private func run() async {
        failure = nil
        isRunning = true
        defer { isRunning = false }

        switch tool {
        case .ruleMatch:
            let host = hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { failure = "请填写域名"; return }
            let port = Int(portInput.trimmingCharacters(in: .whitespaces)) ?? 443
            explain = await store.explain(host: host, port: port)
            if explain == nil { failure = store.lastError ?? "判定失败" }

        case .dns:
            let host = hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { failure = "请填写域名"; return }
            trace = await store.dnsTrace(host: host)
            if trace == nil { failure = store.lastError ?? "解析失败" }

        case .http:
            let url = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { failure = "请填写 URL"; return }
            probe = await store.httpProbe(url: url)
            if probe == nil { failure = store.lastError ?? "探测失败" }
        }
    }
}

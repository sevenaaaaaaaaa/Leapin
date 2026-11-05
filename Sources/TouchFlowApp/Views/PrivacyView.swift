import SwiftUI
import TouchFlowCore
import TouchFlowIntegrations
import TouchFlowPolicy
import TouchFlowNet
import TouchFlowRuntime

@MainActor
struct PrivacyView: View {
    @ObservedObject private var engine = TouchFlowEngine.shared
    @EnvironmentObject private var app: AppModel

    private let trackerDomains: Set<String> = [
        "doubleclick.net", "google-analytics.com", "googletagmanager.com", "googleadservices.com",
        "googlesyndication.com", "app-measurement.com", "crashlytics.com", "connect.facebook.net",
        "graph.facebook.com", "analytics.twitter.com", "ads-twitter.com", "ads.linkedin.com",
        "appsflyer.com", "adjust.com", "branch.io", "kochava.com", "amplitude.com", "mixpanel.com",
        "segment.io", "hotjar.com", "fullstory.com", "sentry.io", "bugsnag.com", "scorecardresearch.com",
        "quantserve.com", "criteo.com", "taboola.com", "outbrain.com", "moatads.com", "adnxs.com",
    ]

    private var report: PrivacyReport {
        PrivacyAudit.audit(flows: engine.flows, trackerDomains: trackerDomains)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                HStack(alignment: .top, spacing: 16) {
                    checklist
                    findings
                }
            }
            .pagePadding()
        }
        .navigationTitle("隐私")
    }

    private var header: some View {
        let r = report
        return HStack(spacing: 20) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 10).frame(width: 86, height: 86)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(100, r.score))) / 100)
                    .stroke(scoreColor(r.score), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 86, height: 86)
                VStack(spacing: 0) {
                    Text("\(r.score)").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("分").font(.caption2).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("隐私健康度").font(.title3.weight(.semibold))
                Text("已拦截 \(r.trackersBlocked) 次跟踪器请求 · 发现 \(r.findings.count) 个风险项")
                    .font(.callout).foregroundStyle(.secondary)
                Text("评分基于跟踪器拦截、DNS 加密、HTTPS 解密开关与日志脱敏状态。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(18)
        .background(
            LinearGradient(colors: [scoreColor(r.score).opacity(0.16), .clear], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private var checklist: some View {
        Card(title: "加固清单", icon: "checkmark.shield") {
            check("DNS over HTTPS / TLS", engine.profile.dns.mode != .system,
                  engine.profile.dns.mode == .system ? "当前使用系统 DNS，易被本地劫持" : "已加密 DNS（\(engine.profile.dns.mode.rawValue)）")
            check("广告与跟踪器拦截", engine.profile.adblock.enabled && engine.adblockActive,
                  "\(engine.adblockRuleCount) 条规则生效")
            check("HTTPS 解密默认关闭", !engine.profile.general.mitmEnabled,
                  engine.profile.general.mitmEnabled ? "已开启 MITM：出站证书由本机 CA 签发" : "未开启，抓包只见明文")
            check("日志自动脱敏", true, "Authorization / Cookie / token 等在写入前被替换")
            check("凭据保存在钥匙串", true, "SSH / NAS 密码可选择仅存 Keychain")
            check("系统代理可一键关闭", !engine.systemProxyActive || engine.state == .running,
                  engine.systemProxyActive ? "当前已接管系统代理" : "未接管")
            Divider().padding(.vertical, 4)
            Text("搭配建议：与 Little Snitch / LuLu 一起使用——它们管出站进程，本工具管域名分流与去广告；再把浏览器切到 NextDNS 或 DoH，三层互补。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var findings: some View {
        Card(title: "发现", subtitle: report.findings.isEmpty ? nil : "\(report.findings.count) 项", icon: "exclamationmark.triangle") {
            if report.findings.isEmpty {
                EmptyHint(icon: "checkmark.seal", text: "暂无跟踪器流量。启动代理并浏览一段时间后再回来看。")
                    .frame(height: 180)
            } else {
                ForEach(report.findings.prefix(30)) { finding in
                    HStack(spacing: 8) {
                        Circle().fill(severityColor(finding.severity)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(finding.domain).font(.callout.monospaced()).lineLimit(1)
                            Text("\(finding.app) · \(finding.category)").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("加入拦截") {
                            engine.updateProfile(restart: true) { profile in
                                let rule = "||\(finding.domain)^"
                                if !profile.adblock.blockLists.contains(rule) {
                                    profile.adblock.blockLists.append(rule)
                                }
                            }
                            app.toast = "已加入拦截：\(finding.domain)"
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func check(_ title: String, _ ok: Bool, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }

    private func scoreColor(_ score: Int) -> Color {
        score >= 80 ? .green : score >= 55 ? .orange : .red
    }
    private func severityColor(_ s: Int) -> Color {
        s >= 3 ? .red : s == 2 ? .orange : .yellow
    }
}

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
                hero
                HStack(alignment: .top, spacing: 16) {
                    checklist
                    findings
                }
            }
            .pagePadding()
        }
    }

    // MARK: Hero

    private var hero: some View {
        let r = report
        let tint = scoreColor(r.score)
        return HStack(spacing: 26) {
            scoreRing(r.score, tint: tint)
            VStack(alignment: .leading, spacing: 8) {
                Text("隐私健康度")
                    .font(TFFont.overline)
                    .tracking(1.1)
                    .foregroundStyle(TF.textTertiary)
                Text(scoreHeadline(r.score))
                    .font(TFFont.display(20, weight: .bold))
                    .foregroundStyle(TF.text)
                Text("评分基于跟踪器拦截、DNS 加密、HTTPS 解密开关、日志脱敏与凭据存储。")
                    .font(.system(size: 11))
                    .foregroundStyle(TF.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    miniStat("已拦截", "\(r.trackersBlocked)", TF.mint)
                    miniStat("风险项", "\(r.findings.count)", r.findings.isEmpty ? TF.mint : TF.amber)
                    miniStat("拦截规则", "\(engine.adblockRuleCount)", TF.accent)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(TF.panel)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.16), .clear],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(TF.strokeStrong, lineWidth: 1)
            }
        )
    }

    private func scoreRing(_ score: Int, tint: Color) -> some View {
        ZStack {
            Circle()
                .stroke(TF.strokeStrong.opacity(0.5), lineWidth: 9)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, score))) / 100)
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.55), tint, tint.opacity(0.75)],
                                    center: .center),
                    style: StrokeStyle(lineWidth: 9, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Circle()
                .fill(tint.opacity(0.07))
                .padding(14)
            VStack(spacing: 0) {
                Text("\(score)")
                    .font(TFFont.num(30, weight: .bold))
                    .foregroundStyle(TF.text)
                Text("分")
                    .font(.system(size: 9.5))
                    .foregroundStyle(TF.textTertiary)
            }
        }
        .frame(width: 106, height: 106)
        .shadow(color: tint.opacity(0.22), radius: 18)
    }

    private func miniStat(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .font(TFFont.num(12, weight: .bold))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(TF.textSecondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(TF.stroke.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: Checklist

    private var checklist: some View {
        Card(title: "加固清单", subtitle: "逐项核对的隐私设置", icon: "checkmark.shield") {
            VStack(spacing: 0) {
                check("DNS over HTTPS / TLS", engine.profile.dns.mode != .system,
                      engine.profile.dns.mode == .system ? "当前使用系统 DNS，易被本地劫持" : "已加密 DNS（\(engine.profile.dns.mode.rawValue)）")
                TFDivider().opacity(0.5).padding(.vertical, 4)
                check("广告与跟踪器拦截", engine.profile.adblock.enabled && engine.adblockActive,
                      "\(engine.adblockRuleCount) 条规则生效")
                TFDivider().opacity(0.5).padding(.vertical, 4)
                check("HTTPS 解密默认关闭", !engine.profile.general.mitmEnabled,
                      engine.profile.general.mitmEnabled ? "已开启 MITM：出站证书由本机 CA 签发" : "未开启，抓包只见明文")
                TFDivider().opacity(0.5).padding(.vertical, 4)
                check("日志自动脱敏", true, "Authorization / Cookie / token 等在写入前被替换")
                TFDivider().opacity(0.5).padding(.vertical, 4)
                check("凭据保存在钥匙串", true, "SSH / NAS 密码可选择仅存 Keychain")
                TFDivider().opacity(0.5).padding(.vertical, 4)
                check("系统代理可一键关闭", !engine.systemProxyActive || engine.state == .running,
                      engine.systemProxyActive ? "当前已接管系统代理" : "未接管")

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(TF.violet)
                    Text("搭配 Little Snitch / LuLu 管出站进程，本工具管域名分流与去广告，再把浏览器切到 NextDNS 或 DoH——三层互补。")
                        .font(.system(size: 10))
                        .foregroundStyle(TF.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(TF.stroke.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Findings

    private var findings: some View {
        Card(title: "发现", subtitle: report.findings.isEmpty ? nil : "\(report.findings.count) 项", icon: "exclamationmark.triangle") {
            if report.findings.isEmpty {
                EmptyHint(icon: "checkmark.seal", text: "暂无跟踪器流量\n启动代理并浏览一段时间后再回来看看")
                    .frame(height: 200)
            } else {
                VStack(spacing: 0) {
                    ForEach(report.findings.prefix(30)) { finding in
                        HStack(spacing: 9) {
                            Circle()
                                .fill(severityColor(finding.severity))
                                .frame(width: 6, height: 6)
                                .shadow(color: severityColor(finding.severity).opacity(0.5), radius: 3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(finding.domain)
                                    .font(TFFont.mono(11))
                                    .foregroundStyle(TF.text)
                                    .lineLimit(1)
                                Text("\(finding.app) · \(finding.category)")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(TF.textTertiary)
                            }
                            Spacer(minLength: 8)
                            Button("加入拦截") {
                                engine.updateProfile(restart: true) { profile in
                                    let rule = "||\(finding.domain)^"
                                    if !profile.adblock.blockLists.contains(rule) {
                                        profile.adblock.blockLists.append(rule)
                                    }
                                }
                                app.toast = "已加入拦截：\(finding.domain)"
                            }
                            .buttonStyle(TFGhostButtonStyle())
                        }
                        .padding(.vertical, 5)
                        TFDivider().opacity(0.5)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func check(_ title: String, _ ok: Bool, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(ok ? TF.mint : TF.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(TF.text)
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(TF.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func scoreHeadline(_ score: Int) -> String {
        score >= 85 ? "防护状态良好" : score >= 60 ? "还有几处可以加强" : "建议先完成基础加固"
    }

    private func scoreColor(_ score: Int) -> Color {
        score >= 80 ? TF.mint : score >= 55 ? TF.amber : TF.danger
    }
    private func severityColor(_ s: Int) -> Color {
        s >= 3 ? TF.danger : s == 2 ? TF.amber : TF.textTertiary
    }
}

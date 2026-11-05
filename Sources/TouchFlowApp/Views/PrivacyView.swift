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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let trackerDomains: Set<String> = [
        "doubleclick.net", "google-analytics.com", "googletagmanager.com", "googleadservices.com",
        "googlesyndication.com", "app-measurement.com", "crashlytics.com", "connect.facebook.net",
        "graph.facebook.com", "analytics.twitter.com", "ads-twitter.com", "ads.linkedin.com",
        "appsflyer.com", "adjust.com", "branch.io", "kochava.com", "amplitude.com", "mixpanel.com",
        "segment.io", "hotjar.com", "fullstory.com", "sentry.io", "bugsnag.com", "scorecardresearch.com",
        "quantserve.com", "criteo.com", "taboola.com", "outbrain.com", "moatads.com", "adnxs.com",
    ]

    /// 全量审计有成本：按抓包数量节流重算，避免每条请求都重扫全部 flow。
    @State private var report = PrivacyAudit.audit(flows: [], trackerDomains: [])

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                hero
                HStack(alignment: .top, spacing: 22) {
                    checklist
                    findings
                }
            }
            .pagePadding()
            .navigationTitle("隐私")
        }
        .task(id: engine.stats.captures) {
            // 600ms 合并窗口：抓包高峰期的连续事件只触发一次审计。
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            report = PrivacyAudit.audit(flows: engine.flows, trackerDomains: trackerDomains)
        }
    }

    // MARK: Hero

    /// 没有任何抓包样本时，分数无从谈起：宁可显示「—」，也不给一个凭空的 100。
    private var hasSample: Bool {
        engine.stats.captures > 0 || !engine.flows.isEmpty
    }

    private var hero: some View {
        let r = report
        let tint = hasSample ? scoreColor(r.score) : TF.textTertiary
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 30) {
                VStack(alignment: .leading, spacing: 10) {
                    TFEyebrow(text: "隐私健康度 / PRIVACY SCORE")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if hasSample {
                            Text("\(r.score)")
                                .font(TFFont.num(48, weight: .medium))
                                .foregroundStyle(TF.text)
                                .contentTransition(.numericText())
                                .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: r.score)
                            Text("/100")
                                .font(TFFont.mono(13))
                                .foregroundStyle(TF.textTertiary)
                        } else {
                            // 读数位保持高度，但不伪造一个数字：34pt 的「无样本」比 48pt 破折号诚实也更好看。
                            Text("无样本")
                                .font(TFFont.display(34, weight: .semibold))
                                .foregroundStyle(TF.textTertiary)
                                .contentTransition(.opacity)
                        }
                    }
                    scoreRuler(hasSample ? r.score : 0, tint: tint, insufficient: !hasSample)
                        .opacity(hasSample ? 1 : 0.55)
                }

                Rectangle()
                    .fill(TF.stroke)
                    .frame(width: 1, height: 84)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Circle().fill(tint).frame(width: 6, height: 6)
                        Text(hasSample ? scoreHeadline(r.score) : "样本不足，先抓一段流量")
                            .font(TFFont.display(15, weight: .semibold))
                            .foregroundStyle(TF.text)
                    }
                    Text(hasSample
                         ? "评分基于跟踪器拦截、DNS 加密、HTTPS 解密开关、日志脱敏与凭据存储。"
                         : "下面三项是本次会话的真实计数；没有流量时显示「—」，评分留空。")
                        .font(.system(size: 12))
                        .foregroundStyle(TF.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(hasSample
                         ? "低于 55 建议先完成基础加固；80 以上视为防护到位。"
                         : "启动代理并浏览一会儿，样本足够后这里会给出分数。")
                        .font(.system(size: 12))
                        .foregroundStyle(TF.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(18)

            TFDivider()

            HStack(spacing: 0) {
                metric("已拦截 / BLOCKED", hasSample ? "\(r.trackersBlocked)" : "—")
                Rectangle().fill(TF.stroke).frame(width: 1, height: 44)
                metric("风险项 / FINDINGS", hasSample ? "\(r.findings.count)" : "—")
                Rectangle().fill(TF.stroke).frame(width: 1, height: 44)
                metric("拦截规则 / RULES", "\(engine.adblockRuleCount)")
            }
            .padding(.vertical, 2)
        }
        .tfPanel(padding: 0)
    }

    /// 2px 刻度尺：55 / 80 两个阈值把分数分成「需加固 / 可加强 / 良好」三段。
    private func scoreRuler(_ score: Int, tint: Color, insufficient: Bool = false) -> some View {
        let clamped = CGFloat(min(max(score, 0), 100)) / 100
        return GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                Capsule().fill(TF.strokeStrong.opacity(0.35)).frame(width: w, height: 3)
                Capsule().fill(tint).frame(width: max(3, w * clamped), height: 3)
                    .opacity(insufficient ? 0 : 1)
                ForEach([0.55, 0.80], id: \.self) { threshold in
                    Rectangle()
                        .fill(TF.text.opacity(0.45))
                        .frame(width: 1, height: 8)
                        .offset(x: w * threshold - 0.5, y: -2.5)
                }
                Group {
                    Text("0").position(x: 5, y: 15)
                    Text("55").position(x: w * 0.55, y: 15)
                    Text("80").position(x: w * 0.80, y: 15)
                    Text("100").position(x: w - 12, y: 15)
                }
                .font(TFFont.mono(9))
                .foregroundStyle(TF.textTertiary)
            }
            .frame(width: w, height: 24)
        }
        .frame(width: 320, height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("隐私评分 \(score) 分，满分 100，55 分与 80 分为阈值")
    }

    private func metric(_ label: String, _ value: String) -> some View {
        let placeholder = value == "—"
        return VStack(alignment: .leading, spacing: 7) {
            TFEyebrow(text: label)
            Text(value)
                .font(TFFont.num(placeholder ? 20 : 26, weight: .medium))
                .foregroundStyle(placeholder ? TF.textTertiary : TF.text)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: Checklist

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "加固清单", subtitle: "逐项核对的隐私设置", icon: "checkmark.shield")
                .padding(18)

            TFDivider()

            VStack(spacing: 0) {
                check("DNS over HTTPS / TLS", engine.profile.dns.mode != .system,
                      engine.profile.dns.mode == .system ? "当前使用系统 DNS，易被本地劫持" : "已加密 DNS（\(engine.profile.dns.mode.rawValue)）")
                TFDivider()
                check("广告与跟踪器拦截", engine.profile.adblock.enabled && engine.adblockActive,
                      "\(engine.adblockRuleCount) 条规则生效")
                TFDivider()
                check("HTTPS 解密默认关闭", !engine.profile.general.mitmEnabled,
                      engine.profile.general.mitmEnabled ? "已开启 MITM：出站证书由本机 CA 签发" : "未开启，抓包只见明文")
                TFDivider()
                note("抓包与导出脱敏", "详情面板与 HAR 导出前由 Redactor 替换 Authorization / Cookie / token")
                TFDivider()
                note("凭据存储", "SSH / NAS 密码可选仅存 Keychain，可在「钥匙串访问」中核对")
                TFDivider()
                check("系统代理可一键关闭", !engine.systemProxyActive || engine.state == .running,
                      engine.systemProxyActive ? "当前已接管系统代理" : "未接管")
            }
            .padding(.horizontal, 18)

            TFDivider()

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.textTertiary)
                Text("搭配 Little Snitch / LuLu 管出站进程，本工具管域名分流与去广告，再把浏览器切到 NextDNS 或 DoH——三层互补。")
                    .font(.system(size: 12))
                    .foregroundStyle(TF.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .tfPanel(padding: 0)
        .frame(maxWidth: .infinity)
    }

    // MARK: Findings

    private var findings: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "发现",
                          subtitle: report.findings.isEmpty ? nil : "\(report.findings.count) 项",
                          icon: "exclamationmark.triangle")
                .padding(18)

            TFDivider()

            if report.findings.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(TF.textTertiary)
                    Text("暂未发现跟踪器流量")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(TF.textSecondary)
                    Text("启动系统代理并浏览一段时间，这里会按域名列出命中的跟踪器。")
                        .font(.system(size: 12))
                        .foregroundStyle(TF.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                    Button("去抓包") { app.go(to: .capture) }
                        .buttonStyle(TFGhostButtonStyle())
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
            } else {
                VStack(spacing: 0) {
                    ForEach(report.findings.prefix(30)) { finding in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(severityColor(finding.severity))
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(finding.domain)
                                    .font(TFFont.mono(12, weight: .medium))
                                    .foregroundStyle(TF.text)
                                    .lineLimit(1)
                                Text("\(finding.app) · \(finding.category)")
                                    .font(TFFont.mono(10))
                                    .foregroundStyle(TF.textTertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Button {
                                block(finding.domain)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus").font(.system(size: 8, weight: .bold))
                                    Text("加入拦截").font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(TF.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(TF.stroke, lineWidth: 1)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("将 \(finding.domain) 加入拦截")
                        }
                        .padding(.vertical, 11)
                        TFDivider()
                    }
                }
                .padding(.horizontal, 18)
            }
        }
        .tfPanel(padding: 0)
        .frame(maxWidth: .infinity)
    }

    private func block(_ domain: String) {
        var added = false
        engine.updateProfile(restart: true) { profile in
            let exists = profile.rules.contains {
                $0.kind == .domainSuffix && $0.value.caseInsensitiveCompare(domain) == .orderedSame
            }
            if !exists {
                profile.rules.append(Rule(kind: .domainSuffix, value: domain, policy: "REJECT",
                                          raw: "DOMAIN-SUFFIX,\(domain),REJECT"))
                added = true
            }
        }
        if added {
            app.showToast("已加入拦截：\(domain)", kind: .success, actionTitle: "撤销") {
                engine.updateProfile(restart: true) { profile in
                    profile.rules.removeAll {
                        $0.kind == .domainSuffix
                            && $0.value.caseInsensitiveCompare(domain) == .orderedSame
                            && $0.policy.uppercased() == "REJECT"
                    }
                }
                app.showToast("已撤销拦截：\(domain)", kind: .info)
            }
        } else {
            app.showToast("\(domain) 已在拦截规则中", kind: .warning)
        }
    }

    private func check(_ title: String, _ ok: Bool, _ detail: String) -> some View {
        row(title: title, detail: detail, color: ok ? TF.mint : TF.amber, filled: true)
    }

    /// 仅作说明的事实行：不是可勾选的安全项，避免出现「永远通过」的假绿灯。
    private func note(_ title: String, _ detail: String) -> some View {
        row(title: title, detail: detail, color: TF.textTertiary, filled: false)
    }

    private func row(title: String, detail: String, color: Color, filled: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if filled {
                    Circle().fill(color).frame(width: 6, height: 6)
                } else {
                    Circle().strokeBorder(color, lineWidth: 1).frame(width: 6, height: 6)
                }
            }
            .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(TF.text)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(TF.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    /// 文案与配色共用同一阈值表，避免「85 分说良好但显示琥珀色」的错位。
    private enum HealthLevel {
        case good, fair, weak
        static func of(_ score: Int) -> HealthLevel {
            score >= 80 ? .good : score >= 55 ? .fair : .weak
        }
    }

    private func scoreHeadline(_ score: Int) -> String {
        switch HealthLevel.of(score) {
        case .good: return "防护状态良好"
        case .fair: return "还有几处可以加强"
        case .weak: return "建议先完成基础加固"
        }
    }

    private func scoreColor(_ score: Int) -> Color {
        switch HealthLevel.of(score) {
        case .good: return TF.mint
        case .fair: return TF.amber
        case .weak: return TF.danger
        }
    }
    private func severityColor(_ s: Int) -> Color {
        s >= 3 ? TF.danger : s == 2 ? TF.amber : TF.textTertiary
    }
}

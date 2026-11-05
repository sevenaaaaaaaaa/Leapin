import SwiftUI
import TouchFlowCore
import TouchFlowPolicy
import TouchFlowNet
import TouchFlowIntegrations
import TouchFlowRuntime

enum Fmt {
    static func bytes(_ n: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(n), idx = 0
        while value >= 1024, idx < units.count - 1 { value /= 1024; idx += 1 }
        return idx == 0 ? "\(n) B" : String(format: "%.1f %@", value, units[idx])
    }
    static func duration(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.2f s", Double(ms) / 1000)
    }
    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }
}

/// Standard content panel with an optional header.
struct Card<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    var icon: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !title.isEmpty {
                SectionHeader(title: title, subtitle: subtitle, icon: icon)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tfPanel()
    }
}

/// Compact KPI tile used across the dashboard and module pages.
struct StatTile: View {
    var icon: String
    var title: String
    var value: String
    var tint: Color = TF.accent
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 20, height: 20)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TF.textSecondary)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(TFFont.num(24, weight: .bold))
                .foregroundStyle(TF.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(TF.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(TF.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(TF.stroke, lineWidth: 1)
        )
    }
}

struct Badge: View {
    var text: String
    var color: Color = TF.textSecondary
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(color.opacity(0.18), lineWidth: 0.5)
            )
            .foregroundStyle(color)
    }
}

struct EmptyHint: View {
    var icon: String
    var text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(TF.textTertiary)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(TF.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(26)
    }
}

struct FlowRow: View {
    var flow: FlowEvent
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(accent.opacity(0.12))
                Image(systemName: flow.blockedBy != nil ? "nosign" : (flow.phase == .closed ? "arrow.left.arrow.right" : "bolt.horizontal.fill"))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(accent)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(flow.host)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(Fmt.clock(flow.timestamp))
                        .font(TFFont.mono(9.5))
                        .foregroundStyle(TF.textTertiary)
                    if !flow.policy.isEmpty { Badge(text: flow.policy) }
                    if let rule = flow.matchedRule, !rule.isEmpty {
                        Text(rule)
                            .font(TFFont.mono(9.5))
                            .foregroundStyle(TF.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            if flow.bytesIn + flow.bytesOut > 0 {
                Text("\(Fmt.bytes(flow.bytesOut)) ↑  \(Fmt.bytes(flow.bytesIn)) ↓")
                    .font(TFFont.num(10, weight: .medium))
                    .foregroundStyle(TF.textSecondary)
            }
            if let blocked = flow.blockedBy {
                Badge(text: blocked == "adblock" ? "去广告" : "规则拦截", color: TF.danger)
            }
        }
        .padding(.vertical, 5)
    }

    private var accent: Color {
        if flow.blockedBy != nil { return TF.danger }
        return flow.phase == .closed ? TF.textTertiary : TF.mint
    }
}

struct LabeledField<Content: View>: View {
    var label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(TF.textSecondary)
                .frame(width: 104, alignment: .leading)
            content()
        }
    }
}

extension View {
    func pagePadding() -> some View { tfPage() }
}

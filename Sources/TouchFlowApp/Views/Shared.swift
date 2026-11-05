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

struct Card<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    var icon: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).foregroundStyle(.tint) }
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary.opacity(0.45)))
    }
}

struct StatTile: View {
    var icon: String
    var title: String
    var value: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption).foregroundStyle(tint)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.22)))
    }
}

struct Badge: View {
    var text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

struct EmptyHint: View {
    var icon: String
    var text: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

struct FlowRow: View {
    var flow: FlowEvent
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: flow.blockedBy != nil ? "nosign" : (flow.phase == .closed ? "arrow.left.arrow.right" : "bolt.horizontal"))
                .foregroundStyle(flow.blockedBy != nil ? .red : .green)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(flow.host).font(.callout).lineLimit(1)
                HStack(spacing: 6) {
                    Text(Fmt.clock(flow.timestamp)).font(.caption2).foregroundStyle(.tertiary)
                    if !flow.policy.isEmpty { Badge(text: flow.policy) }
                    if let rule = flow.matchedRule, !rule.isEmpty {
                        Text(rule).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer()
            if flow.bytesIn + flow.bytesOut > 0 {
                Text("\(Fmt.bytes(flow.bytesOut)) ↑ \(Fmt.bytes(flow.bytesIn)) ↓")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            if let blocked = flow.blockedBy {
                Badge(text: blocked == "adblock" ? "去广告" : "规则拦截", color: .red)
            }
        }
        .padding(.vertical, 3)
    }
}

struct LabeledField<Content: View>: View {
    var label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            content()
        }
    }
}

extension View {
    func pagePadding() -> some View { padding(20) }
}

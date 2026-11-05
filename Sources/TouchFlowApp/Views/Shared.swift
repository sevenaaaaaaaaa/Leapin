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
        VStack(alignment: .leading, spacing: 16) {
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(title)
                    .font(TFFont.mono(10, weight: .medium))
                    .tracking(1.1)
                    .foregroundStyle(TF.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(tint.opacity(0.9))
            }
            Text(value)
                .font(TFFont.num(26, weight: .medium))
                .foregroundStyle(TF.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.numericText())
                .tfAnimation(TFMotion.emphasized, value: value)
            if let caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(TF.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .tfGlass(radius: 12,
                 fallbackFill: TF.panel,
                 shadow: 0.04)
        .tfHoverLift()
    }
}

struct Badge: View {
    var text: String
    var color: Color = TF.textSecondary
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.3)
            .padding(.horizontal, 5.5)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(color.opacity(0.22), lineWidth: 0.5)
            )
            .foregroundStyle(color)
    }
}

/// Menu-backed select that matches the ruled form line.
struct TFSelectField<Value: Hashable>: View {
    @Binding var value: Value
    let options: [(Value, String)]
    @State private var open = false

    private var currentLabel: String {
        options.first(where: { $0.0 == value })?.1 ?? "—"
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 7) {
                Text(currentLabel)
                    .font(TFFont.mono(12, weight: .medium))
                    .foregroundStyle(TF.text)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(open ? TF.accent : TF.textTertiary)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.bottom, 4)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(open ? TF.accent : TF.strokeStrong.opacity(0.8))
                    .frame(height: open ? 1.5 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(options.indices, id: \.self) { index in
                    Button {
                        value = options[index].0
                        open = false
                    } label: {
                        HStack(spacing: 10) {
                            Text(options[index].1)
                                .font(TFFont.mono(12, weight: options[index].0 == value ? .semibold : .regular))
                                .foregroundStyle(options[index].0 == value ? TF.text : TF.textSecondary)
                            Spacer(minLength: 14)
                            if options[index].0 == value {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(TF.accent)
                            }
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < options.count - 1 {
                        Rectangle().fill(TF.stroke.opacity(0.6)).frame(height: 0.5).padding(.horizontal, 11)
                    }
                }
            }
            .padding(.vertical, 5)
            .frame(minWidth: 158)
        }
    }
}

/// Underlined single-line input: a ruled form line rather than a gray pill.
struct TFLineField: View {
    @Binding var text: String
    var placeholder: String
    var width: CGFloat? = nil
    var alignment: TextAlignment = .leading
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(TF.textTertiary))
            .textFieldStyle(.plain)
            .focused($focused)
            .font(.system(size: 12))
            .multilineTextAlignment(alignment)
            .lineLimit(1)
            .frame(width: width)
            .padding(.vertical, 3)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(focused ? TF.accent : TF.strokeStrong.opacity(0.8))
                    .frame(height: focused ? 1.5 : 1)
                    .tfAnimation(TFMotion.quick, value: focused)
            }
    }
}

struct EmptyHint: View {
    var icon: String
    var text: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(TF.textTertiary.opacity(0.8))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(TF.textTertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
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
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(accent.opacity(0.10))
                Image(systemName: flow.blockedBy != nil ? "nosign" : (flow.phase == .closed ? "arrow.left.arrow.right" : "bolt.horizontal.fill"))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(accent)
            }
            .frame(width: 21, height: 21)

            VStack(alignment: .leading, spacing: 2) {
                Text(flow.host)
                    .font(TFFont.mono(12, weight: .medium))
                    .foregroundStyle(TF.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(Fmt.clock(flow.timestamp))
                        .font(TFFont.mono(10))
                        .foregroundStyle(TF.textTertiary)
                    if !flow.policy.isEmpty { Badge(text: flow.policy) }
                    if let rule = flow.matchedRule, !rule.isEmpty {
                        Text(rule)
                            .font(TFFont.mono(10))
                            .foregroundStyle(TF.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            if flow.bytesIn + flow.bytesOut > 0 {
                Text("\(Fmt.bytes(flow.bytesOut)) ↑  \(Fmt.bytes(flow.bytesIn)) ↓")
                    .font(TFFont.num(10, weight: .regular))
                    .foregroundStyle(TF.textSecondary)
            }
            if let blocked = flow.blockedBy {
                Badge(text: blocked == "adblock" ? "去广告" : "规则拦截", color: TF.danger)
            }
        }
        .padding(.vertical, 6)
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
                .font(.system(size: 12))
                .foregroundStyle(TF.textSecondary)
                .frame(width: 104, alignment: .leading)
            content()
        }
    }
}

// MARK: - Copy affordance

/// Icon button that morphs into a check for a beat after copying.
/// The toast still fires; this is the local, proximate confirmation.
struct TFCopyButton: View {
    var value: String
    var accessibility: String = "复制"
    @State private var copied = false

    var body: some View {
        Button {
            TFClipboard.copy(value)
            TFMotion.run(TFMotion.emphasized) { copied = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                TFMotion.run(TFMotion.standard) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(copied ? TF.mint : TF.textTertiary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "已复制" : accessibility)
    }
}

// MARK: - Entrance

/// One-shot staggered entrance for page blocks. Motion is small (8pt, 340ms)
/// and disappears entirely under Reduce Motion.
struct TFAppear: ViewModifier {
    var delay: Double = 0
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                guard !shown else { return }
                if reduceMotion {
                    shown = true
                } else {
                    TFMotion.run(TFMotion.enter.delay(delay)) { shown = true }
                }
            }
    }
}

extension View {
    func tfAppear(_ delay: Double = 0) -> some View {
        modifier(TFAppear(delay: delay))
    }

    func pagePadding() -> some View { tfPage() }
}

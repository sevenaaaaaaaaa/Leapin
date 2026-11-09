import SwiftUI
import LeapinCore
import LeapinPolicy
import LeapinNet
import LeapinIntegrations
import LeapinRuntime

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
        .lpPanel()
    }
}

/// Compact KPI tile used across the dashboard and module pages.
struct StatTile: View {
    var icon: String
    var title: String
    var value: String
    var tint: Color = LP.accent
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(title)
                    .font(LPFont.mono(10, weight: .medium))
                    .tracking(1.1)
                    .foregroundStyle(LP.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(tint.opacity(0.9))
            }
            Text(value)
                .font(LPFont.num(26, weight: .medium))
                .foregroundStyle(LP.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.numericText())
                .lpAnimation(LPMotion.emphasized, value: value)
            if let caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(LP.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .lpGlass(radius: 12,
                 fallbackFill: LP.panel,
                 shadow: 0.04)
        .lpHoverLift()
    }
}

struct Badge: View {
    var text: String
    var color: Color = LP.textSecondary
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

/// Why a connection went where it went: the outer rule plus the rule-set member
/// that actually fired. Shared by capture detail and any surface that shows a
/// routing decision, so the wording stays identical everywhere.
struct RuleChainCard: View {
    var chain: RuleChain
    var title: String = "裁决链 / RULE CHAIN"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                LPEyebrow(text: title)
                Spacer(minLength: 6)
                if let index = chain.index {
                    Text("第 \(index) / \(chain.total) 条")
                        .font(LPFont.mono(9))
                        .foregroundStyle(LP.textTertiary)
                }
                Text(chain.policy)
                    .font(LPFont.mono(9.5, weight: .semibold))
                    .foregroundStyle(LP.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 9)
            LPDivider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(chain.steps.enumerated()), id: \.offset) { offset, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text(String(format: "%02d", offset + 1))
                            .font(LPFont.mono(9))
                            .foregroundStyle(LP.textTertiary)
                            .frame(width: 15, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.label)
                                .font(LPFont.mono(11, weight: offset == chain.steps.count - 1 ? .semibold : .regular))
                                .foregroundStyle(offset == chain.steps.count - 1 ? LP.text : LP.textSecondary)
                                .textSelection(.enabled)
                            if let detail = step.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(LPFont.mono(9.5))
                                    .foregroundStyle(LP.textTertiary)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 4)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            LPDivider()
            Text(chain.isFinal ? "没有命中具体规则，由兜底 MATCH 裁决" : "按首次命中裁决，后面的规则不再求值")
                .font(LPFont.mono(9))
                .foregroundStyle(LP.textTertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .background(LP.panel, in: RoundedRectangle(cornerRadius: LP.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LP.radius, style: .continuous)
                .strokeBorder(LP.stroke, lineWidth: 0.5)
        )
    }
}

/// Menu-backed select that matches the ruled form line.
struct LPSelectField<Value: Hashable>: View {
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
                    .font(LPFont.mono(12, weight: .medium))
                    .foregroundStyle(LP.text)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(open ? LP.accent : LP.textTertiary)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.bottom, 4)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(open ? LP.accent : LP.strokeStrong.opacity(0.8))
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
                                .font(LPFont.mono(12, weight: options[index].0 == value ? .semibold : .regular))
                                .foregroundStyle(options[index].0 == value ? LP.text : LP.textSecondary)
                            Spacer(minLength: 14)
                            if options[index].0 == value {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(LP.accent)
                            }
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < options.count - 1 {
                        Rectangle().fill(LP.stroke.opacity(0.6)).frame(height: 0.5).padding(.horizontal, 11)
                    }
                }
            }
            .padding(.vertical, 5)
            .frame(minWidth: 158)
        }
    }
}

/// Underlined single-line input: a ruled form line rather than a gray pill.
struct LPLineField: View {
    @Binding var text: String
    var placeholder: String
    var width: CGFloat? = nil
    var alignment: TextAlignment = .leading
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(LP.textTertiary))
            .textFieldStyle(.plain)
            .focused($focused)
            .font(.system(size: 12))
            .multilineTextAlignment(alignment)
            .lineLimit(1)
            .frame(width: width)
            .padding(.vertical, 3)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(focused ? LP.accent : LP.strokeStrong.opacity(0.8))
                    .frame(height: focused ? 1.5 : 1)
                    .lpAnimation(LPMotion.quick, value: focused)
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
                .foregroundStyle(LP.textTertiary.opacity(0.8))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(LP.textTertiary)
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
                    .font(LPFont.mono(12, weight: .medium))
                    .foregroundStyle(LP.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(Fmt.clock(flow.timestamp))
                        .font(LPFont.mono(10))
                        .foregroundStyle(LP.textTertiary)
                    if let app = flow.sourceApp, !app.isEmpty {
                        Text(app)
                            .font(LPFont.mono(10))
                            .foregroundStyle(LP.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if !flow.policy.isEmpty { Badge(text: flow.policy) }
                    if flow.chain?.isFinal == true {
                        // "FINAL,PROXY" is the engine's兜底 rule; naming it plainly beats
                        // repeating the outbound already shown by the badge.
                        Text("兜底")
                            .font(LPFont.mono(10))
                            .foregroundStyle(LP.textTertiary)
                    } else if let rule = flow.matchedRule, !rule.isEmpty {
                        Text(rule)
                            .font(LPFont.mono(10))
                            .foregroundStyle(LP.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            if flow.bytesIn + flow.bytesOut > 0 {
                Text("\(Fmt.bytes(flow.bytesOut)) ↑  \(Fmt.bytes(flow.bytesIn)) ↓")
                    .font(LPFont.num(10, weight: .regular))
                    .foregroundStyle(LP.textSecondary)
            }
            if let blocked = flow.blockedBy {
                Badge(text: blocked == "adblock" ? "去广告" : "规则拦截", color: LP.danger)
            }
        }
        .padding(.vertical, 6)
        .modifier(OptionalHelp(text: flow.chain?.summary))
    }

    private var accent: Color {
        if flow.blockedBy != nil { return LP.danger }
        return flow.phase == .closed ? LP.textTertiary : LP.mint
    }
}

/// On macOS .help("") still shows an empty tooltip box; only attach when there is text.
struct OptionalHelp: ViewModifier {
    var text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.help(text)
        } else {
            content
        }
    }
}

struct LabeledField<Content: View>: View {
    var label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(LP.textSecondary)
                .frame(width: 104, alignment: .leading)
            content()
        }
    }
}

// MARK: - Copy affordance

/// Icon button that morphs into a check for a beat after copying.
/// The toast still fires; this is the local, proximate confirmation.
struct LPCopyButton: View {
    var value: String
    var accessibility: String = "复制"
    @State private var copied = false

    var body: some View {
        Button {
            LPClipboard.copy(value)
            LPMotion.run(LPMotion.emphasized) { copied = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                LPMotion.run(LPMotion.standard) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(copied ? LP.mint : LP.textTertiary)
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
struct LPAppear: ViewModifier {
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
                    LPMotion.run(LPMotion.enter.delay(delay)) { shown = true }
                }
            }
    }
}

extension View {
    func lpAppear(_ delay: Double = 0) -> some View {
        modifier(LPAppear(delay: delay))
    }

    func pagePadding() -> some View { lpPage() }
}

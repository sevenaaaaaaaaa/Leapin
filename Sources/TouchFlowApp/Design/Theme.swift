import SwiftUI
import AppKit

// MARK: - Palette

/// Dynamic (light/dark) colour tokens for the whole app.
///
/// Visual direction: "Editorial Instrument" — warm paper, ink typography,
/// a single vermilion signal colour, hairline rules instead of floating cards.
/// Data is monospaced; prose is proportional; nothing competes with the numbers.
enum TF {
    static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func hex(_ v: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255,
                alpha: alpha)
    }

    // Surfaces — warm paper in light, warm ink in dark.
    static let bg = dyn(hex(0xF6F4EF), hex(0x0A0A0B))
    static let bgDeep = dyn(hex(0xEFEBE3), hex(0x050506))
    static let panel = dyn(hex(0xFCFBF8), hex(0x151517))
    static let panelSolid = dyn(hex(0xFFFFFF), hex(0x171719))
    static let panelRaised = dyn(hex(0xFFFFFF), hex(0x1F1F22))
    static let stroke = dyn(hex(0x16150F, 0.10), hex(0xFFFFFF, 0.12))
    static let strokeStrong = dyn(hex(0x16150F, 0.20), hex(0xFFFFFF, 0.20))

    // Text
    static let text = dyn(hex(0x16150F), hex(0xF3F1EA))
    static let textSecondary = dyn(hex(0x5F5C53), hex(0xA6A39A))
    // 9–10pt 说明文字大量使用三级色：浅底需 ≥4.5:1，深底同样拉到 5:1 以上。
    static let textTertiary = dyn(hex(0x6F6B60), hex(0x87847B))

    // Accents — one signal colour; the rest are semantic status only.
    static let accent = dyn(hex(0xC63A12), hex(0xFF7A4D))
    /// Filled-button background: white text must clear 4.5:1 in both modes, so the
    /// dark mode fill is the deeper vermilion rather than the bright accent used for text.
    static let accentFill = dyn(hex(0xB83510), hex(0xC2410F))
    static let dangerFill = dyn(hex(0xB32636), hex(0xC0323F))
    static let accentSoft = dyn(hex(0xC63A12, 0.09), hex(0xFF7A4D, 0.15))
    static let violet = dyn(hex(0x5446B8), hex(0xB0A3FF))
    static let mint = dyn(hex(0x0C7A55), hex(0x35D19B))
    static let amber = dyn(hex(0x8F5E07), hex(0xE8B04A))
    static let danger = dyn(hex(0xB32636), hex(0xFF6B74))
    static let success = dyn(hex(0x0C7A55), hex(0x35D19B))

    /// Used for the logo and the one live-data accent. Deliberately low-chroma:
    /// vermilion into burnt umber, never a rainbow gradient.
    static var brand: LinearGradient {
        LinearGradient(colors: [accent, dyn(hex(0x8E2606), hex(0xD9502A))],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    // Metrics — 8pt rhythm.
    static let radius: CGFloat = 10
    static let radiusSmall: CGFloat = 6
    static let gutter: CGFloat = 24
    static let hairline: CGFloat = 1
}

// MARK: - Typography

enum TFFont {
    /// Display type: SF Pro, tight. Tracking is applied at the call site for
    /// sizes ≥ 20 where the optical adjustment actually matters.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }
    /// Data type: SF Mono with tabular digits so counters never jitter.
    static func num(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// Editorial accent, used sparingly for the one human sentence on a page.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static let overline = Font.system(size: 9, weight: .semibold)
}

// MARK: - Background

struct TFBackground: View {
    var body: some View {
        TF.bg.ignoresSafeArea()
    }
}

// MARK: - Panels

struct TF_PanelModifier: ViewModifier {
    var radius: CGFloat = TF.radius
    var padding: CGFloat = 18
    var raised: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(raised ? TF.panelRaised : TF.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(TF.stroke, lineWidth: TF.hairline)
            )
            .shadow(color: Color.black.opacity(raised ? 0.05 : 0), radius: 22, x: 0, y: 10)
    }
}

extension View {
    func tfPanel(radius: CGFloat = TF.radius, padding: CGFloat = 18, raised: Bool = false) -> some View {
        modifier(TF_PanelModifier(radius: radius, padding: padding, raised: raised))
    }

    /// Standard page container: generous margins, one readable measure.
    func tfPage() -> some View {
        self.frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
    }

    /// Hover feedback for interactive cards/rows. Subtle: 1pt lift, not a bounce.
    func tfHoverLift() -> some View {
        modifier(TFHoverLift())
    }
}

private struct TFHoverLift: ViewModifier {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(y: hovering ? -1 : 0)
            .shadow(color: .black.opacity(hovering ? 0.06 : 0), radius: 12, y: 6)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
    }
}

// MARK: - Section header

struct SectionHeader: View {
    var title: String
    var subtitle: String? = nil
    var icon: String? = nil
    var tint: Color = TF.accent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TF.textTertiary)   // 图标恒定中性：颜色只留给数据信号
                    .baselineOffset(-1)
            }
            Text(title)
                .font(TFFont.display(14.5, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(TF.text)
            Spacer(minLength: 8)
            if let subtitle {
                Text(subtitle)
                    .font(TFFont.mono(10))
                    .foregroundStyle(TF.textTertiary)
                    .lineLimit(1)
            }
        }
    }
}

struct PageHeader: View {
    var title: String
    var subtitle: String
    var icon: String
    @ViewBuilder var actions: () -> AnyView

    init(title: String, subtitle: String, icon: String, @ViewBuilder actions: @escaping () -> some View) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.actions = { AnyView(actions()) }
    }

    init(title: String, subtitle: String, icon: String) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.actions = { AnyView(EmptyView()) }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Text(title)
                        .font(TFFont.display(22, weight: .semibold))
                        .tracking(-0.6)
                        .foregroundStyle(TF.text)
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(TF.textTertiary)
            }
            Spacer()
            actions()
        }
        .padding(.horizontal, 32)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }
}

// MARK: - Editorial eyebrow

/// Small uppercase mono label used above a block of data.
struct TFEyebrow: View {
    var text: String
    var tint: Color = TF.textTertiary

    /// Both call styles are valid: `TFEyebrow("LABEL")` and `TFEyebrow(text: "LABEL")`.
    init(_ text: String, tint: Color = TF.textTertiary) {
        self.text = text
        self.tint = tint
    }

    init(text: String, tint: Color = TF.textTertiary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(TFFont.mono(10, weight: .medium))
            .tracking(1.5)
            .foregroundStyle(tint)
    }
}

// MARK: - Controls

struct TFPrimaryButtonStyle: ButtonStyle {
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint ?? TF.accentFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct TFGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(TF.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Status

struct StatusDot: View {
    var color: Color
    var pulsing: Bool = false
    @State private var on = false

    var body: some View {
        ZStack {
            if pulsing {
                Circle()
                    .fill(color.opacity(0.30))
                    .frame(width: 12, height: 12)
                    .scaleEffect(on ? 1.35 : 0.7)
                    .opacity(on ? 0 : 1)
                    .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false), value: on)
            }
            Circle().fill(color).frame(width: 6, height: 6)
        }
        .frame(width: 12, height: 12)
        .onAppear { on = true }
    }
}

struct TFDivider: View {
    var body: some View {
        Rectangle().fill(TF.stroke).frame(height: TF.hairline)
    }
}

/// Hairline with a mono label — the primary structural device in this design.
struct TFRule: View {
    var label: String? = nil
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(TF.stroke).frame(height: 1)
            if let label {
                Text(label)
                    .font(TFFont.mono(10, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(TF.textTertiary)
                    .fixedSize()
                Rectangle().fill(TF.stroke).frame(height: 1)
            }
        }
    }
}

/// Custom switch: macOS 27 的无标签 `.switch` 在部分容器里会恒定渲染成关闭态，
/// 这里用自绘开关保证状态与视觉一致，也顺便统一了品牌色。
struct TFSwitch: View {
    @Binding var isOn: Bool
    var tint: Color = TF.accent
    var width: CGFloat = 32
    @FocusState private var focused: Bool

    var body: some View {
        let h = width * 18 / 34
        let knob = h - 5
        Button {
            isOn.toggle()
        } label: {
            Capsule(style: .continuous)
                .fill(isOn ? tint : TF.text.opacity(0.22))
                .frame(width: width, height: h)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.18), radius: 1.4, y: 0.6)
                        .frame(width: knob, height: knob)
                        .padding(2.5)
                        .offset(x: isOn ? width - knob - 5 : 0)
                }
                .animation(.spring(response: 0.26, dampingFraction: 0.82), value: isOn)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(focused ? TF.accent : .clear, lineWidth: 2)
                        .padding(-3)
                )
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: $isOn) { EmptyView() } }
        .accessibilityValue(isOn ? "开启" : "关闭")
        .focusEffectDisabled()
    }
}

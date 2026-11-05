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
    static let bg = dyn(hex(0xEDE7DB), hex(0x0A0A0B))
    /// Tint laid over a clear glass card so content surfaces sit a step above the
    /// window material instead of dissolving into it.
    static let cardTint = dyn(hex(0xFFFFFF, 0.34), hex(0xFFFFFF, 0.05))
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
    // Ambient light behind the glass. Very low chroma: enough for the material to
    // refract and for edges to read, never enough to become decoration.
    static let bloomCool = dyn(hex(0xCBDFF6), hex(0x14243C))
    static let bloomWarm = dyn(hex(0xF2DADD), hex(0x2E1A20))
    static let bloomViolet = dyn(hex(0xD9D9F2), hex(0x1F1E3E))

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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                TF.bg
            } else {
                // The blur itself lives on the window's frame view (Platform.swift);
                // this wash is the only thing between the wallpaper and the text.
                TF.bg.opacity(0.40)
            }
            RadialGradient(colors: [TF.bloomCool.opacity(0.55), .clear],
                           center: UnitPoint(x: 0.08, y: 0.0),
                           startRadius: 40, endRadius: 720)
            RadialGradient(colors: [TF.bloomWarm.opacity(0.32), .clear],
                           center: UnitPoint(x: 0.98, y: 0.06),
                           startRadius: 20, endRadius: 520)
            RadialGradient(colors: [TF.bloomViolet.opacity(0.38), .clear],
                           center: UnitPoint(x: 0.45, y: 1.08),
                           startRadius: 40, endRadius: 760)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Liquid Glass

/// Liquid Glass (macOS 26) with a materials fallback for macOS 14-15.
///
/// Rules encoded here rather than at every call site:
/// - glass is a surface material, not a fill: never layer an opaque colour behind it;
/// - corner radii grow with the surface (panels 20, tiles 16, controls capsule);
/// - interactive is only passed for elements the user can actually press.
enum TFGlass {
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
    static let panelRadius: CGFloat = 20
    static let tileRadius: CGFloat = 16
    static let controlRadius: CGFloat = 11
}

private struct TFGlassSurface<S: InsettableShape>: ViewModifier {
    var shape: S
    var tint: Color?
    var interactive: Bool
    var clear: Bool
    var fallbackFill: Color
    var fallbackMaterial: Material
    var shadow: Double

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(glass, in: shape)
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.92), .white.opacity(0.34),
                                                .black.opacity(0.05), .white.opacity(0.26)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
                )
                .shadow(color: .black.opacity(shadow), radius: 20, x: 0, y: 9)
        } else {
            content
                .background(fallbackFill, in: shape)
                .background(fallbackMaterial, in: shape)
                .overlay(shape.strokeBorder(TF.stroke, lineWidth: 1))
                .shadow(color: .black.opacity(shadow * 0.6), radius: 18, x: 0, y: 8)
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var g: Glass = clear ? .clear : .regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

extension View {
    func tfGlass<S: InsettableShape>(in shape: S,
                           tint: Color? = nil,
                           interactive: Bool = false,
                           clear: Bool = false,
                           fallbackFill: Color = TF.panel,
                           fallbackMaterial: Material = .ultraThinMaterial,
                           shadow: Double = 0.0) -> some View {
        modifier(TFGlassSurface(shape: shape,
                                tint: tint,
                                interactive: interactive,
                                clear: clear,
                                fallbackFill: fallbackFill,
                                fallbackMaterial: fallbackMaterial,
                                shadow: shadow))
    }

    func tfGlass(radius: CGFloat = TFGlass.panelRadius,
                 tint: Color? = nil,
                 interactive: Bool = false,
                 clear: Bool = false,
                 fallbackFill: Color = TF.panel,
                 fallbackMaterial: Material = .ultraThinMaterial,
                 shadow: Double = 0.0) -> some View {
        tfGlass(in: RoundedRectangle(cornerRadius: radius, style: .continuous),
                tint: tint,
                interactive: interactive,
                clear: clear,
                fallbackFill: fallbackFill,
                fallbackMaterial: fallbackMaterial,
                shadow: shadow)
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
            .tfGlass(radius: max(TFGlass.panelRadius, radius + 6),
                     tint: TF.cardTint,
                     clear: true,
                     fallbackFill: raised ? TF.panelRaised : TF.panel,
                     shadow: raised ? 0.10 : 0.07)
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
            .tfAnimation(TFMotion.quick, value: hovering)
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
        let fill = tint ?? TF.accentFill
        TFButtonFocusRing(shape: Capsule()) {
            // 主操作保持不透明实色：tint 玻璃在浅底上会把朱红洗成灰，
            // 白字对比掉到 2:1 以下——可读性优先于材质一致性。
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 15)
                .padding(.vertical, 7)
                .background(Capsule(style: .continuous).fill(fill))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.06)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .tfAnimation(TFMotion.press, value: configuration.isPressed)
        }
    }
}

struct TFGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TFButtonFocusRing(shape: Capsule()) {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TF.text)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .tfGlass(in: Capsule(style: .continuous),
                         interactive: true,
                         fallbackFill: TF.panel,
                         fallbackMaterial: .thinMaterial)
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }
}

/// 键盘焦点环：读到最近可聚焦祖先（Button）的焦点态，在按钮外描 2pt 朱红。
/// 放在 ButtonStyle 内部，因此所有用这两套样式的按钮自动获得焦点提示，无需逐处接 @FocusState。
private struct TFButtonFocusRing<S: InsettableShape, Content: View>: View {
    @Environment(\.isFocused) private var isFocused
    var shape: S
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .overlay(
                shape
                    .strokeBorder(TF.accent, lineWidth: 2)
                    .padding(-3)
                    .opacity(isFocused ? 1 : 0)
                    .allowsHitTesting(false)
            )
    }
}

// MARK: - Status

struct StatusDot: View {
    var color: Color
    var pulsing: Bool = false
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if pulsing {
                Circle()
                    .fill(color.opacity(0.30))
                    .frame(width: 12, height: 12)
                    .scaleEffect(on ? 1.35 : 0.7)
                    .opacity(on ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 1.8).repeatForever(autoreverses: false), value: on)
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

// MARK: - Motion

/// 动效令牌：全 App 只用这几条曲线，避免每个视图各写各的时长。
/// reduceMotion 由 tfAnimation / run 统一处理，调用点不再重复判断。
enum TFMotion {
    /// 按压、勾选等需要“立刻”的反馈。
    static let press = Animation.easeOut(duration: 0.12)
    /// 焦点、hover 等小范围状态。
    static let quick = Animation.easeOut(duration: 0.14)
    /// 换页、抽屉等标准过渡。
    static let standard = Animation.easeOut(duration: 0.18)
    /// 强调：弹层、指标变化。
    static let emphasized = Animation.snappy(duration: 0.28)
    /// 开关滑块。
    static let spring = Animation.spring(response: 0.26, dampingFraction: 0.82)
    /// 首屏错峰入场。
    static let enter = Animation.easeOut(duration: 0.38)

    /// 命令式动画：reduceMotion 打开时直接落位。
    @MainActor
    static func run(_ animation: Animation = TFMotion.standard, _ body: () -> Void) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            body()
        } else {
            withAnimation(animation, body)
        }
    }
}

/// 声明式动画包装：reduceMotion 打开时禁用动画。
struct TFAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// 用动效令牌做 .animation，且自动尊重「减弱动态效果」。
    func tfAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(TFAnimationModifier(animation: animation, value: value))
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
            track(width: width, height: h)
                .frame(width: width, height: h)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.22), radius: 1.6, y: 0.8)
                        .frame(width: knob, height: knob)
                        .padding(2.5)
                        .offset(x: isOn ? width - knob - 5 : 0)
                }
                .tfAnimation(TFMotion.spring, value: isOn)
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

    /// macOS 26: the track IS the glass — tinted when on, clear when off.
    /// Older systems keep the solid track so the on/off contrast never relies on blur.
    @ViewBuilder
    private func track(width: CGFloat, height: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(isOn ? .regular.tint(tint).interactive() : .regular.interactive(),
                             in: Capsule())
                .overlay(
                    Capsule()
                        .fill(isOn ? Color.white.opacity(0.0) : TF.text.opacity(0.10))
                        .allowsHitTesting(false)
                )
        } else {
            Capsule(style: .continuous)
                .fill(isOn ? tint : TF.text.opacity(0.22))
        }
    }
}


// MARK: - Window metrics

/// 根视图测量的窗口宽度，供页面做单列/双列切换（macOS 没有 compact size class）。
private struct TFWindowWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1200
}

extension EnvironmentValues {
    var tfWindowWidth: CGFloat {
        get { self[TFWindowWidthKey.self] }
        set { self[TFWindowWidthKey.self] = newValue }
    }
}

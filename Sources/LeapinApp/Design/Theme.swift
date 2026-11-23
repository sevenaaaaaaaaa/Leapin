import SwiftUI
import AppKit

// MARK: - Palette

/// Dynamic (light/dark) colour tokens for the whole app.
///
/// Visual direction: "Editorial Instrument" — warm paper, ink typography,
/// a single vermilion signal colour, hairline rules instead of floating cards.
/// Data is monospaced; prose is proportional; nothing competes with the numbers.
enum LP {
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
    static let panel = dyn(hex(0xFCFBF8), hex(0x151517))
    static let panelSolid = dyn(hex(0xFFFFFF), hex(0x171719))
    static let panelRaised = dyn(hex(0xFFFFFF), hex(0x1F1F22))
    static let stroke = dyn(hex(0x16150F, 0.10), hex(0xFFFFFF, 0.12))
    static let strokeStrong = dyn(hex(0x16150F, 0.20), hex(0xFFFFFF, 0.20))

    // MARK: v5 surfaces (DESIGN-v5 §6.1) — only three surfaces plus the hairline.
    /// Window background: one sheet of paper.
    static let paper = dyn(hex(0xF4EFE6), hex(0x0F0F10))
    /// Content surface: modules, rows, inputs.
    static let sheet = dyn(hex(0xFBF8F2), hex(0x161618))
    /// The single focus band per screen. At most one per page.
    static let ink = dyn(hex(0x19191B), hex(0x1C1C1F))
    /// Hairline rule — replaces the double stroke.
    static let line = dyn(hex(0x16150F, 0.10), hex(0xFFFFFF, 0.10))
    /// Sidebar / list selection. Ink at 6%, never a tinted accent wash:
    /// a pale vermilion row reads as a warning, not as "you are here".
    static let selectionFill = dyn(hex(0x16150F, 0.06), hex(0xFFFFFF, 0.07))

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

enum LPFont {
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
    static let overline = Font.system(size: 11, weight: .semibold)
}

/// v5 type scale (DESIGN-v5 §6.2). Nothing below 11pt; body is always 13.
/// Use these instead of raw sizes so the scale is one place, not four hundred.
enum LPType {
    static let title = Font.system(size: 28, weight: .semibold)
    static let section = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let label = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let data = Font.system(size: 20, weight: .semibold, design: .monospaced)
    static let dataSmall = Font.system(size: 13, weight: .medium, design: .monospaced)
    static let quote = Font.system(size: 15, design: .serif).italic()
    /// The floor. A glyph may go below this only with a reason written in qa/T-15.
    static let minimum: CGFloat = 11
}

/// v5 spacing scale (§6.3): 4 / 8 / 12 / 16 / 24 / 32 / 48.
enum LPSpace {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
    static let page: CGFloat = 32
    static let section: CGFloat = 24
    static let module: CGFloat = 16
}

/// v5 radii (§6.3): panel 12, control 8, status pill full.
enum LPRadius {
    static let panel: CGFloat = 12
    static let control: CGFloat = 8
    static let pill: CGFloat = 999
}

// MARK: - Background

struct LPBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                LP.bg
            } else {
                // The blur itself lives on the window's frame view (Platform.swift);
                // this wash is the only thing between the wallpaper and the text.
                LP.bg.opacity(0.40)
            }
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
/// v5 content surface (DESIGN-v5 §6.1): paper + hairline, no material.
/// Glass is reserved for overlays — menu bar panel, floating window, palette, sheet.
struct LPSheetSurface: ViewModifier {
    var radius: CGFloat = LPRadius.panel

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LP.sheet)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LP.line, lineWidth: 1)
            )
    }
}

extension View {
    /// Put the content on paper. Use this instead of `lpGlass` anywhere the
    /// surface belongs to the page rather than floating above it.
    func lpSheet(radius: CGFloat = LPRadius.panel) -> some View {
        modifier(LPSheetSurface(radius: radius))
    }
}

/// v5 pill control surface: paper + hairline, used by chips and inline pickers.
struct LPPillSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Capsule(style: .continuous).fill(LP.sheet))
            .overlay(Capsule(style: .continuous).strokeBorder(LP.line, lineWidth: 1))
    }
}

extension View {
    func lpPill() -> some View { modifier(LPPillSurface()) }
}

enum LPGlass {
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
    static let panelRadius: CGFloat = 20
    static let tileRadius: CGFloat = 16
    static let controlRadius: CGFloat = 11
}

private struct LPGlassSurface<S: InsettableShape>: ViewModifier {
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
                    shape.strokeBorder(LP.stroke, lineWidth: 1)
                    .allowsHitTesting(false)
                )
                .shadow(color: .black.opacity(shadow), radius: 20, x: 0, y: 9)
        } else {
            content
                .background(fallbackFill, in: shape)
                .background(fallbackMaterial, in: shape)
                .overlay(shape.strokeBorder(LP.stroke, lineWidth: 1))
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
    func lpGlass<S: InsettableShape>(in shape: S,
                           tint: Color? = nil,
                           interactive: Bool = false,
                           clear: Bool = false,
                           fallbackFill: Color = LP.panel,
                           fallbackMaterial: Material = .ultraThinMaterial,
                           shadow: Double = 0.0) -> some View {
        modifier(LPGlassSurface(shape: shape,
                                tint: tint,
                                interactive: interactive,
                                clear: clear,
                                fallbackFill: fallbackFill,
                                fallbackMaterial: fallbackMaterial,
                                shadow: shadow))
    }

    func lpGlass(radius: CGFloat = LPGlass.panelRadius,
                 tint: Color? = nil,
                 interactive: Bool = false,
                 clear: Bool = false,
                 fallbackFill: Color = LP.panel,
                 fallbackMaterial: Material = .ultraThinMaterial,
                 shadow: Double = 0.0) -> some View {
        lpGlass(in: RoundedRectangle(cornerRadius: radius, style: .continuous),
                tint: tint,
                interactive: interactive,
                clear: clear,
                fallbackFill: fallbackFill,
                fallbackMaterial: fallbackMaterial,
                shadow: shadow)
    }
}

// MARK: - Panels

struct LEAPIN_PanelModifier: ViewModifier {
    var radius: CGFloat = LP.radius
    var padding: CGFloat = 18
    var raised: Bool = false

    func body(content: Content) -> some View {
        // System-native surfaces: a flat, subtly raised card on the window
        // background, the way macOS System Settings groups content. No glass, no
        // border, no shadow — the glass panel read as a widget dashboard rather
        // than part of the system.
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: raised ? .controlBackgroundColor : .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
    }
}

extension View {
    func lpPanel(radius: CGFloat = LP.radius, padding: CGFloat = 18, raised: Bool = false) -> some View {
        modifier(LEAPIN_PanelModifier(radius: radius, padding: padding, raised: raised))
    }

    /// Standard page container: generous margins, one readable measure.
    func lpPage() -> some View {
        // One measure for every page: a narrower column than before (1180 read
        // as a dashboard wall on a 1440 screen) and the insets System Settings uses.
        self.frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
    }

    /// Hover feedback for interactive cards/rows. Subtle: 1pt lift, not a bounce.
    func lpHoverLift() -> some View {
        modifier(LPHoverLift())
    }
}

private struct LPHoverLift: ViewModifier {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(y: hovering ? -1 : 0)
            .shadow(color: .black.opacity(hovering ? 0.06 : 0), radius: 12, y: 6)
            .onHover { hovering = $0 }
            .lpAnimation(LPMotion.quick, value: hovering)
    }
}

// MARK: - Section header

struct SectionHeader: View {
    var title: String
    var subtitle: String? = nil
    var icon: String? = nil
    var tint: Color = LP.accent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LP.textTertiary)   // 图标恒定中性：颜色只留给数据信号
                    .baselineOffset(-1)
            }
            Text(title)
                .font(LPType.section)
                .tracking(-0.2)
                .foregroundStyle(LP.text)
            Spacer(minLength: 8)
            if let subtitle {
                Text(subtitle)
                    .font(LPFont.mono(11))
                    .foregroundStyle(LP.textTertiary)
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
                        .font(LPType.title)
                        .tracking(-0.4)
                        .foregroundStyle(LP.text)
                }
                Text(subtitle)
                    .font(LPType.body)
                    .foregroundStyle(LP.textTertiary)
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

/// Small mono label used above a block of data.
struct LPEyebrow: View {
    var text: String
    var tint: Color = LP.textTertiary

    /// Both call styles are valid: `LPEyebrow("LABEL")` and `LPEyebrow(text: "LABEL")`.
    init(_ text: String, tint: Color = LP.textTertiary) {
        self.text = text
        self.tint = tint
    }

    init(text: String, tint: Color = LP.textTertiary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(LPFont.mono(11, weight: .medium))
            .tracking(0.8)
            .foregroundStyle(tint)
    }
}

// MARK: - Controls

struct LPPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        let fill = isEnabled ? (tint ?? LP.accentFill) : LP.stroke
        LPButtonFocusRing(shape: RoundedRectangle(cornerRadius: 8, style: .continuous)) {
            // 主操作保持不透明实色：tint 玻璃在浅底上会把朱红洗成灰，
            // 白字对比掉到 2:1 以下——可读性优先于材质一致性。
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isEnabled ? .white : LP.textTertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .lpAnimation(LPMotion.press, value: configuration.isPressed)
        }
    }
}

struct LPGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        LPButtonFocusRing(shape: RoundedRectangle(cornerRadius: 8, style: .continuous)) {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LP.text)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5))
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
        }
    }
}

/// Card-style button: press compression + the same visible keyboard focus ring
/// as the primary/ghost styles. Used by overview cards and index rows.
struct LPCardButtonStyle: ButtonStyle {
    var radius: CGFloat = 16
    func makeBody(configuration: Configuration) -> some View {
        LPButtonFocusRing(shape: RoundedRectangle(cornerRadius: radius, style: .continuous)) {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.992 : 1)
                .opacity(configuration.isPressed ? 0.92 : 1)
                .lpAnimation(LPMotion.press, value: configuration.isPressed)
        }
    }
}

/// 键盘焦点环：读到最近可聚焦祖先（Button）的焦点态，在按钮外描 2pt 朱红。
/// 放在 ButtonStyle 内部，因此所有用这两套样式的按钮自动获得焦点提示，无需逐处接 @FocusState。
private struct LPButtonFocusRing<S: InsettableShape, Content: View>: View {
    @Environment(\.isFocused) private var isFocused
    var shape: S
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .overlay(
                shape
                    .strokeBorder(LP.accent, lineWidth: 2)
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

struct LPDivider: View {
    var body: some View {
        Rectangle().fill(LP.stroke).frame(height: LP.hairline)
    }
}

// MARK: - Motion

/// 动效令牌：全 App 只用这几条曲线，避免每个视图各写各的时长。
/// reduceMotion 由 lpAnimation / run 统一处理，调用点不再重复判断。
enum LPMotion {
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
    static func run(_ animation: Animation = LPMotion.standard, _ body: () -> Void) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            body()
        } else {
            withAnimation(animation, body)
        }
    }
}

/// 声明式动画包装：reduceMotion 打开时禁用动画。
struct LPAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// 用动效令牌做 .animation，且自动尊重「减弱动态效果」。
    func lpAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(LPAnimationModifier(animation: animation, value: value))
    }
}

/// Hairline with a mono label — the primary structural device in this design.
struct LPRule: View {
    var label: String? = nil
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(LP.stroke).frame(height: 1)
            if let label {
                Text(label)
                    .font(LPFont.mono(10, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(LP.textTertiary)
                    .fixedSize()
                Rectangle().fill(LP.stroke).frame(height: 1)
            }
        }
    }
}

/// Custom switch: macOS 27 的无标签 `.switch` 在部分容器里会恒定渲染成关闭态，
/// 这里用自绘开关保证状态与视觉一致，也顺便统一了品牌色。
struct LPSwitch: View {
    @Binding var isOn: Bool
    var tint: Color = LP.accent
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
                .lpAnimation(LPMotion.spring, value: isOn)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(focused ? LP.accent : .clear, lineWidth: 2)
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
                        .fill(isOn ? Color.white.opacity(0.0) : LP.text.opacity(0.10))
                        .allowsHitTesting(false)
                )
        } else {
            Capsule(style: .continuous)
                .fill(isOn ? tint : LP.text.opacity(0.22))
        }
    }
}


// MARK: - Window metrics

/// 根视图测量的窗口宽度，供页面做单列/双列切换（macOS 没有 compact size class）。
private struct LPWindowWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1200
}

extension EnvironmentValues {
    var lpWindowWidth: CGFloat {
        get { self[LPWindowWidthKey.self] }
        set { self[LPWindowWidthKey.self] = newValue }
    }
}

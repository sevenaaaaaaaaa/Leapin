import SwiftUI
import AppKit

// MARK: - Palette

/// Dynamic (light/dark) colour tokens for the whole app.
///
/// Visual direction: "Editorial Instrument" — warm paper, ink typography,
/// a single vermilion signal colour, hairline rules instead of floating cards.
/// Data is monospaced; prose is proportional; nothing competes with the numbers.
///
/// Surfaces are a three-step ramp in both modes, so the eye always knows what it is
/// looking at without reading a border: **paper** (the window) < **sheet** (a card,
/// a control) < **ink** (the one focus band a screen is allowed).
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

    // MARK: Surfaces

    /// The window: one sheet of paper.
    static let paper = dyn(hex(0xF4EFE6), hex(0x0F0F10))
    /// The window: one continuous surface. 空间感来自拓扑、连线与运动的包，
    /// 不靠一块突兀的深色底——那是上一版被否掉的「两座孤岛」。
    static let space = paper
    /// Content surface: cards, rows, inputs.
    static let sheet = dyn(hex(0xFDFBF7), hex(0x1A1A1E))
    /// Something sitting on a sheet: a menu row, the selected segment.
    static let sheetRaised = dyn(hex(0xFFFFFF), hex(0x25252A))
    /// The single focus band per screen. At most one per page.
    /// Dark mode lifts it a clear step above the paper: an ink band that is
    /// barely darker than the night paper is not a focus band, it is a shadow.
    static let ink = dyn(hex(0x19191B), hex(0x26262B))
    /// The band's edge: nothing in light (ink is its own edge), a hairline in dark.
    static let inkBorder = dyn(hex(0xFFFFFF, 0), hex(0xFFFFFF, 0.12))
    /// Hairline rule.
    static let line = dyn(hex(0x16150F, 0.10), hex(0xFFFFFF, 0.10))
    static let lineStrong = dyn(hex(0x16150F, 0.18), hex(0xFFFFFF, 0.18))
    /// Row hover, never a tinted wash.
    static let hover = dyn(hex(0x16150F, 0.05), hex(0xFFFFFF, 0.07))
    /// Sidebar / list selection. Ink at 6%, never a tinted accent wash:
    /// a pale vermilion row reads as a warning, not as "you are here".
    static let selectionFill = dyn(hex(0x16150F, 0.06), hex(0xFFFFFF, 0.08))

    // Older names, still read across the app. Each one now resolves to a step of
    // the same ramp, so a card cannot pick a fourth surface by using the old token.
    static let bg = paper
    static let panel = sheet
    static let panelSolid = sheetRaised
    static let panelRaised = sheetRaised
    static let stroke = line
    static let strokeStrong = lineStrong
    static let cardTint = dyn(hex(0xFFFFFF, 0.34), hex(0xFFFFFF, 0.05))

    // MARK: Text

    static let text = dyn(hex(0x16150F), hex(0xF3F1EA))
    static let textSecondary = dyn(hex(0x5F5C53), hex(0xA6A39A))
    // 9–10pt 说明文字大量使用三级色：浅底需 ≥4.5:1，深底同样拉到 5:1 以上。
    static let textTertiary = dyn(hex(0x6F6B60), hex(0x87847B))

    /// On the ink band. The band is dark in both modes, so these are plain white
    /// at three weights; the tertiary weight stays at 50% because 11pt text on
    /// the dark-mode band needs every bit of that to clear 4.5:1.
    static let onInk = Color.white.opacity(0.94)
    static let onInkSecondary = Color.white.opacity(0.66)
    static let onInkTertiary = Color.white.opacity(0.50)
    static let inkLine = Color.white.opacity(0.20)
    static let inkText = onInk
    static let inkTextSecondary = onInkSecondary

    // MARK: Accents — one signal colour; the rest are semantic status only.

    static let accent = dyn(hex(0xC63A12), hex(0xFF7A4D))
    /// The same vermilion for use **on ink**. The brand red is 3.2:1 against the
    /// band, fine for a dot but not for a label, and it reads brown next to black;
    /// the lifted red is 5.8:1 or better on both bands and is still one hue.
    static let accentOnInk = Color(red: 1, green: 122 / 255, blue: 77 / 255)
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

    // Metrics — 8pt rhythm. Panels are 12 everywhere; nothing rounds at 10 any more.
    static let radius: CGFloat = 12
    static let radiusSmall: CGFloat = 8
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

/// The type scale. Nothing below 11pt; body is always 13.
///
/// The scale has a job beyond "sizes that go together": a screen is allowed exactly
/// one `hero`, and it goes to the thing the screen is about — the exit on 走哪,
/// the verdict on 为什么 — never to a page title.
/// Use these instead of raw sizes so the scale is one place, not four hundred.
enum LPType {
    /// Page title in the shell header. Small on purpose: the verb name is a label,
    /// two characters that say where you are, not the loudest thing on the page.
    static let title = Font.system(size: 22, weight: .semibold)
    /// The one large thing on a screen, given by meaning.
    static let hero = Font.system(size: 28, weight: .semibold)
    static let section = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let label = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let data = Font.system(size: 20, weight: .semibold, design: .monospaced)
    static let dataSmall = Font.system(size: 13, weight: .medium, design: .monospaced)
    /// One serif sentence per screen at most: the brand's voice, used for the tagline.
    static let quote = Font.system(size: 12, design: .serif).italic()
    /// The floor. A glyph may go below this only with a reason written in qa/T-15.
    static let minimum: CGFloat = 11
}

/// Spacing scale: 4 / 8 / 12 / 16 / 24 / 32 / 48.
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
    /// The one left edge every page shares: header title, toolbar and content all
    /// start this far from the sidebar. Pages used to disagree by up to 38pt.
    static let inset: CGFloat = 28
    /// A toolbar row under the header: 12 + 28 control + 12.
    static let toolbar: CGFloat = 52
}

/// Radii: panel 12, control 8, status pill full.
enum LPRadius {
    static let panel: CGFloat = 12
    static let control: CGFloat = 8
    static let pill: CGFloat = 999
}

// MARK: - Shell metrics

/// Fixed numbers of the window chrome. Pages do not read these; the shell does,
/// and the two halves of the header (title block and tab underline) must agree.
enum LPShell {
    static let headerHeight: CGFloat = 66
    static let headerTop: CGFloat = 12
    static let titleLine: CGFloat = 26
    static let sidebarWidth: CGFloat = 208
    static let sidebarCompact: CGFloat = 64
}

// MARK: - Background

/// The space the whole window sits in: one continuous paper. The route is drawn
/// directly on it with ink lines and the vermilion star; cards float by hairlines.
struct LPBackground: View {
    var body: some View {
        LP.space
            .ignoresSafeArea()
    }
}

// MARK: - Paper surfaces

/// Paper + hairline. The only content surface: cards, the sidebar, inputs sit on it.
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

/// Pill control surface: paper + hairline, used by chips and inline pickers.
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

// MARK: - Liquid Glass

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
        // Same paper + hairline as every other surface. The old 0.5pt separator at
        // half strength vanished at 1× and left cards as unexplained white patches.
        content
            .padding(padding)
            .modifier(LPSheetSurface(radius: radius))
    }
}

extension View {
    func lpPanel(radius: CGFloat = LP.radius, padding: CGFloat = 18, raised: Bool = false) -> some View {
        modifier(LEAPIN_PanelModifier(radius: radius, padding: padding, raised: raised))
    }

    /// Standard page container: the shell's one inset, top-aligned.
    /// No maximum width: pages that scroll and pages that do not used to disagree
    /// about the measure, so content jumped sideways when switching pages.
    func lpPage() -> some View {
        self.frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, LPSpace.inset)
            .padding(.vertical, 20)
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

/// The name of a group in the chrome: a sidebar section, a table column, a rail.
/// Sans, 11pt, secondary. The mono eyebrow (`LPEyebrow`) is for data.
struct LPLabel: View {
    var text: String
    var tint: Color = LP.textSecondary

    init(_ text: String, tint: Color = LP.textSecondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .tracking(0.2)
            .foregroundStyle(tint)
            .lineLimit(1)
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

/// Keyboard focus ring: reads the nearest focusable ancestor's focus state and
/// draws a 2pt vermilion ring outside the shape. It lives inside the button styles,
/// so every button that uses one of them is keyboard-visible without a @FocusState.
struct LPButtonFocusRing<S: InsettableShape, Content: View>: View {
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

/// One height for every button so a toolbar rows up: 13pt text + 7pt above and below.
private let lpButtonShape = RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous)
private let lpButtonOverlay = RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous)

struct LPPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        let fill = isEnabled ? (tint ?? LP.accentFill) : LP.stroke
        return LPButtonFocusRing(shape: lpButtonShape) {
            // 主操作保持不透明实色：tint 玻璃在浅底上会把朱红洗成灰，
            // 白字对比掉到 2:1 以下——可读性优先于材质一致性。
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isEnabled ? .white : LP.textTertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(lpButtonOverlay.fill(fill))
                .overlay(
                    lpButtonOverlay
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                )
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .opacity(configuration.isPressed ? 0.86 : 1)
                .lpAnimation(LPMotion.press, value: configuration.isPressed)
        }
    }
}

/// The quiet button: hairline, no fill, ink text. Hover and press tint it with ink.
struct LPGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        LPButtonFocusRing(shape: lpButtonShape) {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? LP.text : LP.textTertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    lpButtonOverlay.fill(configuration.isPressed
                                         ? LP.text.opacity(0.10)
                                         : (hovering ? LP.hover : Color.clear))
                )
                .overlay(lpButtonOverlay.strokeBorder(isEnabled ? LP.lineStrong : LP.line, lineWidth: 1))
        }
        .onHover { hovering = $0 }
    }
}

/// The quiet button for the ink band: same shape and metrics as the ghost, drawn
/// in white so a second action on the band is reachable without a second red button.
struct LPOnInkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        LPButtonFocusRing(shape: lpButtonShape) {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? LP.onInk : LP.onInkTertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    lpButtonOverlay.fill(configuration.isPressed
                                         ? Color.white.opacity(0.16)
                                         : (hovering ? Color.white.opacity(0.10) : Color.white.opacity(0.04)))
                )
                .overlay(lpButtonOverlay.strokeBorder(Color.white.opacity(isEnabled ? 0.22 : 0.10), lineWidth: 1))
        }
        .onHover { hovering = $0 }
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

// MARK: - Status

struct StatusDot: View {
    var color: Color
    var pulsing: Bool = false
    var size: CGFloat = 6
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if pulsing {
                Circle()
                    .fill(color.opacity(0.30))
                    .frame(width: size * 2, height: size * 2)
                    .scaleEffect(on ? 1.35 : 0.7)
                    .opacity(on ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 1.8).repeatForever(autoreverses: false), value: on)
            }
            Circle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size * 2, height: size * 2)
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
    /// 「跃」：换路生效时，朱红点在新的一站弹出。没有飞行轨迹——
    /// 品牌的主图形就是「A 消失，B 出现，留白是瞬间」。
    static let leap = Animation.spring(response: 0.34, dampingFraction: 0.62)
    /// 「弦」：换路生效的那一下，判据到出口之间的连线亮起再暗下去。
    /// 只在状态切换时出现，不做装饰。
    static let chord = Animation.easeOut(duration: 0.55)

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
                    .font(LPFont.mono(11, weight: .medium))
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

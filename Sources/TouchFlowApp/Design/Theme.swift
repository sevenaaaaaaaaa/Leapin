import SwiftUI
import AppKit

// MARK: - Palette

/// Dynamic (light/dark) colour tokens for the whole app.
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

    // Surfaces
    static let bg = dyn(hex(0xF3F5FA), hex(0x080B11))
    static let bgDeep = dyn(hex(0xE9EDF6), hex(0x05070B))
    static let panel = dyn(hex(0xFFFFFF, 0.86), hex(0x121826, 0.72))
    static let panelSolid = dyn(hex(0xFFFFFF), hex(0x121826))
    static let panelRaised = dyn(hex(0xFFFFFF), hex(0x18202F))
    static let stroke = dyn(hex(0x101828, 0.10), hex(0xFFFFFF, 0.09))
    static let strokeStrong = dyn(hex(0x101828, 0.18), hex(0xFFFFFF, 0.16))

    // Text
    static let text = dyn(hex(0x111A28), hex(0xEDF2FB))
    static let textSecondary = dyn(hex(0x5A6779), hex(0x99A7BC))
    static let textTertiary = dyn(hex(0x8B98AB), hex(0x6B7A90))

    // Accents
    static let accent = dyn(hex(0x3D6BFF), hex(0x6E93FF))
    static let accentSoft = dyn(hex(0x3D6BFF, 0.12), hex(0x6E93FF, 0.18))
    static let violet = dyn(hex(0x7B5CFF), hex(0x9B84FF))
    static let mint = dyn(hex(0x0FBFA4), hex(0x3BE0C2))
    static let amber = dyn(hex(0xE08A00), hex(0xFFB84D))
    static let danger = dyn(hex(0xE23D4F), hex(0xFF6B7C))
    static let success = dyn(hex(0x0FA36B), hex(0x35E39B))

    static var brand: LinearGradient {
        LinearGradient(colors: [accent, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var mintGradient: LinearGradient {
        LinearGradient(colors: [mint, accent], startPoint: .leading, endPoint: .trailing)
    }

    // Metrics
    static let radius: CGFloat = 14
    static let radiusSmall: CGFloat = 9
    static let gutter: CGFloat = 18
}

// MARK: - Typography

enum TFFont {
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static func num(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static let overline = Font.system(size: 10, weight: .semibold)
}

// MARK: - Background

struct TFBackground: View {
    var body: some View {
        ZStack {
            TF.bg
            // soft aurora glows
            GeometryReader { geo in
                Circle()
                    .fill(TF.accent.opacity(0.10))
                    .frame(width: geo.size.width * 0.55)
                    .blur(radius: 120)
                    .offset(x: -geo.size.width * 0.18, y: -geo.size.height * 0.30)
                Circle()
                    .fill(TF.mint.opacity(0.08))
                    .frame(width: geo.size.width * 0.45)
                    .blur(radius: 130)
                    .offset(x: geo.size.width * 0.62, y: geo.size.height * 0.55)
            }
            TFGrid()
                .opacity(0.55)
        }
        .ignoresSafeArea()
    }
}

/// Faint 32pt technical grid — gives the "instrument" feel without noise.
private struct TFGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let step: CGFloat = 32
            var x: CGFloat = 0
            while x <= size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y: CGFloat = 0
            while y <= size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            context.stroke(path, with: .color(TF.stroke.opacity(0.35)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Panels

struct TF_PanelModifier: ViewModifier {
    var radius: CGFloat = TF.radius
    var padding: CGFloat = 16
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
                    .strokeBorder(TF.stroke, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 14, x: 0, y: 6)
    }
}

extension View {
    func tfPanel(radius: CGFloat = TF.radius, padding: CGFloat = 16, raised: Bool = false) -> some View {
        modifier(TF_PanelModifier(radius: radius, padding: padding, raised: raised))
    }

    /// Standard page container: max width + generous rhythm.
    func tfPage() -> some View {
        self.frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
    }
}

// MARK: - Section header

struct SectionHeader: View {
    var title: String
    var subtitle: String? = nil
    var icon: String? = nil
    var tint: Color = TF.accent

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.14))
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 24, height: 24)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(TFFont.display(13.5, weight: .semibold))
                    .foregroundStyle(TF.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(TF.textTertiary)
                }
            }
            Spacer(minLength: 8)
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
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TF.accent)
                    Text(title)
                        .font(TFFont.display(20, weight: .bold))
                        .foregroundStyle(TF.text)
                }
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(TF.textTertiary)
            }
            Spacer()
            actions()
        }
        .padding(.horizontal, 26)
        .padding(.top, 18)
        .padding(.bottom, 14)
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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AnyShapeStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(TF.brand)))
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .shadow(color: (tint ?? TF.accent).opacity(0.25), radius: 8, y: 3)
    }
}

struct TFGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(TF.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(TF.stroke.opacity(configuration.isPressed ? 1.6 : 0.9),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                    .fill(color.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .scaleEffect(on ? 1.25 : 0.75)
                    .opacity(on ? 0 : 1)
                    .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: on)
            }
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .onAppear { on = true }
    }
}

struct TFDivider: View {
    var body: some View {
        Rectangle().fill(TF.stroke).frame(height: 1)
    }
}

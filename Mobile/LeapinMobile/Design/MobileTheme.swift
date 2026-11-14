import SwiftUI

/// The same tokens as the desktop app, rebuilt for iOS so both clients read as
/// one product: warm off-white paper in light mode, near-black slate in dark.
enum LP {
    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(UIColor { traits in
            let dark_ = traits.userInterfaceStyle == .dark
            return UIColor(srgbHex: dark_ ? dark : light,
                           alpha: CGFloat(dark_ ? darkAlpha : lightAlpha))
        })
    }

    static let canvas = adaptive(light: 0xF6F4EF, dark: 0x101012)
    static let panel = adaptive(light: 0xFCFBF8, dark: 0x151517)
    static let panelRaised = adaptive(light: 0xFFFFFF, dark: 0x1F1F22)
    static let stroke = adaptive(light: 0x16150F, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.12)
    static let strokeStrong = adaptive(light: 0x16150F, dark: 0xFFFFFF, lightAlpha: 0.20, darkAlpha: 0.20)

    static let text = adaptive(light: 0x16150F, dark: 0xF3F1EA)
    static let textSecondary = adaptive(light: 0x5F5C53, dark: 0xA6A39A)
    static let textTertiary = adaptive(light: 0x6F6B60, dark: 0x87847B)

    static let accent = adaptive(light: 0xC63A12, dark: 0xFF7A4D)
    static let accentFill = adaptive(light: 0xB83510, dark: 0xC2410F)
    static let accentSoft = adaptive(light: 0xC63A12, dark: 0xFF7A4D, lightAlpha: 0.09, darkAlpha: 0.15)
    static let mint = adaptive(light: 0x0C7A55, dark: 0x35D19B)
    static let amber = adaptive(light: 0x8F5E07, dark: 0xE8B04A)
    static let danger = adaptive(light: 0xB32636, dark: 0xFF6B74)
    static let violet = adaptive(light: 0x5446B8, dark: 0xB0A3FF)

    static let radius: CGFloat = 14
    static let radiusSmall: CGFloat = 8
    static let gutter: CGFloat = 16
}

extension UIColor {
    convenience init(srgbHex value: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - Typography

enum LPFont {
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let title = display(22, weight: .semibold)
    static let section = display(15, weight: .semibold)
    static let body = display(14)
    static let caption = display(12)
    static let micro = display(11, weight: .medium)
}

// MARK: - Components

/// Grouped container: raised panel with a hairline border, no drop shadows.
struct LPCard<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(LPFont.section)
                        .foregroundStyle(LP.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(LPFont.micro)
                            .foregroundStyle(LP.textTertiary)
                    }
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LP.panel, in: RoundedRectangle(cornerRadius: LP.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LP.radius, style: .continuous)
                .strokeBorder(LP.stroke, lineWidth: 1)
        )
    }
}

/// One headline number with its label and optional unit.
struct LPStat: View {
    var label: String
    var value: String
    var unit: String?
    var tint: Color = LP.text

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(LPFont.micro)
                .foregroundStyle(LP.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(LPFont.display(20, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(LPFont.micro)
                        .foregroundStyle(LP.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small status chip. Colour carries meaning; the label always says it in words too.
struct LPPill: View {
    var text: String
    var tint: Color
    var filled = false

    var body: some View {
        Text(text)
            .font(LPFont.micro)
            .foregroundStyle(filled ? .white : tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(filled ? tint : tint.opacity(0.14))
            )
    }
}

struct LPRow: View {
    var key: String
    var value: String
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .font(LPFont.caption)
                .foregroundStyle(LP.textTertiary)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? LPFont.mono(12) : LPFont.caption)
                .foregroundStyle(LP.textSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}

/// Filled primary button matching the desktop accent.
struct LPButtonStyle: ButtonStyle {
    var tint: Color = LP.accentFill
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LPFont.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 11)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 0 : 16)
            .background(
                RoundedRectangle(cornerRadius: LP.radiusSmall + 2, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.82 : 1))
            )
    }
}

extension View {
    /// Page background: the warm canvas plus the standard gutter.
    /// The bottom inset clears the floating iOS 26 tab bar, which overlays scroll content.
    func lpPage() -> some View {
        self
            .padding(.horizontal, LP.gutter)
            .padding(.top, 12)
            .padding(.bottom, 88)
            .background(LP.canvas)
    }
}

// MARK: - Formatting

enum LPFormat {
    static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(value)
        var index = 0
        while size >= 1024, index < units.count - 1 {
            size /= 1024
            index += 1
        }
        return index == 0 ? "\(Int(size)) \(units[index])"
                          : String(format: "%.1f %@", size, units[index])
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds)) 秒" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟" }
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        return minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分"
    }

    static func milliseconds(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.2f s", value / 1000) : String(format: "%.0f ms", value)
    }

    static func timeAgo(_ date: Date?) -> String {
        guard let date else { return "尚未刷新" }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 3 { return "刚刚" }
        if seconds < 60 { return "\(Int(seconds)) 秒前" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        return "\(Int(seconds / 3600)) 小时前"
    }
}

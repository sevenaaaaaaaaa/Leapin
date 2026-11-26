import SwiftUI

/// The single ink band a screen is allowed (DESIGN-v5 §3, §7).
///
/// Slot order is fixed: eyebrow → the route → facts → one primary action.
/// Nothing else goes in; a second band on the same screen is a bug.
///
/// The band is the product's one dark surface: it is where "where is my traffic
/// going right now" lives, so everything on it is white at three weights and the
/// one vermilion point. In dark mode the band is lifted a step above the paper
/// and given a hairline, otherwise the focus band is not a focus band.
struct FocusBand<Content: View>: View {
    var eyebrow: String? = nil
    @ViewBuilder var content: Content

    init(_ eyebrow: String? = nil, @ViewBuilder content: () -> Content) {
        self.eyebrow = eyebrow
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let eyebrow {
                Text(eyebrow)
                    .font(LPFont.mono(11, weight: .medium))
                    .tracking(1.1)
                    .foregroundStyle(LP.onInkTertiary)
            }
            content
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LPRadius.panel, style: .continuous)
                .fill(LP.ink)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LPRadius.panel, style: .continuous)
                .strokeBorder(LP.inkBorder, lineWidth: 1)
        )
    }
}

/// One fact on the band: an 11pt mono label over a 20pt mono number.
struct RouteFact: View {
    var key: String
    var value: String
    var unit: String? = nil

    init(_ key: String, _ value: String, unit: String? = nil) {
        self.key = key
        self.value = value
        self.unit = unit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(LP.onInkTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LP.onInk)
                    .lineLimit(1)
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LP.onInkSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A hairline on the band.
struct InkRule: View {
    var body: some View {
        Rectangle().fill(LP.inkLine).frame(height: 1)
    }
}

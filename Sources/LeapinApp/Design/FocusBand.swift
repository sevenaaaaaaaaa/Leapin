import SwiftUI

/// The single ink band a screen is allowed (DESIGN-v5 §3, §7).
///
/// Slot order is fixed: eyebrow → one route line → facts → one primary action.
/// Nothing else goes in; a second band on the same screen is a bug.
struct FocusBand<Content: View>: View {
    var eyebrow: String?
    @ViewBuilder var content: Content

    init(_ eyebrow: String? = nil, @ViewBuilder content: () -> Content) {
        self.eyebrow = eyebrow
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let eyebrow {
                Text(eyebrow)
                    .font(LPType.label)
                    .tracking(1.1)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.55))
            }
            content
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LPRadius.panel, style: .continuous)
                .fill(LP.ink)
        )
    }
}

/// One fact inside a focus band: an 11pt label over a 20pt mono number.
struct RouteFact: View {
    var key: String
    var value: String
    var unit: String?

    init(_ key: String, _ value: String, unit: String? = nil) {
        self.key = key
        self.value = value
        self.unit = unit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key)
                .font(LPType.label)
                .foregroundStyle(.white.opacity(0.50))
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(LPType.data)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let unit {
                    Text(unit)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
    }
}

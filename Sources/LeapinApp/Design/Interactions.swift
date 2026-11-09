import SwiftUI
import AppKit

// MARK: - Rows

/// A clickable list row with hover, pressed, selected and focus feedback.
/// Use this instead of `.onTapGesture` so rows stay keyboard reachable.
struct LPRow<Content: View>: View {
    var selected: Bool = false
    var accessibilityText: String? = nil
    var action: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            content()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.055) : (hovering ? LP.stroke.opacity(0.55) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? LP.strokeStrong.opacity(0.7) : Color.clear, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            if selected {
                Capsule().fill(LP.accent).frame(width: 2, height: 15).padding(.leading, 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .lpAnimation(LPMotion.press, value: selected)
        .lpAnimation(LPMotion.press, value: hovering)
        .accessibilityLabel(accessibilityText ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Search

struct LPSearchField: View {
    @Binding var text: String
    var placeholder: String
    var width: CGFloat = 320
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(focus.wrappedValue ? LP.accent : LP.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(focus)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(LP.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .lpGlass(in: Capsule(style: .continuous),
                 fallbackFill: LP.stroke.opacity(0.5),
                 fallbackMaterial: .thinMaterial)
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(focus.wrappedValue ? LP.accent.opacity(0.75) : Color.clear, lineWidth: 1.2)
                .padding(-1)
                .lpAnimation(LPMotion.quick, value: focus.wrappedValue)
        )
        .frame(maxWidth: width)
        .accessibilityLabel(placeholder)
    }
}

// MARK: - Chips

/// Filter chip with optional count. Selected state is announced to VoiceOver.
struct LPChip: View {
    var title: String
    var count: Int? = nil
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                if let count {
                    Text("\(count)").font(LPFont.num(9.5, weight: .medium)).opacity(0.75)
                }
            }
            .foregroundStyle(selected ? LP.text : LP.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(selected ? LP.accentSoft : LP.stroke.opacity(0.4))
            )
            .overlay(
                Capsule().strokeBorder(selected ? LP.accent.opacity(0.35) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Key hints

struct LPKeyCap: View {
    var keys: String
    var body: some View {
        Text(keys)
            .font(LPFont.mono(10, weight: .medium))
            .foregroundStyle(LP.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(LP.stroke.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Progress

/// Thin determinate/indeterminate progress line used for long-running work.
struct LPProgressLine: View {
    var value: Double? = nil
    @State private var phase: CGFloat = -0.3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(LP.stroke.opacity(0.6))
                if let value {
                    Capsule().fill(LP.brand)
                        .frame(width: max(3, geo.size.width * min(max(value, 0), 1)))
                } else {
                    Capsule().fill(LP.brand)
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: geo.size.width * phase)
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                                phase = 1.1
                            }
                        }
                }
            }
        }
        .frame(height: 3)
        .clipShape(Capsule())
        .accessibilityLabel("进度")
    }
}

// MARK: - Empty state with a way out

struct LPEmptyState: View {
    var icon: String
    var title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(LP.textTertiary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LP.textSecondary)
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(LP.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(LPPrimaryButtonStyle())
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(26)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Confirmation

extension View {
    /// Destructive actions always go through a visible confirmation.
    func lpConfirm(_ title: String,
                   message: String,
                   isPresented: Binding<Bool>,
                   confirmTitle: String = "确认",
                   destructive: Bool = true,
                   action: @escaping () -> Void) -> some View {
        confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            Button(confirmTitle, role: destructive ? .destructive : nil, action: action)
            Button("取消", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

// MARK: - Copy helper

enum LPClipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

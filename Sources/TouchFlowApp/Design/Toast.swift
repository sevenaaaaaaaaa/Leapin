import SwiftUI

/// Four-state feedback used across the app. Errors must never look like success.
enum TFToastKind: String {
    case success
    case warning
    case error
    case info

    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success: return TF.success
        case .warning: return TF.amber
        case .error: return TF.danger
        case .info: return TF.accent
        }
    }
}

/// Bottom-anchored toast with an optional single action (撤销 / 重试 / 查看).
struct ToastOverlay: View {
    let text: String
    let kind: TFToastKind
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: kind.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(kind.tint)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(TF.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle) { action() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(TF.accent)
                    .padding(.leading, 2)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(TF.textTertiary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(TF.panelSolid, in: Capsule())
        .overlay(Capsule().strokeBorder(kind.tint.opacity(0.28), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.rawValue)：\(text)")
    }
}

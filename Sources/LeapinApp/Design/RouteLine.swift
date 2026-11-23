import SwiftUI

/// 一条路 — the one decorative geometry of the product (DESIGN-v5 §3).
///
/// Every screen tells one routing decision the same way: 你 → 判据 → 出口.
/// Horizontal on the first screen, vertical inside a trace. Only the current
/// node may use the signal colour; everything else stays quiet.
struct RouteLine: View {
    enum Axis { case horizontal, vertical }

    enum NodeState { case idle, current, alert }

    struct Node: Identifiable {
        let id = UUID()
        var title: String
        var subtitle: String?
        var state: NodeState

        init(_ title: String, subtitle: String? = nil, state: NodeState = .idle) {
            self.title = title
            self.subtitle = subtitle
            self.state = state
        }
    }

    var nodes: [Node]
    var axis: Axis = .horizontal
    /// True when the line sits inside an ink focus band.
    var onInk: Bool = true

    var body: some View {
        switch axis {
        case .horizontal: horizontalBody
        case .vertical: verticalBody
        }
    }

    // MARK: colours

    private var titleColor: Color { onInk ? Color.white.opacity(0.96) : LP.text }
    private var subColor: Color { onInk ? Color.white.opacity(0.55) : LP.textTertiary }
    private var idleDot: Color { onInk ? Color.white.opacity(0.35) : LP.textTertiary.opacity(0.55) }
    private var connector: Color { onInk ? Color.white.opacity(0.18) : LP.line }

    private func dotColor(_ state: NodeState) -> Color {
        switch state {
        case .idle: return idleDot
        case .current, .alert: return LP.accent
        }
    }

    private func labelColor(_ state: NodeState) -> Color {
        state == .idle ? titleColor : LP.accent
    }

    // MARK: horizontal

    private var horizontalBody: some View {
        HStack(spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                nodeView(node)
                if index < nodes.count - 1 {
                    connectorView
                }
            }
        }
    }

    private func nodeView(_ node: Node) -> some View {
        HStack(spacing: 10) {
            dot(node.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(labelColor(node.state))
                    .lineLimit(1)
                if let subtitle = node.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(subColor)
                        .lineLimit(1)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var connectorView: some View {
        Rectangle()
            .fill(connector)
            .frame(height: 1)
            .frame(minWidth: 24, maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                Circle().fill(connector).frame(width: 5, height: 5)
            }
            .padding(.horizontal, 14)
    }

    // MARK: vertical

    private var verticalBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        dot(node.state)
                        if index < nodes.count - 1 {
                            Rectangle().fill(connector).frame(width: 1).frame(maxHeight: .infinity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(labelColor(node.state))
                        if let subtitle = node.subtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(subColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.bottom, index < nodes.count - 1 ? 16 : 0)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func dot(_ state: NodeState) -> some View {
        Circle()
            .fill(dotColor(state))
            .frame(width: 8, height: 8)
            .padding(.top, 4)
            .background {
                if state == .current || state == .alert {
                    Circle().fill(LP.accent.opacity(0.18)).frame(width: 16, height: 16).offset(y: 4)
                }
            }
    }
}

#Preview("horizontal") {
    ZStack {
        LP.ink
        RouteLine(nodes: [
            .init("你", subtitle: "这台 Mac"),
            .init("规则 3", subtitle: "COMPANY → 公司"),
            .init("公司 · HK 01", subtitle: "42 ms · 规则模式", state: .current),
        ])
        .padding(28)
    }
    .frame(width: 720, height: 140)
}

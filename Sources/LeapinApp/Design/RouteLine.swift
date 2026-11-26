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
        /// 这条路的主角（出口）：字号升到 22，是所在那一页唯一的大字。
        var prominent: Bool = false

        init(_ title: String, subtitle: String? = nil, state: NodeState = .idle, prominent: Bool = false) {
            self.title = title
            self.subtitle = subtitle
            self.state = state
            self.prominent = prominent
        }
    }

    var nodes: [Node]
    var axis: Axis = .horizontal
    /// True when the line sits inside an ink focus band.
    var onInk: Bool = true
    /// 常驻层用的紧凑形态：不显示副标题、点更小、连接线更短。
    /// 默认 false —— 首屏与「为什么」页的既有调用一个字都不用改。
    var compact: Bool = false

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
        HStack(alignment: .firstTextBaseline, spacing: compact ? 6 : 10) {
            dot(node.state, prominent: node.prominent)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + (compact ? 3 : 4) }
            VStack(alignment: .leading, spacing: node.prominent ? 3 : 2) {
                Text(node.title)
                    .font(.system(size: compact ? 12 : (node.prominent ? 22 : 14), weight: .semibold))
                    .tracking(node.prominent ? -0.3 : 0)
                    .foregroundStyle(labelColor(node.state))
                    .lineLimit(1)
                if let subtitle = node.subtitle, !compact {
                    Text(subtitle)
                        .font(.system(size: compact ? 11 : 12))
                        .foregroundStyle(subColor)
                        .lineLimit(1)
                }
            }
        }
        // 紧凑形态允许被压缩：常驻层只有 280pt，宁可截断也不把面板撑破。
        .fixedSize(horizontal: !compact, vertical: false)
    }

    private var connectorView: some View {
        Rectangle()
            .fill(connector)
            .frame(height: 1)
            .frame(minWidth: compact ? 10 : 24, maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                Circle().fill(connector).frame(width: compact ? 4 : 5, height: compact ? 4 : 5)
            }
            .padding(.horizontal, compact ? 8 : 14)
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

    private func dot(_ state: NodeState, prominent: Bool = false) -> some View {
        Circle()
            .fill(dotColor(state))
            .frame(width: compact ? 6 : (prominent ? 10 : 8),
                   height: compact ? 6 : (prominent ? 10 : 8))
            .background {
                if state == .current || state == .alert {
                    Circle().fill(LP.accent.opacity(0.18))
                        .frame(width: compact ? 12 : (prominent ? 22 : 16),
                               height: compact ? 12 : (prominent ? 22 : 16))
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

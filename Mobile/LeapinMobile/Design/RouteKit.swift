import SwiftUI

/// v5 的「一条路」：全产品唯一的装饰几何。
///
/// 三节点（你 → 判据 → 出口），当前节点用朱红并带一圈光。桌面端叫 RouteLine，
/// iOS 与 Android 用同一套画法与同一组色值，读起来才像一个产品。
struct RouteLine: View {
    var nodes: [String]
    var current: Int
    var axis: Axis = .horizontal
    var onInk: Bool = false
    var compact: Bool = false

    private var activeText: Color { onInk ? LP.onInk : LP.text }
    private var dimText: Color { onInk ? LP.onInkSecondary : LP.textSecondary }
    private var connector: Color {
        onInk ? LP.onInkSecondary.opacity(0.32) : LP.stroke
    }

    var body: some View {
        switch axis {
        case .horizontal: horizontal
        case .vertical: vertical
        }
    }

    private var horizontal: some View {
        HStack(spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { index, name in
                node(index, name)
                if index < nodes.count - 1 {
                    Rectangle()
                        .fill(connector)
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 20)
                }
            }
        }
    }

    private var vertical: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { index, name in
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        dot(index)
                        if index < nodes.count - 1 {
                            Rectangle()
                                .fill(connector)
                                .frame(width: 1)
                                .frame(maxHeight: .infinity)
                                .padding(.vertical, 3)
                        }
                    }
                    .frame(width: 16)
                    Text(name)
                        .font(compact ? LPFont.micro : LPFont.caption)
                        .foregroundStyle(index == current ? activeText : dimText)
                        .padding(.top, 1)
                        .padding(.bottom, 16)
                }
            }
        }
    }

    private func node(_ index: Int, _ name: String) -> some View {
        VStack(spacing: 6) {
            dot(index)
            Text(name)
                .font(compact ? LPFont.micro : LPFont.caption)
                .foregroundStyle(index == current ? activeText : dimText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func dot(_ index: Int) -> some View {
        let active = index == current
        return ZStack {
            if active {
                Circle()
                    .fill(LP.accent.opacity(0.26))
                    .frame(width: 16, height: 16)
            }
            Circle()
                .fill(active ? LP.accent : (onInk ? LP.onInkSecondary : LP.textTertiary))
                .frame(width: 7, height: 7)
        }
        .frame(width: 16, height: 16)
    }
}

/// 墨色焦点带：每屏最多一个，承载「一条路 + 事实 + 主操作」。
struct FocusBand<Content: View>: View {
    var eyebrow: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let eyebrow {
                Text(eyebrow)
                    .font(LPFont.label)
                    .tracking(0.8)
                    .foregroundStyle(LP.onInkSecondary)
            }
            content
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LP.ink, in: RoundedRectangle(cornerRadius: LP.radius, style: .continuous))
    }
}

/// 一条事实：11 标签 + 20 mono 数值，焦点带里四个一排。
struct LPFact: View {
    var label: String
    var value: String
    /// 数字用 20 mono；状态词用 13 正文，避免中文被放大成标题。
    var mono: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(LPFont.label)
                .foregroundStyle(LP.onInkSecondary)
            Text(value)
                .font(mono ? LPFont.number : LPFont.body.weight(.medium))
                .foregroundStyle(LP.onInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// v5 页头：28 标题 + 一句状态，左对齐，不靠系统大标题。
struct LPPageHeader: View {
    var title: String
    var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(LPFont.title)
                .foregroundStyle(LP.text)
                .fixedSize(horizontal: false, vertical: true)
            if let status {
                Text(status)
                    .font(LPFont.body)
                    .foregroundStyle(LP.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

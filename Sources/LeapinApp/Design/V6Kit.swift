import SwiftUI

// MARK: - v6 · Live Instrument（macOS）
//
// 与 iOS 同一套交互语法：可拖的路、可回看的时间河。
// 桌面不做「编排」与「草稿行」的接线；组件在 iOS 侧先跑通，再移植。

enum LPHaptic {
    static func soft() {}
    static func select() {}
    static func success() {}
    static func warning() {}
}

extension LP {
    /// ink 面上的两级文字。桌面 v5 之前只在 FocusBand 里临时用 `.white.opacity`，
    /// 现在集中成两个 token，免得每个调用点各写一个透明度。
    static let inkText = Color.white.opacity(0.94)
    static let inkTextSecondary = Color.white.opacity(0.60)
}

/// 「你 → 判据 → 出口」的第三条腿是可拖的。
///
/// 按住出口上下拖，候选在下方浮出并吸附；松手才提交。
/// `compact` 用于 280pt 的菜单栏面板：节点更窄、字号更小，但手势不变。
struct LPRouteScrubber: View {
    struct Stop: Identifiable, Equatable {
        var id: String
        var label: String
        var detail: String
    }

    var stops: [Stop]
    var selectedID: String
    var judge: String
    var enabled: Bool
    var compact = false
    var onInk = false
    var onCommit: (String) -> Void

    @State private var scrubbing = false
    @State private var index = 0
    @State private var startedIndex = 0

    private var currentIndex: Int {
        stops.firstIndex(where: { $0.id == selectedID }) ?? 0
    }

    private var selected: Stop? {
        stops.first(where: { $0.id == selectedID }) ?? stops.first
    }

    private var ink: Color { onInk ? LP.inkText : LP.text }
    private var inkSoft: Color { onInk ? LP.inkTextSecondary : LP.textTertiary }
    private var nodeWidth: CGFloat { compact ? 62 : 84 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            HStack(spacing: 0) {
                endpoint(title: "你", detail: compact ? nil : "这台 Mac", filled: false)
                connector
                endpoint(title: "判据", detail: compact ? nil : judge, filled: false)
                connector
                exitControl
            }
            if scrubbing, stops.count > 1 {
                candidateRail
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: scrubbing)
    }

    private func endpoint(title: String, detail: String?, filled: Bool) -> some View {
        VStack(spacing: compact ? 3 : 5) {
            Circle()
                .fill(filled ? LP.accent : ink.opacity(0.9))
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: compact ? 10.5 : 12, weight: .semibold))
                .foregroundStyle(ink)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(inkSoft)
                    .lineLimit(1)
            }
        }
        .frame(width: nodeWidth)
    }

    private var connector: some View {
        Rectangle()
            .fill(inkSoft.opacity(0.40))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private var exitControl: some View {
        Button {
            guard enabled, stops.count > 1 else { LPHaptic.warning(); return }
            let next = stops[(currentIndex + 1) % stops.count]
            onCommit(next.id)
        } label: {
            VStack(spacing: compact ? 3 : 5) {
                Circle()
                    .fill(LP.accent)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(LP.accent.opacity(0.28), lineWidth: 5))
                Text(scrubbing ? stops[safe: index]?.label ?? "—" : selected?.label ?? "—")
                    .font(.system(size: compact ? 10.5 : 12, weight: .semibold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 3) {
                    Image(systemName: "chevron.up")
                    Image(systemName: "chevron.down")
                }
                .font(.system(size: 6.5, weight: .bold))
                .foregroundStyle(enabled && stops.count > 1 ? inkSoft : inkSoft.opacity(0.4))
            }
            .frame(width: compact ? 70 : 96)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .highPriorityGesture(scrubGesture, including: enabled && stops.count > 1 ? .all : .subviews)
        .help(enabled ? "上下拖切换出口" : "未接管：没有可切换的出口")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("出口")
        .accessibilityValue(selected?.label ?? "未设置")
        .accessibilityHint("上下轻扫切换出口")
        .accessibilityAdjustableAction { direction in
            guard enabled, stops.count > 1 else { return }
            switch direction {
            case .increment:
                onCommit(stops[(currentIndex + 1) % stops.count].id)
            case .decrement:
                onCommit(stops[(currentIndex - 1 + stops.count) % stops.count].id)
            @unknown default:
                break
            }
        }
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard enabled, stops.count > 1 else { return }
                if !scrubbing {
                    scrubbing = true
                    startedIndex = currentIndex
                    index = currentIndex
                    LPHaptic.soft()
                }
                let step = Int((-value.translation.height / (compact ? 26 : 34)).rounded())
                let next = min(max(startedIndex + step, 0), stops.count - 1)
                if next != index {
                    index = next
                    LPHaptic.select()
                }
            }
            .onEnded { _ in
                guard scrubbing else { return }
                let chosen = stops[safe: index]
                scrubbing = false
                guard let chosen, chosen.id != selectedID else { return }
                onCommit(chosen.id)
            }
    }

    private var candidateRail: some View {
        VStack(spacing: 0) {
            ForEach(Array(stops.enumerated()), id: \.element.id) { offset, stop in
                HStack(spacing: 7) {
                    Rectangle()
                        .fill(offset == index ? LP.accent : inkSoft.opacity(0.35))
                        .frame(width: offset == index ? 12 : 5, height: 1)
                    Text(stop.label)
                        .font(.system(size: compact ? 10.5 : 12,
                                      weight: offset == index ? .semibold : .regular))
                        .foregroundStyle(offset == index ? ink : inkSoft)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !stop.detail.isEmpty {
                        Text(stop.detail)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(inkSoft)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, compact ? 3 : 5)
                .padding(.horizontal, 6)
                .background(offset == index ? ink.opacity(0.08) : Color.clear)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct LPRiverSample: Equatable {
    var down: Double
    var up: Double
    static let zero = LPRiverSample(down: 0, up: 0)
}

/// 60 秒速率河。数据由调用方每秒喂一次（`ResidentRates` 已经是字节/秒）。
struct LPRiver: View {
    var samples: [LPRiverSample]
    var frozenIndex: Int?
    var enabled: Bool
    var onInk = true
    var height: CGFloat = 44
    var onScrub: (Int?) -> Void

    private var ink: Color { onInk ? LP.inkText : LP.text }

    private var isIdle: Bool {
        samples.allSatisfy { $0.down <= 0.0001 && $0.up <= 0.0001 }
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let count = max(samples.count, 1)
                let slot = size.width / CGFloat(count)
                let barWidth = max(1.5, slot * 0.52)
                let mid = size.height / 2
                let idle = samples.allSatisfy { $0.down <= 0.0001 && $0.up <= 0.0001 }

                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: mid))
                baseline.addLine(to: CGPoint(x: size.width, y: mid))
                context.stroke(baseline, with: .color(ink.opacity(idle ? 0.30 : 0.18)),
                               lineWidth: idle ? 1 : 0.5)

                if !idle {
                    for (offset, sample) in samples.enumerated() {
                        let x = CGFloat(offset) * slot + (slot - barWidth) / 2
                        let past = frozenIndex.map { offset > $0 } ?? false
                        let alpha = past ? 0.18 : (enabled ? 0.9 : 0.25)

                        let downHeight = max(1.5, CGFloat(sample.down) * (mid - 3))
                        context.fill(
                            Path(roundedRect: CGRect(x: x, y: mid + 1, width: barWidth, height: downHeight),
                                 cornerRadius: barWidth / 2),
                            with: .color(ink.opacity(alpha)))

                        let upHeight = max(1.0, CGFloat(sample.up) * (mid - 3))
                        if upHeight > 1.4 {
                            context.fill(
                                Path(roundedRect: CGRect(x: x, y: mid - 1 - upHeight,
                                                         width: barWidth, height: upHeight),
                                     cornerRadius: barWidth / 2),
                                with: .color(LP.accent.opacity(past ? 0.2 : alpha)))
                        }
                    }
                }

                if let frozenIndex, frozenIndex >= 0, frozenIndex < count {
                    let x = CGFloat(frozenIndex) * slot + slot / 2
                    var cursor = Path()
                    cursor.move(to: CGPoint(x: x, y: 0))
                    cursor.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(cursor, with: .color(LP.accent), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard enabled, !samples.isEmpty else { return }
                        let ratio = min(max(value.location.x / max(geo.size.width, 1), 0), 0.999)
                        onScrub(Int(ratio * CGFloat(samples.count)))
                        LPHaptic.select()
                    }
                    .onEnded { _ in
                        Task {
                            try? await Task.sleep(for: .seconds(3))
                            onScrub(nil)
                        }
                    }
            )
        }
        .frame(height: height)
        .overlay {
            if isIdle {
                Text(enabled ? "打开一个网页，波形从这里开始" : "引擎停止，没有波形")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.52))
                    .offset(y: -13)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement()
        .accessibilityIdentifier("lp.river")
        .accessibilityLabel("最近一分钟流量")
        .accessibilityValue(enabled ? "实时" : "已停止")
        .accessibilityAdjustableAction { direction in
            let base = frozenIndex ?? samples.count - 1
            let next = direction == .increment ? min(base + 1, samples.count - 1) : max(base - 1, 0)
            onScrub(next == samples.count - 1 ? nil : next)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

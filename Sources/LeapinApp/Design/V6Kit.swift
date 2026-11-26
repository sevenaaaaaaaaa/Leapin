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

/// 「这台 Mac → 判据 → 出口」。第三站是可拖的，也是这一页的主角。
///
/// `hero` 用在「走哪」的焦点带上：出口是全屏最大的一个字，朱红点带光晕，
/// 换路生效时「跃」一下（品牌动效：旧点消失、新点出现、弦亮一闪）。
/// `compact` 用在 280pt 的菜单栏面板：节点更窄、字号更小，但手势不变。
struct LPRouteScrubber: View {
    enum Size { case hero, compact }

    struct Stop: Identifiable, Equatable {
        var id: String
        var label: String
        var detail: String
    }

    var stops: [Stop]
    var selectedID: String
    /// 判据站的名字：场景名，或「规则模式」/「尚未接管」。
    var judge: String
    /// 判据站下面的一行小字，例如「303 条规则」。
    var judgeDetail: String? = nil
    /// 出口下面的一行小字，例如「Proxy › 机场主订阅 · 42 ms」。
    var exitDetail: String? = nil
    /// 一个出口都没有时，出口站写什么。默认破折号；首屏未接管时它会变成一句人话，
    /// 于是「还没有出口」就是这一屏唯一的大字，不用再另起一个标题。
    var emptyExitTitle: String? = nil
    var enabled: Bool
    var size: Size = .compact
    var onInk = false
    var onCommit: (String) -> Void

    @State private var scrubbing = false
    @State private var index = 0
    @State private var startedIndex = 0
    /// 「跃」的两个状态：新出口的弹出（pop）与判据到出口之间的弦（chord）。
    @State private var pop = true
    @State private var chord: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currentIndex: Int {
        stops.firstIndex(where: { $0.id == selectedID }) ?? 0
    }

    private var selected: Stop? {
        stops.first(where: { $0.id == selectedID }) ?? stops.first
    }

    private var canScrub: Bool { enabled && stops.count > 1 }

    // MARK: metrics

    private var hero: Bool { size == .hero }
    private var ink: Color { onInk ? LP.onInk : LP.text }
    private var inkSoft: Color { onInk ? LP.onInkSecondary : LP.textSecondary }
    private var inkFaint: Color { onInk ? LP.onInkTertiary : LP.textTertiary }
    private var signal: Color { onInk ? LP.accentOnInk : LP.accent }
    private var trackColor: Color { onInk ? LP.inkLine : LP.lineStrong }
    /// The dot's box, halo included. Its centre is the height the track runs at.
    private var dotBox: CGFloat { hero ? 22 : 12 }
    private var dotSize: CGFloat { hero ? 12 : 8 }
    private var trackHeight: CGFloat { hero ? 1.5 : 1}
    private var stationGap: CGFloat { hero ? 10 : 6}
    /// The exit label's room. The band has space to spare; the 280pt panel has 248pt of it.
    private var exitMaxWidth: CGFloat { hero ? 400 : 112 }

    var body: some View {
        VStack(alignment: .leading, spacing: hero ? 14 : 6) {
            route
            if scrubbing, canScrub {
                candidateRail
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: scrubbing)
        .onChange(of: selectedID) { _, _ in leap() }
    }

    // MARK: the route

    private var route: some View {
        HStack(alignment: .top, spacing: 0) {
            station(hero ? "这台 Mac" : "你", detail: nil)
            track(hero ? 56 : 14, isChord: false)
            station(hero ? judge : "判据", detail: hero ? judgeDetail : nil)
            track(hero ? 76 : 18, isChord: true)
            exitStation
        }
    }

    private func station(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: stationGap) {
            Circle()
                .fill(ink.opacity(hero ? 0.55 : 0.9))
                .frame(width: hero ? 8 : 6, height: hero ? 8 : 6)
                .frame(width: dotBox, height: dotBox)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: hero ? 15 : 11, weight: .semibold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail {
                    Text(detail)
                        .font(.system(size: hero ? 13 : 11))
                        .foregroundStyle(inkSoft)
                        .lineLimit(1)
                }
            }
            .padding(.leading, hero ? -2 : 0)
        }
        // The band lets a station take its natural width; the panel cannot, so there a
        // station gets a ceiling and truncates rather than pushing the exit off the edge.
        .frame(maxWidth: hero ? nil : 64, alignment: .leading)
        .fixedSize(horizontal: hero, vertical: false)
    }

    /// One leg of the route. The second leg is the chord: it lights up when a
    /// different exit takes effect, which is the only time it is ever drawn.
    private func track(_ width: CGFloat, isChord: Bool) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(trackColor)
                .frame(height: trackHeight)
            if isChord {
                Rectangle()
                    .fill(signal)
                    .frame(height: trackHeight)
                    .opacity(chord)
            }
        }
        .frame(width: width)
        .padding(.top, (dotBox - trackHeight) / 2)
    }

    private var exitStation: some View {
        Button {
            guard canScrub else { LPHaptic.warning(); return }
            onCommit(stops[(currentIndex + 1) % stops.count].id)
        } label: {
            VStack(alignment: .leading, spacing: stationGap) {
                HStack(spacing: 5) {
                    ZStack {
                        if hero {
                            Circle()
                                .fill(signal.opacity(0.24))
                                .frame(width: dotBox, height: dotBox)
                        }
                        if hasExit {
                            Circle()
                                .fill(signal)
                                .frame(width: dotSize, height: dotSize)
                        } else {
                            // No exit yet: an open ring where the point will land.
                            Circle()
                                .strokeBorder(signal, lineWidth: hero ? 1.5 : 1.5)
                                .frame(width: dotSize, height: dotSize)
                        }
                    }
                    .scaleEffect(pop ? 1 : 0.4)
                    .frame(width: dotBox, height: dotBox)
                    if canScrub {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: hero ? 9 : 7, weight: .bold))
                            .foregroundStyle(inkFaint)
                    }
                }
                Text(scrubbing ? stops[safe: index]?.label ?? "—" : (selected?.label ?? emptyExitTitle ?? "—"))
                    .font(exitFont)
                    .tracking(hero ? -0.4 : 0)
                    .foregroundStyle(hasExit ? ink : inkSoft)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: exitMaxWidth, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                if hero, let detail = scrubbing ? stops[safe: index]?.detail : exitDetail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(inkSoft)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .highPriorityGesture(scrubGesture, including: canScrub ? .all : .subviews)
        .help(canScrub ? "上下拖切换出口" : "未接管：没有可切换的出口")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("出口")
        .accessibilityValue(selected?.label ?? "未设置")
        .accessibilityHint("上下轻扫切换出口")
        .accessibilityAdjustableAction { direction in
            guard canScrub else { return }
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

    private var hasExit: Bool {
        selected != nil && !stops.isEmpty
    }

    /// The exit is the one large thing on the screen. A short node name gets the
    /// full 28pt; airport names run long (flags, line types, numbering), and those
    /// drop a step rather than filling the band with one word.
    private var exitFont: Font {
        let label = scrubbing ? stops[safe: index]?.label ?? "" : selected?.label ?? ""
        let size: CGFloat = !hero ? 15 : (label.count <= 14 ? 28 : 20)
        return .system(size: size, weight: .semibold)
    }

    // MARK: the leap

    /// A different exit took effect. The point does not travel: it vanishes where it
    /// was and appears where it lands, and the chord behind it lights once and dims.
    private func leap() {
        guard hero, !reduceMotion else { return }
        pop = false
        chord = 1
        DispatchQueue.main.async {
            withAnimation(LPMotion.leap) { pop = true }
            withAnimation(LPMotion.chord) { chord = 0 }
        }
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard canScrub else { return }
                if !scrubbing {
                    scrubbing = true
                    startedIndex = currentIndex
                    index = currentIndex
                    LPHaptic.soft()
                }
                let step = Int((-value.translation.height / (hero ? 30 : 26)).rounded())
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
                        .fill(offset == index ? signal : inkFaint.opacity(0.55))
                        .frame(width: offset == index ? 12 : 5, height: 1)
                    Text(stop.label)
                        .font(.system(size: hero ? 12 : 11,
                                      weight: offset == index ? .semibold : .regular))
                        .foregroundStyle(offset == index ? ink : inkSoft)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !stop.detail.isEmpty {
                        Text(stop.detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(inkSoft)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, hero ? 4 : 3)
                .padding(.horizontal, 6)
                .background(offset == index ? Color.white.opacity(onInk ? 0.10 : 0) : Color.clear)
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
    /// 矮条形态（菜单栏面板）里放不下一句提示：留一条平线就够了。
    var showsIdleHint = true
    var onScrub: (Int?) -> Void

    private var ink: Color { onInk ? LP.onInk : LP.text }
    private var signal: Color { onInk ? LP.accentOnInk : LP.accent }

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
                                with: .color(signal.opacity(past ? 0.2 : alpha)))
                        }
                    }
                }

                if let frozenIndex, frozenIndex >= 0, frozenIndex < count {
                    let x = CGFloat(frozenIndex) * slot + slot / 2
                    var cursor = Path()
                    cursor.move(to: CGPoint(x: x, y: 0))
                    cursor.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(cursor, with: .color(signal), lineWidth: 1)
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
            if isIdle, showsIdleHint {
                Text(enabled ? "打开一个网页，波形从这里开始" : "引擎停止，没有波形")
                    .font(.system(size: 11))
                    .foregroundStyle(ink.opacity(0.50))
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

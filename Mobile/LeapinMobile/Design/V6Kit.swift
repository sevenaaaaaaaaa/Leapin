import SwiftUI
import UIKit

// MARK: - v6 · Live Instrument
//
// 四种块：Card（可编排）、Scrubber（可拖的路）、River（可回看的时间）、Draft（就地 agent）。
// 设计契约见 docs/DESIGN-v6.md。这一层只做交互与呈现，不持有网络状态。

enum LPHaptic {
    static func soft() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
    static func select() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

// MARK: - Deck（卡片编排）

/// 一张卡在网格里占几列。总列数由宽度决定（iPhone 2、iPad/Mac 4）。
enum LPCardSpan: String, Codable, CaseIterable, Identifiable {
    case s, m, l

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }

    /// 基准列数；实际值会被 `min(base, total)` 收住。
    var base: Int {
        switch self {
        case .s: return 1
        case .m: return 2
        case .l: return 4
        }
    }

    func columns(in total: Int) -> Int { max(1, min(base, total)) }

    var next: LPCardSpan {
        switch self {
        case .s: return .m
        case .m: return .l
        case .l: return .s
        }
    }
}

struct LPCardSpec: Codable, Identifiable, Equatable {
    var id: String
    var span: LPCardSpan = .m
    var hidden = false
}

/// 布局的唯一真相。写入 UserDefaults，重启后按同一顺序渲染。
/// 新增卡片（版本升级）会追加到末尾，不会打乱用户已有的顺序。
@Observable
final class LPDeckStore {
    private(set) var specs: [LPCardSpec]
    private let key: String

    init(defaults: [LPCardSpec], key: String = "lp.deck.v6") {
        self.key = key
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([LPCardSpec].self, from: data),
           !decoded.isEmpty {
            var merged = decoded
            for item in defaults where !merged.contains(where: { $0.id == item.id }) {
                merged.append(item)
            }
            specs = merged
        } else {
            specs = defaults
        }
    }

    func spec(_ id: String) -> LPCardSpec {
        specs.first(where: { $0.id == id }) ?? LPCardSpec(id: id)
    }

    func move(_ id: String, before target: String) {
        guard id != target,
              let from = specs.firstIndex(where: { $0.id == id }),
              let to = specs.firstIndex(where: { $0.id == target }) else { return }
        let item = specs.remove(at: from)
        let index = from < to ? to - 1 : to
        specs.insert(item, at: max(0, min(index, specs.count)))
        save()
        LPHaptic.soft()
    }

    func cycleSpan(_ id: String) {
        guard let index = specs.firstIndex(where: { $0.id == id }) else { return }
        specs[index].span = specs[index].span.next
        save()
        LPHaptic.select()
    }

    func toggleHidden(_ id: String) {
        guard let index = specs.firstIndex(where: { $0.id == id }) else { return }
        let visible = specs.filter { !$0.hidden }
        // 至少留一张：隐藏最后一张可见卡时拒绝，并给出触觉警告。
        if !specs[index].hidden, visible.count <= 1 {
            LPHaptic.warning()
            return
        }
        specs[index].hidden.toggle()
        save()
        LPHaptic.select()
    }

    func reset(_ defaults: [LPCardSpec]) {
        specs = defaults
        save()
        LPHaptic.soft()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(specs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// 一张可编排的卡。内容由调用方给；这里只负责表面、拖放与编辑控件。
struct LPCardTile<Content: View>: View {
    var id: String
    var store: LPDeckStore
    var editing: Bool
    var onInk = false
    @ViewBuilder var content: Content

    @State private var isTargeted = false

    private var span: LPCardSpan { store.spec(id).span }
    private var hidden: Bool { store.spec(id).hidden }

    var body: some View {
        content
            .padding(.horizontal, 14)
            // 编排态把内容整体下移，右上角的 S/M/L 与眼睛才有地方站，不压住「本机」这类角标。
            .padding(.top, editing ? 46 : 14)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .background(surface)
            .overlay(border)
            .overlay(alignment: .topTrailing) {
                if editing {
                    HStack(spacing: 4) {
                        Button { store.cycleSpan(id) } label: {
                            Text(span.label)
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .frame(width: 24, height: 24)
                        }
                        .accessibilityLabel("改变卡片大小，当前 \(span.label)")
                        Button { store.toggleHidden(id) } label: {
                            Image(systemName: hidden ? "eye.slash" : "eye")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 24, height: 24)
                        }
                        .accessibilityLabel(hidden ? "显示这张卡" : "隐藏这张卡")
                    }
                    .foregroundStyle(onInk ? LP.onInk : LP.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(onInk ? Color.black.opacity(0.35) : LP.canvas))
                    .padding(6)
                }
            }
            .opacity(hidden && editing ? 0.4 : 1)
            .scaleEffect(editing ? 1.0 : 1.0)
            .draggable(id) {
                Text("移动")
                    .font(LPFont.micro)
                    .padding(10)
                    .background(LP.panelRaised, in: RoundedRectangle(cornerRadius: 8))
            }
            .dropDestination(for: String.self) { items, _ in
                guard editing, let from = items.first else { return false }
                store.move(from, before: id)
                return true
            } isTargeted: { isTargeted = $0 }
            .overlay {
                if editing && isTargeted {
                    RoundedRectangle(cornerRadius: LP.radius, style: .continuous)
                        .strokeBorder(LP.accent, lineWidth: 2)
                }
            }
    }

    private var surface: some View {
        RoundedRectangle(cornerRadius: LP.radius, style: .continuous)
            .fill(onInk ? Color.white.opacity(0.04) : LP.panel)
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: LP.radius, style: .continuous)
            .strokeBorder(
                editing ? LP.accent.opacity(0.45) : (onInk ? Color.white.opacity(0.10) : LP.stroke),
                style: StrokeStyle(lineWidth: 1, dash: editing ? [4, 3] : [])
            )
    }
}

// MARK: - Scrubber（拖出口）

/// 「你 → 判据 → 出口」的第三条腿是可拖的。
///
/// 按住出口胶囊上下拖，候选在下方浮出并吸附；松手才提交，提交前不改变任何状态。
/// 未配对 / 只有一个候选时，轨道保留但给出阻尼，不假装能切。
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
    var onCommit: (String) -> Void
    var onInk = true

    @State private var scrubbing = false
    @State private var index = 0
    @State private var startedIndex = 0

    private var currentIndex: Int {
        stops.firstIndex(where: { $0.id == selectedID }) ?? 0
    }

    private var selected: Stop? {
        stops.first(where: { $0.id == selectedID }) ?? stops.first
    }

    private var ink: Color { onInk ? LP.onInk : LP.text }
    private var inkSoft: Color { onInk ? LP.onInkSecondary : LP.textTertiary }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                endpoint(title: "你", detail: "这台手机", filled: false)
                connector
                endpoint(title: "判据", detail: judge, filled: false)
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

    private func endpoint(title: String, detail: String, filled: Bool) -> some View {
        VStack(spacing: 5) {
            Circle()
                .fill(filled ? LP.accent : ink.opacity(0.9))
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ink)
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(inkSoft)
                .lineLimit(1)
        }
        .frame(width: 74)
    }

    private var connector: some View {
        Rectangle()
            .fill(inkSoft.opacity(0.45))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private var exitControl: some View {
        Button {
            // 单击仍然可用：给不想拖的人一条路。
            guard enabled, stops.count > 1 else { LPHaptic.warning(); return }
            let next = stops[(currentIndex + 1) % stops.count]
            onCommit(next.id)
        } label: {
            VStack(spacing: 5) {
                Circle()
                    .fill(LP.accent)
                    .frame(width: 9, height: 9)
                    .overlay(
                        Circle().strokeBorder(LP.accent.opacity(0.28), lineWidth: 6)
                    )
                Text(scrubbing ? stops[safe: index]?.label ?? "—" : selected?.label ?? "—")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                HStack(spacing: 3) {
                    Image(systemName: "chevron.up")
                    Image(systemName: "chevron.down")
                }
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(enabled && stops.count > 1 ? inkSoft : inkSoft.opacity(0.4))
            }
            .frame(width: 88)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .highPriorityGesture(scrubGesture, including: enabled && stops.count > 1 ? .all : .subviews)
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
                // 向上拖 → 下一个候选；每 34pt 一档。
                let step = Int((-value.translation.height / 34).rounded())
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
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(offset == index ? LP.accent : inkSoft.opacity(0.35))
                        .frame(width: offset == index ? 14 : 6, height: 1)
                    Text(stop.label)
                        .font(.system(size: 12, weight: offset == index ? .semibold : .regular))
                        .foregroundStyle(offset == index ? ink : inkSoft)
                    Spacer(minLength: 4)
                    Text(stop.detail)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(inkSoft)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(offset == index ? ink.opacity(onInk ? 0.08 : 0.05) : .clear)
            }
            if !enabled {
                Text("未配对：出口由这台手机自己决定")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(inkSoft)
                    .padding(.top, 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - River（时间河）

struct LPRiverSample: Equatable {
    var down: Double
    var up: Double
    static let zero = LPRiverSample(down: 0, up: 0)
}

/// 60 秒的速率河：上行向上、下行向下，中线是零。
/// 拖动即冻结并回看；读数交给调用方（它知道那一刻的连接数与出口）。
struct LPRiver: View {
    var samples: [LPRiverSample]
    var frozenIndex: Int?
    var enabled: Bool
    var onInk = true
    var height: CGFloat = 52
    var onScrub: (Int?) -> Void

    private var ink: Color { onInk ? LP.onInk : LP.text }

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
                // 没有采样时就只留一条中线：虚线不是「波形」，是没画完的柱子。
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
                    let liveOpacity = enabled ? 0.9 : 0.25
                    let alpha = past ? 0.18 : liveOpacity

                    let downHeight = max(1.5, CGFloat(sample.down) * (mid - 3))
                    let downRect = CGRect(x: x, y: mid + 1, width: barWidth, height: downHeight)
                    context.fill(Path(roundedRect: downRect, cornerRadius: barWidth / 2),
                                 with: .color(ink.opacity(alpha)))

                    let upHeight = max(1.0, CGFloat(sample.up) * (mid - 3))
                    if upHeight > 1.4 {
                        let upRect = CGRect(x: x, y: mid - 1 - upHeight, width: barWidth, height: upHeight)
                        context.fill(Path(roundedRect: upRect, cornerRadius: barWidth / 2),
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
                        let index = Int(ratio * CGFloat(samples.count))
                        onScrub(index)
                        LPHaptic.select()
                    }
                    .onEnded { _ in
                        // 松手先冻 3 秒：读数要来得及被看见，再回到实时。
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

// MARK: - Draft（就地 agent）

/// 底部草稿行：不跳页、不开聊天窗，只把一句话变成一张可应用的变更卡。
struct LPAgentDraftBar: View {
    @Binding var text: String
    var placeholder: String
    var busy: Bool
    var suggestions: [String]
    var onSubmit: (String) -> Void

    @State private var expanded = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("/")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(LP.accent)
                        TextField(placeholder, text: $text, axis: .vertical)
                            .font(.system(size: 14))
                            .lineLimit(1...3)
                            .focused($focused)
                            .accessibilityIdentifier("lp.draftField")
                            .submitLabel(.send)
                            .onSubmit(send)
                        Button(action: send) {
                            Image(systemName: busy ? "ellipsis" : "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(LP.accentFill, in: Circle())
                        }
                        .accessibilityLabel("发送")
                        .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                        .opacity(busy || text.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(suggestions, id: \.self) { item in
                                Button {
                                    text = item
                                    send()
                                } label: {
                                    Text(item)
                                        .font(.system(size: 11))
                                        .foregroundStyle(LP.textSecondary)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5)
                                        .background(Capsule().fill(LP.backgroundElevated))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(12)
                .background(LP.panelRaised)
                .overlay(alignment: .top) { Rectangle().fill(LP.stroke).frame(height: 0.5) }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Button {
                    expanded = true
                    focused = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LP.accent)
                        Text(placeholder)
                            .font(.system(size: 13))
                            .foregroundStyle(LP.textTertiary)
                        Spacer(minLength: 4)
                        Text("/")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(LP.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(LP.backgroundElevated))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        Capsule(style: .continuous)
                            .fill(LP.panelRaised)
                            .overlay(Capsule().strokeBorder(LP.stroke, lineWidth: 1))
                    )
                    .padding(.horizontal, LP.gutter)
                    .padding(.bottom, 6)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("lp.draftOpen")
                .accessibilityLabel("打开草稿")
            }
        }
        .animation(.easeOut(duration: 0.2), value: expanded)
    }

    private func send() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onSubmit(value)
        text = ""
        focused = false
        expanded = false
    }
}

extension LP {
    /// 草稿行与 chips 的浅一档底色；v5 只有 canvas/panel/ink 三层，这里补一层。
    static let backgroundElevated = adaptive(light: 0xF0EDE6, dark: 0x232326)
}


// MARK: - RiverFeed（一页采样，多页读）

/// 60 秒速率的唯一采样点：状态页与连接页读同一份，数字不会各说各的。
/// 1 Hz，只在本机引擎运行时才有意义；`start()` 幂等。
@MainActor
@Observable
final class LPRiverFeed {
    static let shared = LPRiverFeed()

    private(set) var samples: [LPRiverSample] = Array(repeating: .zero, count: 60)
    private var lastIn = 0
    private var lastOut = 0
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() {
        let engine = LocalProxyEngine.shared
        let inBytes = engine.totalBytesIn
        let outBytes = engine.totalBytesOut
        let dIn = max(0, inBytes - lastIn)
        let dOut = max(0, outBytes - lastOut)
        lastIn = inBytes
        lastOut = outBytes
        samples.removeFirst()
        samples.append(LPRiverSample(down: normalize(Double(dIn)), up: normalize(Double(dOut))))
    }

    /// 对数归一：1 KB/s 看得见，3 MB/s 封顶。
    private func normalize(_ bytesPerSecond: Double) -> Double {
        guard bytesPerSecond > 0 else { return 0 }
        return min(1, log1p(bytesPerSecond) / log1p(3_000_000))
    }
}

import SwiftUI
import LeapinRuntime

// MARK: - 舞台：一张活的图
//
// 窗口不再是「一页页」，而是一个舞台：顶部整片是墨色的空间，你的路由
// （这台 Mac → 判据 → 出口）横贯整个宽度，真实流量变成沿路飞行的包。
// 四个动词是同一张图上的四个机位——换页是移动视线，不是换一张纸。

/// 机位：同一张图上的四个视线落点。工具与收纳页镜头拉远，只留一条安静的路。
enum LPStation: Equatable {
    case route, gate, bend, trace, ambient

    /// 走哪把路完整摊开（出口是主角）；另外三个动词把天空收窄，把地方让给纸上的内容；
    /// 工具页只留一条细路。高度随换页带弹簧过渡，于是「镜头」真的在动。
    var skyHeight: CGFloat {
        switch self {
        case .route: return 154
        case .gate, .bend, .trace: return 98
        case .ambient: return 62
        }
    }

    /// 星尘层的视差：镜头推向判据时星尘往右让，推向出口时往左让。
    var dustShift: CGFloat {
        switch self {
        case .gate: return 22
        case .trace: return -22
        default: return 0
        }
    }

    @MainActor static func of(_ section: AppModel.Section?) -> LPStation {
        switch section {
        case .dashboard, .profiles, .none: return .route
        case .rules: return .gate
        case .rewrite, .adblock: return .bend
        case .why, .capture, .activity, .diagnostics: return .trace
        default: return .ambient
        }
    }
}

/// 一个沿路飞行的包。它的种类来自真实的决策：走出口、直连、或被拦在判据门上。
private struct LPPacket: Identifiable {
    enum Kind { case proxy, direct, blocked }
    let id = UUID()
    let kind: Kind
    let start: Date
    /// 从「你」飞到终点用几秒。
    let duration: Double
}

/// 舞台的几何：三个站在一条基线上的节点，外加直连的分支星。
private struct LPStageGeometry {
    let size: CGSize
    let you: CGPoint
    let gate: CGPoint
    let exit: CGPoint
    let direct: CGPoint
    let baseline: CGFloat

    init(size: CGSize, station: LPStation) {
        self.size = size
        let width = max(size.width, 560)
        baseline = station == .route ? size.height * 0.40 : size.height * 0.46
        you = CGPoint(x: 30, y: baseline)
        // 判据门留在左中之间，并给右边的出口与它的大字留够位置。
        let gateX = min(max(236, width * 0.37), width - 430)
        gate = CGPoint(x: max(gateX, 150), y: baseline)
        let exitX = width - (station == .route ? 306 : 176)
        exit = CGPoint(x: max(exitX, gate.x + 110), y: baseline)
        direct = CGPoint(x: gate.x + (exit.x - gate.x) * 0.52, y: baseline + 27)
    }

    /// 你 → 判据：直线。
    func approach(_ t: Double) -> CGPoint {
        CGPoint(x: you.x + (gate.x - you.x) * t, y: you.y + (gate.y - you.y) * t)
    }

    /// 判据 → 出口：向上微拱的三次曲线，路才有「在空间里」的弧度。
    func toExit(_ t: Double) -> CGPoint {
        cubic(t, from: gate, to: exit, lift: -14)
    }

    /// 判据 → 直连：向下分流。
    func toDirect(_ t: Double) -> CGPoint {
        cubic(t, from: gate, to: direct, lift: 6)
    }

    private func cubic(_ t: Double, from: CGPoint, to: CGPoint, lift: CGFloat) -> CGPoint {
        let dx = to.x - from.x
        let c1 = CGPoint(x: from.x + dx * 0.30, y: from.y + lift)
        let c2 = CGPoint(x: from.x + dx * 0.70, y: from.y + lift)
        let mt = 1 - t
        let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
        return CGPoint(x: a * from.x + b * c1.x + c * c2.x + d * to.x,
                       y: a * from.y + b * c1.y + c * c2.y + d * to.y)
    }

    func exitPath() -> Path {
        var path = Path()
        path.move(to: gate)
        path.addCurve(to: exit,
                      control1: CGPoint(x: gate.x + (exit.x - gate.x) * 0.30, y: gate.y - 14),
                      control2: CGPoint(x: gate.x + (exit.x - gate.x) * 0.70, y: gate.y - 14))
        return path
    }

    func directPath() -> Path {
        var path = Path()
        path.move(to: gate)
        path.addCurve(to: direct,
                      control1: CGPoint(x: gate.x + (direct.x - gate.x) * 0.40, y: gate.y + 6),
                      control2: CGPoint(x: gate.x + (direct.x - gate.x) * 0.60, y: direct.y - 6))
        return path
    }
}

/// 天空：路、包、出口星，以及走哪机位下的事实与主操作。
struct LPRouteSky: View {
    let station: LPStation
    @ObservedObject var scenes: NetworkScenes
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var engine = LeapinEngine.shared
    /// 常驻事实的唯一数据源：与菜单栏面板、实时浮窗是同一个对象。
    @ObservedObject private var resident = ResidentStatusStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var packets: [LPPacket] = []
    @State private var budget = 0.0
    @State private var lastBlocked = 0
    /// 可拖的出口：运行中且候选 > 1 时才允许。
    @State private var quickStops: [LPRouteScrubber.Stop] = []
    @State private var quickGroup: String?
    @State private var scrubbing = false
    @State private var scrubIndex = 0
    @State private var scrubStartIndex = 0

    private var status: ResidentStatus { resident.status }
    private var running: Bool { engine.state == .running }
    private var connected: Bool { running && engine.systemProxyActive }
    private var canScrub: Bool { running && quickStops.count > 1 }

    private var activeScene: NetworkScene? {
        guard let active = scenes.active, scenes.profileID(for: active) == engine.profile.id else { return nil }
        return active
    }

    var body: some View {
        GeometryReader { geo in
            let geometry = LPStageGeometry(size: geo.size, station: station)
            ZStack(alignment: .topLeading) {
                starDust(width: geo.size.width, height: geo.size.height)
                    .offset(x: reduceMotion ? 0 : station.dustShift)
                    .lpAnimation(LPMotion.emphasized, value: station)
                routeCanvas(geometry)
                if station == .route {
                    routeStationLabels(geometry)
                    factsAndActions(width: geo.size.width, height: geo.size.height)
                } else if station != .ambient {
                    compactLabels(geometry)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .task(id: engine.state) { await drive() }
        .onChange(of: engine.profile.id) { _, _ in Task { await refreshExit() } }
    }

    // MARK: 喂数据（与菜单栏面板同一模式）

    /// 舞台常驻，所以由它驱动共享 store：先取一次快照（出口只在 `MenuBarSnapshot` 里），
    /// 再进循环喂帧、按真实速率放飞包。视图离开舞台时循环自动取消。
    private func drive() async {
        await refreshExit()
        lastBlocked = status.blocked
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
            resident.update(from: engine)
            spawn()
        }
    }

    private func refreshExit() async {
        let latest = await engine.menuBarSnapshot()
        resident.update(from: engine, snapshot: latest)
        let groups = latest.nodeMenuGroups
        guard let group = groups.first(where: { $0.name == latest.currentGroup }) ?? groups.first else {
            quickStops = []
            quickGroup = nil
            return
        }
        quickGroup = group.name
        quickStops = group.members.map { node in
            LPRouteScrubber.Stop(id: node.name, label: node.name,
                                 detail: node.failed ? "失败" : (node.latencyMs.map { "\($0) ms" } ?? ""))
        }
    }

    /// 放飞包：速率越高每秒越多；拦截数每涨一个就放一个撞门的包；
    /// 走出口与直连的比例取自最近的真实决策。没在跑或开了「减弱动态效果」就一个都不放。
    private func spawn() {
        packets.removeAll { Date().timeIntervalSince($0.start) > $0.duration + 0.4 }
        guard running, !reduceMotion else {
            if !packets.isEmpty { packets.removeAll() }
            return
        }
        let rate = status.rates.down + status.rates.up
        budget += min(16, log2(1 + rate / 1200)) * 0.2

        let delta = max(0, status.blocked - lastBlocked)
        lastBlocked = status.blocked
        for _ in 0..<min(delta, 6) {
            packets.append(LPPacket(kind: .blocked, start: Date().addingTimeInterval(.random(in: 0...0.2)), duration: 1.0))
        }

        let recent = status.recent
        let directCount = recent.filter { $0.kind == .direct }.count
        let proxyCount = recent.filter { $0.kind == .proxy }.count
        let directShare = (directCount + proxyCount) > 0
            ? Double(directCount) / Double(directCount + proxyCount) : 0.32
        while budget >= 1 {
            budget -= 1
            let kind: LPPacket.Kind = Double.random(in: 0...1) < directShare ? .direct : .proxy
            packets.append(LPPacket(kind: kind,
                                    start: Date().addingTimeInterval(.random(in: 0...0.15)),
                                    duration: .random(in: 1.25...1.8)))
        }
        if packets.count > 90 { packets.removeFirst(packets.count - 90) }
    }

    // MARK: 星尘

    /// 很淡的一层静态参考点，带一点呼吸：空间的深度靠它，不靠装饰。
    private func starDust(width: CGFloat, height: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { timeline in
            Canvas { context, _ in
                let now = timeline.date.timeIntervalSinceReferenceDate
                for index in 0..<70 {
                    let seed = Double(index)
                    let x = (seed * 127.1).truncatingRemainder(dividingBy: max(width, 1))
                    let y = (seed * 311.7).truncatingRemainder(dividingBy: max(height, 1))
                    let twinkle = 0.5 + 0.5 * sin(now * 0.9 + seed * 1.7)
                    let radius = index % 9 == 0 ? 1.4 : 0.9
                    let alpha = 0.05 + 0.09 * twinkle
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                        with: .color(.white.opacity(alpha)))
                }
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: 路与包

    private func routeCanvas(_ geometry: LPStageGeometry) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion || !running)) { timeline in
            Canvas { context, _ in
                let now = timeline.date
                drawRoute(context, geometry: geometry, now: now)
                drawPackets(context, geometry: geometry, now: now)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var dim: Double {
        switch station {
        case .route: return 1
        case .ambient: return 0.55
        default: return 0.85
        }
    }

    private func drawRoute(_ context: GraphicsContext, geometry: LPStageGeometry, now: Date) {
        let ink = Color.white.opacity(0.22 * dim)
        let signal = LP.accentOnInk

        // 你 → 判据
        var approach = Path()
        approach.move(to: geometry.you)
        approach.addLine(to: geometry.gate)
        if running {
            context.stroke(approach, with: .color(station == .gate ? signal.opacity(0.85) : ink),
                           style: StrokeStyle(lineWidth: station == .gate ? 2 : 1.5, lineCap: .round))
        } else {
            context.stroke(approach, with: .color(ink),
                           style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 6]))
        }

        // 判据 → 出口 / 直连
        let exitHighlight = station == .bend || station == .trace
        if running {
            context.stroke(geometry.exitPath(),
                           with: .color(exitHighlight ? signal.opacity(0.9) : ink),
                           style: StrokeStyle(lineWidth: exitHighlight ? 2 : 1.5, lineCap: .round))
            context.stroke(geometry.directPath(), with: .color(LP.mint.opacity(0.55 * dim)),
                           style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        } else {
            context.stroke(geometry.exitPath(), with: .color(.white.opacity(0.16)),
                           style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 6]))
        }

        // 你
        context.fill(Path(ellipseIn: CGRect(center: geometry.you, radius: 4.5)), with: .color(.white.opacity(0.85)))

        // 判据门：两根短竖线，像一道闸。
        let gateGlow = station == .gate
        if gateGlow {
            context.fill(
                Path(ellipseIn: CGRect(center: geometry.gate, radius: 22)),
                with: .radialGradient(Gradient(colors: [signal.opacity(0.35), .clear]),
                                      center: geometry.gate, startRadius: 0, endRadius: 22))
        }
        for offset in [-5.0, 5.0] {
            let rect = CGRect(x: geometry.gate.x + offset - 1, y: geometry.gate.y - 8, width: 2, height: 16)
            context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(gateGlow ? signal : .white.opacity(0.75)))
        }

        // 直连星
        let directRadius = station == .route ? 3.2 : 2.4
        context.fill(Path(ellipseIn: CGRect(center: geometry.direct, radius: directRadius)), with: .color(LP.mint))

        // 出口星：光晕 + 核心；运行时有轻微的呼吸。
        let pulse = reduceMotion || !running ? 1 : 1 + 0.10 * sin(now.timeIntervalSinceReferenceDate * 2.4)
        let big = station == .route
        let glowRadius = (big ? 30 : 18) * pulse
        let starDim = station == .gate ? 0.55 : 1
        if running {
            context.fill(
                Path(ellipseIn: CGRect(center: geometry.exit, radius: glowRadius)),
                with: .radialGradient(
                    Gradient(colors: [signal.opacity(0.50 * starDim * dim), .clear]),
                    center: geometry.exit, startRadius: 0, endRadius: glowRadius))
            context.fill(Path(ellipseIn: CGRect(center: geometry.exit, radius: big ? 6 : 4.5)), with: .color(signal))
            context.stroke(
                Path(ellipseIn: CGRect(center: geometry.exit, radius: (big ? 12 : 9) * pulse)),
                with: .color(signal.opacity(0.55 * starDim)), lineWidth: 1)
        } else {
            context.stroke(Path(ellipseIn: CGRect(center: geometry.exit, radius: big ? 6 : 4.5)),
                           with: .color(signal.opacity(0.9)), lineWidth: 1.5)
        }
    }

    private func drawPackets(_ context: GraphicsContext, geometry: LPStageGeometry, now: Date) {
        for packet in packets {
            let age = now.timeIntervalSince(packet.start)
            if age < 0 { continue }
            let progress = age / packet.duration
            if progress > 1 { continue }
            let color: Color
            switch packet.kind {
            case .proxy: color = LP.accentOnInk
            case .direct: color = LP.mint
            case .blocked: color = LP.danger.opacity(0.95)
            }
            if packet.kind == .blocked, progress > 0.62 {
                // 撞在判据门上：一枚扩散后消散的红环。
                let burst = (progress - 0.62) / 0.38
                let radius = 4 + burst * 15
                context.stroke(
                    Path(ellipseIn: CGRect(center: geometry.gate, radius: radius)),
                    with: .color(color.opacity(1 - burst)), lineWidth: 1.6)
                continue
            }
            let point = position(packet, progress: progress, geometry: geometry)
            for step in 1...4 {
                let tail = progress - Double(step) * 0.022
                if tail > 0 {
                    let tailPoint = position(packet, progress: tail, geometry: geometry)
                    context.fill(
                        Path(ellipseIn: CGRect(center: tailPoint, radius: 3.0 - Double(step) * 0.5)),
                        with: .color(color.opacity(0.20 - Double(step) * 0.035)))
                }
            }
            context.fill(
                Path(ellipseIn: CGRect(center: point, radius: packet.kind == .blocked ? 3.4 : 3.0)),
                with: .color(color))
        }
    }

    private func position(_ packet: LPPacket, progress: Double, geometry: LPStageGeometry) -> CGPoint {
        let approachEnd = packet.kind == .blocked ? 0.62 : 0.40
        if progress <= approachEnd {
            return geometry.approach(progress / approachEnd)
        }
        let rest = (progress - approachEnd) / (1 - approachEnd)
        return packet.kind == .direct ? geometry.toDirect(rest) : geometry.toExit(rest)
    }

    // MARK: 文字层

    /// 走哪机位：出口是全屏唯一的大字；左边是判据，右边是事实与主操作。
    @ViewBuilder private func routeStationLabels(_ geometry: LPStageGeometry) -> some View {
        Text("这台 Mac")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(LP.onInkTertiary)
            .fixedSize()
            .position(x: geometry.you.x + 16, y: geometry.you.y + 20)

        VStack(alignment: .leading, spacing: 2) {
            Text(judgeTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LP.onInk)
            Text("\(engine.ruleCount) 条规则")
                .font(.system(size: 11))
                .foregroundStyle(LP.onInkTertiary)
        }
        .fixedSize()
        .position(x: geometry.gate.x + 8, y: geometry.gate.y - 26)

        Text("直连")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(LP.mint.opacity(0.85))
            .fixedSize()
            .position(x: geometry.direct.x + 20, y: geometry.direct.y)

        exitControl(geometry)
    }

    /// 另外三个机位只留小字：知道路在哪、镜头落在哪一站就够了。
    @ViewBuilder private func compactLabels(_ geometry: LPStageGeometry) -> some View {
        let focus = station == .gate ? "判据" : station == .bend ? "改路" : "出口"
        Text(focus)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(LP.accentOnInk)
            .fixedSize()
            .position(x: station == .gate ? geometry.gate.x : geometry.exit.x + 14,
                      y: (station == .gate ? geometry.gate.y : geometry.exit.y) - 18)
    }

    private var judgeTitle: String {
        if running { return activeScene?.title ?? "规则模式" }
        if case .failed = engine.state { return "没能启动" }
        return "尚未接管"
    }

    /// 出口站：大字 + 拖动换路。按住上下拖，候选在下方浮出，松手才提交。
    @ViewBuilder private func exitControl(_ geometry: LPStageGeometry) -> some View {
        let selectedStop = quickStops.first { $0.id == status.exit } ?? quickStops.first
        let shown = scrubbing ? (quickStops[safe: scrubIndex]?.label ?? "—")
                               : (selectedStop?.label ?? (running ? "没有可切换的节点" : "还没有出口"))
        let detail = scrubbing
            ? (quickStops[safe: scrubIndex]?.detail ?? "")
            : exitDetail(selectedStop: selectedStop)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(shown)
                    .font(.system(size: shown.count <= 14 ? 28 : 20, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(running && selectedStop != nil ? LP.onInk : LP.onInkSecondary)
                    .lineLimit(1)
                if canScrub {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LP.onInkTertiary)
                }
            }
            Text(detail ?? "")
                .font(.system(size: 12))
                .foregroundStyle(LP.onInkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 244, alignment: .leading)
        .contentShape(Rectangle())
        .position(x: geometry.exit.x + 12 + 122, y: geometry.exit.y - 4)
        .onTapGesture {
            guard canScrub else { return }
            commit(stops[(currentIndex + 1) % stops.count].id)
        }
        .gesture(scrubGesture, including: canScrub ? .all : .subviews)
        .help(canScrub ? "上下拖切换出口" : "未接管：没有可切换的出口")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("出口")
        .accessibilityValue(shown)
        .accessibilityAdjustableAction { direction in
            guard canScrub else { return }
            switch direction {
            case .increment: commit(stops[(currentIndex + 1) % stops.count].id)
            case .decrement: commit(stops[(currentIndex - 1 + stops.count) % stops.count].id)
            @unknown default: break
            }
        }
        .overlay(alignment: .top) {
            if scrubbing, canScrub {
                candidateRail
                    .offset(y: 50)
                    .frame(width: 244, alignment: .leading)
            }
        }
    }

    private var stops: [LPRouteScrubber.Stop] { quickStops }
    private var currentIndex: Int { stops.firstIndex { $0.id == status.exit } ?? 0 }

    private func exitDetail(selectedStop: LPRouteScrubber.Stop?) -> String? {
        if case .failed = engine.state {
            return status.issues.first?.text ?? engine.lastError ?? "启动失败。"
        }
        guard running else { return "连上之后，每个请求走哪条路都从这里经过。" }
        var parts: [String] = []
        if let group = status.exitGroup, !group.isEmpty { parts.append(group) }
        if !status.profileName.isEmpty { parts.append(status.profileName) }
        if let latency = selectedStop?.detail, !latency.isEmpty { parts.append(latency) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var candidateRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stops.enumerated()), id: \.element.id) { offset, stop in
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(offset == scrubIndex ? LP.accentOnInk : Color.white.opacity(0.35))
                        .frame(width: offset == scrubIndex ? 12 : 5, height: 1)
                    Text(stop.label)
                        .font(.system(size: 12, weight: offset == scrubIndex ? .semibold : .regular))
                        .foregroundStyle(offset == scrubIndex ? LP.onInk : LP.onInkSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if !stop.detail.isEmpty {
                        Text(stop.detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(LP.onInkTertiary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(offset == scrubIndex ? Color.white.opacity(0.10) : Color.clear)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard canScrub else { return }
                if !scrubbing {
                    scrubbing = true
                    scrubStartIndex = currentIndex
                    scrubIndex = currentIndex
                }
                let step = Int((-value.translation.height / 24).rounded())
                scrubIndex = min(max(scrubStartIndex + step, 0), stops.count - 1)
            }
            .onEnded { _ in
                guard scrubbing else { return }
                scrubbing = false
                guard let chosen = stops[safe: scrubIndex], chosen.id != status.exit else { return }
                commit(chosen.id)
            }
    }

    private func commit(_ member: String) {
        guard let group = quickGroup else { return }
        Task {
            try? await engine.menuBarSelect(group: group, member: member)
            await refreshExit()
        }
    }

    // MARK: 事实与主操作

    @ViewBuilder private func factsAndActions(width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let message = app.networkMessage {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(app.networkFailed ? Color(red: 1, green: 0.70, blue: 0.64) : LP.onInkSecondary)
                    .lineLimit(1)
            }
            HStack(spacing: 10) {
                if running {
                    HStack(spacing: 12) {
                        rate("arrow.down", status.rates.downText)
                        rate("arrow.up", status.rates.upText)
                    }
                    Text("拦截 \(status.blocked) · \(status.connections) 个连接")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(LP.onInkTertiary)
                }
                Image(systemName: status.coverage.isCoveringTraffic ? "checkmark.shield" : "exclamationmark.shield")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(status.coverage.isCoveringTraffic ? LP.mint : LP.accentOnInk)
                Text(status.coverage.declaration)
                    .font(.system(size: 11))
                    .foregroundStyle(LP.onInkTertiary)
                    .lineLimit(1)
                Spacer(minLength: 10)
                if !connected {
                    Button("导入配置") { app.beginImport() }
                        .buttonStyle(LPOnInkButtonStyle())
                }
                if connected {
                    Button("暂停接管") { Task { await app.pauseNetwork() } }
                        .buttonStyle(LPOnInkButtonStyle())
                } else {
                    Button(app.networkBusy ? "准备中…" : (running ? "接管网络" : "连接网络")) { app.connectNetwork() }
                        .buttonStyle(LPPrimaryButtonStyle())
                        .disabled(app.networkBusy || engine.configurationBusy || engine.state == .starting)
                }
            }
        }
        .padding(.horizontal, 22)
        .frame(width: width)
        .position(x: width / 2, y: height - 30)
    }

    private func rate(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(LP.accentOnInk)
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(LP.onInk)
                .monospacedDigit()
        }
    }
}

/// 舞台的壳：页头（坐在墨色空间上）+ 天空。
struct LPStage: View {
    var compact: Bool = false
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let station = LPStation.of(app.section)
        VStack(spacing: 0) {
            PageHeaderBar(compact: compact)
            LPRouteSky(station: station, scenes: app.scenes)
                .frame(height: station.skyHeight)
        }
        .frame(height: LPShell.headerHeight + station.skyHeight)
        .lpAnimation(LPMotion.emphasized, value: station)
    }
}

extension View {
    /// 一张浮在空间里的纸：页面的内容坐在它上面，边缘留着空间透出来。
    func lpPaperSheet() -> some View {
        self.background(LP.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension CGRect {
    /// 以圆心和半径构造外接方框：舞台上的节点、包、光晕都是圆。
    init(center: CGPoint, radius: CGFloat) {
        self.init(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}

import SwiftUI
import AppKit
import LeapinCore
import LeapinIntegrations
import LeapinPolicy
import LeapinRuntime

// MARK: - 网络星图：首页就是你的网络空间
//
// 一张满屏的图。中心是这台 Mac，外圈是按地区归簇的出口，当前出口是一颗发光的朱红星；
// 同一圈轨道的左右两端是公司内网和工具，弧以下是近处——回家、局域网 · NAS、常用网站、直连。
// 真实流量沿路飞：走出口的升向星，直连的落向地面，被拦的撞在判据环上炸红环。
// 四个动词是图上的四个地方：判据环＝怎么判，主路上的弯＝改成什么，问路框＝为什么，整张图＝走哪。
// 点一个地方就是走过去：镜头从那里推近，进入对应的页面。

/// 图上的一个「地方」：点它就是走过去。方位角 90° 在正上方，距离以世界弧半径为单位。
enum LPPlace: String, Identifiable, CaseIterable {
    case company, home, lan, bookmarks, tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .company: return "公司内网"
        case .home: return "回家"
        case .lan: return "局域网 · NAS"
        case .bookmarks: return "常用网站"
        case .tools: return "工具"
        }
    }

    var icon: String {
        switch self {
        case .company: return "building.2"
        case .home: return "house"
        case .lan: return "externaldrive.connected.to.line.below"
        case .bookmarks: return "bookmark"
        case .tools: return "wrench.and.screwdriver"
        }
    }

    /// 公司与工具坐在世界弧的同一圈轨道上，一边一个；回家、局域网、书签在轨道里面，离这台 Mac 更近。
    var angle: Double {
        switch self {
        case .company: return 168
        case .home: return 212
        case .lan: return 242
        case .bookmarks: return 298
        case .tools: return 0
        }
    }

    var distance: CGFloat {
        switch self {
        case .company, .tools: return 0.98
        case .home: return 0.80
        case .lan, .bookmarks: return 0.58
        }
    }
}

/// 星图的几何：中心、世界弧、判据环。所有落点都从中心量出去。
struct LPMapGeometry {
    let size: CGSize
    let center: CGPoint
    /// 世界弧的半径。
    let radius: CGFloat
    /// 判据环的半径。
    let shell: CGFloat
    /// 场景导轨（左上角）占多宽。
    let railWidth: CGFloat
    /// 「其他」那一簇离中心多远。够高就升到弧的正上方；高度不够时贴着弧上沿。
    let otherRing: CGFloat

    /// - Parameter hasOther: 图上有没有「其他」地区的出口。它悬在弧外更高处，决定弧能画多大。
    init(size: CGSize, hasOther: Bool) {
        self.size = size
        center = CGPoint(x: size.width / 2, y: size.height * 0.58)
        // 上方要放得下出口的大字，下方要放得下直连、几个地方和问路框；取三者里最紧的那个。
        let headroom = (center.y - 100) / (hasOther ? LPRegion.other.ring : 1)
        let foothold = (size.height - center.y - 106) / 0.58
        radius = max(90, min(size.width * 0.33, foothold, headroom))
        shell = max(46, radius * 0.27)
        railWidth = min(388, max(240, size.width - 242))
        otherRing = min(LPRegion.other.ring, (center.y - 58) / max(radius, 1))
    }

    func point(_ angle: Double, _ factor: CGFloat = 1) -> CGPoint {
        LPWorldLayout.point(center: center, radius: radius, angle: angle, factor: factor)
    }

    /// 「其他」那一簇的中心。够高时就在弧的正上方，离场景导轨远一点；
    /// 和出口的大字挤在同一条带上时，往右让到大字外头。
    var otherCenterX: CGFloat {
        let spread: CGFloat = 84
        let clearOfRail = 16 + railWidth + 24 + spread
        guard otherRing < LPRegion.other.ring else { return max(center.x, clearOfRail) }
        return max(center.x + 118 + 12 + spread, clearOfRail)
    }

    func point(_ node: LPWorldNode) -> CGPoint {
        let ring = node.region == .other ? otherRing : node.radius
        let point = self.point(node.angle, ring)
        guard node.region == .other else { return point }
        return CGPoint(x: point.x - center.x + otherCenterX, y: point.y)
    }

    func point(_ place: LPPlace) -> CGPoint { point(place.angle, place.distance) }

    /// 上闸：去世界的路从这里出判据环。下闸：落向直连的路从这里出。
    var gateTop: CGPoint { point(90, shell / radius) }
    var gateBottom: CGPoint { point(270, shell / radius) }
    /// 直连星：判据环的正下方，离这台 Mac 最近的一站。
    var direct: CGPoint { point(270, 0.52) }
}

private enum LPMapMath {
    static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    static func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        let mt = 1 - t
        return CGPoint(x: mt * mt * a.x + 2 * mt * t * c.x + t * t * b.x,
                       y: mt * mt * a.y + 2 * mt * t * c.y + t * t * b.y)
    }

    /// 二次曲线的控制点：弦的中点沿垂直方向挪一点。挪向背离 `pivot` 的一侧，
    /// 于是路从闸向外弯，像光线散开，而不是贴着判据环走。
    static func control(_ a: CGPoint, _ b: CGPoint, bow: Double, pivot: CGPoint) -> CGPoint {
        let mid = lerp(a, b, 0.5)
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max((dx * dx + dy * dy).squareRoot(), 1)
        var nx = -dy / length, ny = dx / length
        if (mid.x - pivot.x) * nx + (mid.y - pivot.y) * ny < 0 { nx = -nx; ny = -ny }
        return CGPoint(x: mid.x + nx * length * bow, y: mid.y + ny * length * bow)
    }
}

/// 一个沿路飞行的包。种类来自真实的决策。
private struct LPPacket: Identifiable {
    enum Kind { case proxy, direct, blocked }
    let id = UUID()
    let kind: Kind
    let start: Date
    let duration: Double
}

/// 问路的探针：输入一个域名时，图上实时画出它的去向。
private struct LPProbe: Equatable {
    enum Target: Equatable { case exit, direct, blocked }
    let host: String
    let policy: String
    let target: Target
    /// 判定直接点名了一个出口时，探针落到那颗星上，而不是当前出口。
    let node: String?
}

@MainActor
struct LPNetworkMap: View {
    @ObservedObject var scenes: NetworkScenes
    @ObservedObject var bookmarks: NetworkBookmarks
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var engine = LeapinEngine.shared
    /// 常驻事实的唯一数据源：与菜单栏面板、实时浮窗是同一个对象。
    @ObservedObject private var resident = ResidentStatusStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lpWindowWidth) private var windowWidth

    @State private var appeared = Date()
    @State private var settled = false
    @State private var packets: [LPPacket] = []
    @State private var budget = 0.0
    @State private var lastBlocked = 0
    /// 星「跃」的那一刻：换路生效时弦亮一闪。
    @State private var leapAt: Date?
    @State private var firstStop: String?
    /// 出口名 → 能手动切到它的策略组。只有这些星点得动。
    @State private var selectable: [String: String] = [:]
    @State private var latencies: [String: Int] = [:]
    @State private var hoveredNode: String?
    /// 「问路」框里的字。边打边画，回车才去「为什么」。
    @State private var ask = ""
    @State private var probe: LPProbe?
    @FocusState private var askFocused: Bool
    @State private var departing: UnitPoint?
    @State private var toolsOpen = false
    @State private var lanDevices: [NASDevice] = []
    @State private var lanScanning = false
    @State private var lanHovering = false
    @State private var discovery = NASDiscovery()

    private var status: ResidentStatus { resident.status }
    private var running: Bool { engine.state == .running }
    private var connected: Bool { running && engine.systemProxyActive }

    /// 配置里的出口：除 DIRECT / REJECT 这两个内置去向之外的全部节点。
    /// 不按 `isDialable` 筛——vmess 这些协议原生内核拨不了，但在 mihomo 内核下是正经出口。
    private var names: [String] {
        engine.profile.outbounds.filter { $0.type != .direct && $0.type != .reject }.map(\.name)
    }

    /// 运行中却没有经过任何出口：当前选的就是 DIRECT。图上不挂星，直连线亮着。
    private var exitIsDirect: Bool {
        running && (status.exit ?? "").caseInsensitiveCompare("DIRECT") == .orderedSame
    }

    /// 星：当前生效的出口。没在跑时退到候选的第一个——连上之后走的就是它。
    private var starID: String? {
        guard !exitIsDirect else { return nil }
        let all = names
        if let exit = status.exit, all.contains(exit) { return exit }
        if let first = firstStop, all.contains(first) { return first }
        return all.first
    }

    private var worldNodes: [LPWorldNode] { LPWorldLayout.nodes(names: names, current: starID, labelled: []) }
    private var starNode: LPWorldNode? { worldNodes.first(where: \.current) }
    private var hasOtherNodes: Bool {
        names.contains { LPRegion.of($0) == .other && !LPWorldLayout.isPlaceholder($0) }
    }

    private var activeScene: NetworkScene? {
        guard let active = scenes.active, scenes.profileID(for: active) == engine.profile.id else { return nil }
        return active
    }

    // MARK: 图

    var body: some View {
        GeometryReader { geo in
            let g = LPMapGeometry(size: geo.size, hasOther: hasOtherNodes)
            ZStack(alignment: .topLeading) {
                // 图上任意一处点一下，收起展开的工具。
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { if toolsOpen { toggleTools() } }
                canvas(g)
                exitButtons(g)
                heroLabel(g)
                centerLabel(g)
                judgeLabel(g)
                bendLabel(g)
                directLabel(g)
                places(g)
                if toolsOpen { toolSatellites(g) }
                sceneRail(g)
                recentDecisions(g)
                probeTag(g)
                askBar(g)
                cornerFacts(g)
                actions(g)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            // 走过去：镜头从点中的那个地方推近，再进页面。
            .scaleEffect(departing == nil ? 1 : 1.7, anchor: departing ?? .center)
            .opacity(departing == nil ? 1 : 0)
            .lpAnimation(LPMotion.emphasized, value: departing)
        }
        .task(id: engine.state) { await drive() }
        .task {
            #if DEBUG
            // 快照工具预填问路框：探针画成什么样，不靠人手敲。与 Platform.swift 的快照钩子同一类。
            if let seed = ProcessInfo.processInfo.environment["LEAPIN_SHOT_ASK"] { ask = seed }
            #endif
            try? await Task.sleep(for: .milliseconds(1100))
            settled = true
        }
        .onChange(of: engine.profile.id) { _, _ in Task { await refreshExit() } }
        .onChange(of: status.exit) { _, _ in leapAt = Date() }
        .onChange(of: ask) { _, text in probe = resolveProbe(text) }
        // 这一页没有列表可过滤：⌘F 落到「问路」框，而不是弹命令面板。
        .onChange(of: app.searchFocusRequest) { _, _ in askFocused = true }
        .onDisappear { discovery.stop() }
    }

    private var animating: Bool {
        !reduceMotion && (running || probe != nil || !settled || (leapAt.map { Date().timeIntervalSince($0) < 0.7 } ?? false))
    }

    private func canvas(_ g: LPMapGeometry) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !animating)) { timeline in
            Canvas { context, _ in
                draw(context, geometry: g, now: timeline.date)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: 画

    private func circle(_ point: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(center: point, radius: radius))
    }

    private func text(_ context: GraphicsContext, _ string: String, at point: CGPoint, anchor: UnitPoint = .center,
                      size: CGFloat = 10, weight: Font.Weight = .medium, color: Color, tracking: CGFloat = 0) {
        context.draw(Text(string).font(.system(size: size, weight: weight)).tracking(tracking).foregroundColor(color),
                     at: point, anchor: anchor)
    }

    private func quadPath(_ from: CGPoint, _ to: CGPoint, bow: Double, pivot: CGPoint) -> Path {
        var path = Path()
        path.move(to: from)
        path.addQuadCurve(to: to, control: LPMapMath.control(from, to, bow: bow, pivot: pivot))
        return path
    }

    private func draw(_ context: GraphicsContext, geometry g: LPMapGeometry, now: Date) {
        let life = now.timeIntervalSince(appeared)
        let enter: Double = reduceMotion || settled ? 1 : min(1, max(0, life / 0.7))
        let ink = LP.text
        let nodes = worldNodes
        let star = starNode
        let starPoint = star.map { g.point($0) } ?? g.point(90)
        let gateTop = g.gateTop
        let clock = now.timeIntervalSinceReferenceDate

        // 星尘：很淡的一层参考点，带一点呼吸。和舞台的天空是同一层——空间的深度靠它，不靠装饰。
        for index in 0..<90 {
            let seed = Double(index)
            let x = (seed * 127.1).truncatingRemainder(dividingBy: max(g.size.width, 1))
            let y = (seed * 311.7).truncatingRemainder(dividingBy: max(g.size.height, 1))
            let twinkle: Double = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(clock * 0.9 + seed * 1.7)
            let radius: CGFloat = index % 9 == 0 ? 1.3 : 0.9
            context.fill(circle(CGPoint(x: x, y: y), radius), with: .color(ink.opacity(0.03 + 0.06 * twinkle)))
        }

        // 轨道：一整圈很淡的圆，上半圈是点线——世界弧。入场时从正上方往两边画开。
        context.stroke(circle(g.center, g.radius), with: .color(ink.opacity(0.07)), lineWidth: 1)
        var arc = Path()
        let span = (LPWorldLayout.arcEnd - LPWorldLayout.arcStart) * enter
        for step in 0...64 {
            let point = g.point(90 - span / 2 + span * Double(step) / 64)
            if step == 0 { arc.move(to: point) } else { arc.addLine(to: point) }
        }
        context.stroke(arc, with: .color(ink.opacity(0.38)),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [0.1, 5]))

        // 地区名：写在弧的内侧、各自那一簇点的下方。弧的外侧整条带留给出口的大字。
        // 星所在的那个地区不写——它的名字并进了大字的第二行。
        for region in LPRegion.allCases where region != .other && region != star?.region {
            text(context, region.title, at: g.point(region.angle, 0.82), size: 10, weight: .semibold,
                 color: LP.textTertiary.opacity(enter), tracking: 1.2)
        }
        if nodes.contains(where: { $0.region == .other }) {
            text(context, LPRegion.other.title,
                 at: CGPoint(x: g.otherCenterX, y: g.point(90, g.otherRing).y - (g.otherRing < LPRegion.other.ring ? 26 : 20)),
                 size: 10, weight: .semibold, color: LP.textTertiary.opacity(enter), tracking: 1.2)
        }

        // 判据环：虚线圆 + 两道闸。
        var ring = Path()
        ring.addArc(center: g.center, radius: g.shell, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
        context.stroke(ring, with: .color(ink.opacity(0.34)), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
        for angle in [90.0, 270.0] {
            var tick = Path()
            tick.move(to: g.point(angle, (g.shell - 7) / g.radius))
            tick.addLine(to: g.point(angle, (g.shell + 7) / g.radius))
            context.stroke(tick, with: .color(running ? LP.accent : ink.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }

        // 路：这台 Mac → 两道闸。
        for gate in [gateTop, g.gateBottom] {
            var approach = Path()
            approach.move(to: g.center)
            approach.addLine(to: gate)
            context.stroke(approach, with: .color(ink.opacity(0.42)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
        // 闸 → 每一个出口的引线：所有出口都是从这一道闸出发的。
        for node in nodes where !node.current {
            context.stroke(quadPath(gateTop, g.point(node), bow: 0.12, pivot: g.center),
                           with: .color(ink.opacity(0.06 * enter)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
        // 主路：上闸 → 星。没在跑时是虚线，连上才亮。出口就是 DIRECT 时不画——没有这条路。
        let main = quadPath(gateTop, starPoint, bow: 0.12, pivot: g.center)
        if running {
            if exitIsDirect {
                context.stroke(main, with: .color(ink.opacity(0.12)),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 7]))
            } else {
                context.stroke(main, with: .color(LP.accent.opacity(0.85)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
        } else {
            context.stroke(main, with: .color(ink.opacity(0.30)),
                           style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 6]))
        }
        // 下闸 → 直连。出口就是 DIRECT 时这条路是主角。
        var down = Path()
        down.move(to: g.gateBottom)
        down.addLine(to: g.direct)
        if running && exitIsDirect {
            context.stroke(down, with: .color(LP.mint.opacity(0.95)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        } else {
            context.stroke(down, with: .color(running ? LP.mint.opacity(0.65) : ink.opacity(0.30)),
                           style: running ? StrokeStyle(lineWidth: 1.4, lineCap: .round)
                                          : StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 6]))
        }
        // 回家的隧道：绑定过就有路，Tailnet 在线时亮。
        if app.home.saved != nil {
            var tunnel = Path()
            tunnel.move(to: g.point(.home))
            tunnel.addLine(to: g.point(LPPlace.home.angle, g.shell / g.radius))
            let online = app.home.snapshot?.state == "Running"
            context.stroke(tunnel, with: .color(online ? LP.mint.opacity(0.7) : ink.opacity(0.25)),
                           style: StrokeStyle(lineWidth: online ? 1.4 : 1.2, lineCap: .round, dash: [2, 5]))
        }

        // 「跃」：换路生效的那一下，主路亮起再暗下去，星上荡开一圈。
        if let leapAt, star != nil {
            let age = now.timeIntervalSince(leapAt)
            if age >= 0, age < 0.7 {
                let fade = 1 - age / 0.7
                context.stroke(main, with: .color(LP.accent.opacity(0.9 * fade)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
                context.stroke(circle(starPoint, 10 + 34 * (1 - fade)), with: .color(LP.accent.opacity(0.8 * fade)), lineWidth: 1.5)
            }
        }

        // 这台 Mac。
        context.fill(circle(g.center, 5), with: .color(ink.opacity(0.85)))

        // 弯：路在这里断开——「改成什么」就弯在这里。
        let bend = bendPoint(g, star: starPoint)
        context.fill(circle(bend, 7), with: .color(LP.paper))
        context.stroke(circle(bend, 4.5), with: .color(ink.opacity(0.8)), lineWidth: 1.5)

        // 直连星。
        context.fill(circle(g.direct, 3.4), with: .color(running ? LP.mint : LP.mint.opacity(0.7)))

        // 出口：地区簇里的点；当前出口是星。密的地方名字隔几个写一个，其余悬停才出名字。
        var seen: [LPRegion: Int] = [:]
        let counts = Dictionary(grouping: nodes, by: \.region).mapValues(\.count)
        for (index, node) in nodes.enumerated() {
            let point = g.point(node)
            let fade: Double = reduceMotion || settled ? 1 : min(1, max(0, (life - 0.2 - Double(index % 14) * 0.035) / 0.45))
            let twinkle: Double = reduceMotion || !running ? 0 : 0.14 * sin(clock * 1.3 + Double(index) * 1.9)
            if node.current {
                let pulse: Double = reduceMotion ? 1 : 1 + 0.10 * sin(clock * 2.4)
                if running {
                    let glow = 34 * pulse
                    context.fill(circle(point, glow), with: .radialGradient(
                        Gradient(colors: [LP.accent.opacity(0.45), .clear]), center: point, startRadius: 0, endRadius: glow))
                    context.fill(circle(point, 6), with: .color(LP.accent))
                    context.stroke(circle(point, 12 * pulse), with: .color(LP.accent.opacity(0.55)), lineWidth: 1)
                } else {
                    context.stroke(circle(point, 6), with: .color(LP.accent.opacity(0.9)), lineWidth: 1.5)
                    context.fill(circle(point, 2.4), with: .color(LP.accent))
                }
                continue
            }
            let highlighted = hoveredNode == node.id
            context.fill(circle(point, highlighted ? 3.8 : 2.8),
                         with: .color((highlighted ? LP.text : ink).opacity((highlighted ? 0.95 : 0.52 + twinkle) * fade)))
            let order = seen[node.region, default: 0]
            seen[node.region] = order + 1
            let stride = labelStride(count: counts[node.region] ?? 1, radius: g.radius)
            guard node.labelled && order % stride == 0 || highlighted else { continue }
            let label = highlighted ? (latencies[node.id].map { "\(node.id) · \($0) ms" } ?? node.id) : node.id
            // 名字写在点的外侧；贴近两端的点往左右写，免得挤到地区名。
            var at = CGPoint(x: point.x, y: point.y - 8)
            var anchor = UnitPoint.bottom
            if node.region == .other {
                at = CGPoint(x: point.x, y: point.y + 8)
                anchor = .top
            } else if node.angle < 50 {
                at = CGPoint(x: point.x + 8, y: point.y)
                anchor = .leading
            } else if node.angle > 130 {
                at = CGPoint(x: point.x - 8, y: point.y)
                anchor = .trailing
            }
            text(context, label, at: at, anchor: anchor, weight: highlighted ? .semibold : .medium,
                 color: (highlighted ? LP.text : LP.textSecondary).opacity(fade))
        }

        // 包。
        for packet in packets {
            let progress = now.timeIntervalSince(packet.start) / packet.duration
            if progress < 0 || progress > 1 { continue }
            let color: Color
            switch packet.kind {
            case .proxy: color = LP.accent
            case .direct: color = LP.mint
            case .blocked: color = LP.danger.opacity(0.95)
            }
            if packet.kind == .blocked, progress > 0.62 {
                // 撞在上闸：一枚扩散后消散的红环。
                let burst = (progress - 0.62) / 0.38
                context.stroke(circle(gateTop, 4 + burst * 15), with: .color(color.opacity(1 - burst)), lineWidth: 1.6)
                continue
            }
            let point = position(packet, progress: progress, geometry: g, star: starPoint)
            for step in 1...4 {
                let tail = progress - Double(step) * 0.022
                if tail > 0 {
                    context.fill(circle(position(packet, progress: tail, geometry: g, star: starPoint), 3.0 - Double(step) * 0.5),
                                 with: .color(color.opacity(0.20 - Double(step) * 0.035)))
                }
            }
            context.fill(circle(point, packet.kind == .blocked ? 3.4 : 3.0), with: .color(color))
        }

        // 探针：问路框里有一个域名时，它的路亮起来，一枚空心的环沿路跑过去。
        if let probe {
            let end = probePoint(probe, geometry: g, star: starPoint)
            var path = Path()
            path.move(to: g.center)
            switch probe.target {
            case .direct:
                path.addLine(to: g.gateBottom)
                path.addLine(to: end)
            case .blocked:
                path.addLine(to: end)
            case .exit:
                path.addLine(to: gateTop)
                path.addQuadCurve(to: end, control: LPMapMath.control(gateTop, end, bow: 0.12, pivot: g.center))
            }
            let color = probe.target == .blocked ? LP.danger : ink
            context.stroke(path, with: .color(color.opacity(0.75)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 4]))
            if !reduceMotion {
                let phase = (clock / 1.1).truncatingRemainder(dividingBy: 1)
                for offset in [0.0, 0.5] {
                    let t = (phase + offset).truncatingRemainder(dividingBy: 1)
                    context.stroke(circle(probePosition(probe, t, geometry: g, star: starPoint), 4.5),
                                   with: .color(color.opacity(0.9 - t * 0.4)), lineWidth: 1.5)
                }
            }
            if probe.target == .blocked {
                var cross = Path()
                cross.move(to: CGPoint(x: end.x - 5, y: end.y - 5))
                cross.addLine(to: CGPoint(x: end.x + 5, y: end.y + 5))
                cross.move(to: CGPoint(x: end.x + 5, y: end.y - 5))
                cross.addLine(to: CGPoint(x: end.x - 5, y: end.y + 5))
                context.stroke(cross, with: .color(LP.danger), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            } else {
                context.stroke(circle(end, 10), with: .color(color.opacity(0.8)), lineWidth: 1.5)
            }
        }
    }

    /// 一个地区里隔几个点写一个名字：相邻两个名字之间至少隔 46pt。
    private func labelStride(count: Int, radius: CGFloat) -> Int {
        guard count > 1 else { return 1 }
        let spacing = min(12.0, 36.0 / Double(count)) * Double(radius) * Double.pi / 180
        return max(1, Int((46 / spacing).rounded(.up)))
    }

    /// 弯在主路上的位置：刚出判据环的那一段。不放正中——正中会落进出口簇的名字里。
    private func bendPoint(_ g: LPMapGeometry, star: CGPoint) -> CGPoint {
        LPMapMath.quad(g.gateTop, LPMapMath.control(g.gateTop, star, bow: 0.12, pivot: g.center), star, 0.33)
    }

    private func position(_ packet: LPPacket, progress: Double, geometry g: LPMapGeometry, star: CGPoint) -> CGPoint {
        let approachEnd = packet.kind == .blocked ? 0.62 : 0.40
        let gate = packet.kind == .direct ? g.gateBottom : g.gateTop
        if progress <= approachEnd {
            return LPMapMath.lerp(g.center, gate, progress / approachEnd)
        }
        let rest = (progress - approachEnd) / (1 - approachEnd)
        switch packet.kind {
        case .direct: return LPMapMath.lerp(gate, g.direct, rest)
        case .blocked: return gate
        case .proxy:
            return LPMapMath.quad(gate, LPMapMath.control(gate, star, bow: 0.12, pivot: g.center), star, rest)
        }
    }

    private func probePosition(_ probe: LPProbe, _ t: Double, geometry g: LPMapGeometry, star: CGPoint) -> CGPoint {
        let end = probePoint(probe, geometry: g, star: star)
        switch probe.target {
        case .direct:
            if t < 0.4 { return LPMapMath.lerp(g.center, g.gateBottom, t / 0.4) }
            return LPMapMath.lerp(g.gateBottom, end, (t - 0.4) / 0.6)
        case .blocked:
            return LPMapMath.lerp(g.center, g.gateTop, t)
        case .exit:
            if t < 0.4 { return LPMapMath.lerp(g.center, g.gateTop, t / 0.4) }
            return LPMapMath.quad(g.gateTop, LPMapMath.control(g.gateTop, end, bow: 0.12, pivot: g.center), end, (t - 0.4) / 0.6)
        }
    }

    /// 探针的终点：直连星、上闸，或判定点名的那颗出口——没点名就是当前出口。
    private func probePoint(_ probe: LPProbe, geometry g: LPMapGeometry, star: CGPoint) -> CGPoint {
        switch probe.target {
        case .direct: return g.direct
        case .blocked: return g.gateTop
        case .exit:
            if let node = probe.node, let placed = worldNodes.first(where: { $0.id == node }) { return g.point(placed) }
            return star
        }
    }

    // MARK: 喂数据（与舞台同一模式）

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
            firstStop = nil
            selectable = [:]
            latencies = [:]
            return
        }
        firstStop = group.members.first?.name
        var pickable: [String: String] = [:]
        var ping: [String: Int] = [:]
        for entry in groups {
            for node in entry.members {
                if let ms = node.latencyMs { ping[node.name] = ms }
                // 同一个节点在几个组里都出现时，优先记当前组：切它才真的换路。
                if pickable[node.name] == nil || entry.name == latest.currentGroup { pickable[node.name] = entry.name }
            }
        }
        selectable = pickable
        latencies = ping
    }

    /// 放飞包：速率越高每秒越多；拦截数每涨一个就放一个撞闸的包；
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

    private func resolveProbe(_ text: String) -> LPProbe? {
        guard let site = SiteTarget(text) else { return nil }
        // 没在跑时用保存的配置预估：连接之前也能先看它会走哪条路。
        let match = engine.explain(host: site.host)
            ?? RuleEngine(profile: engine.profile).explain(ConnectionMeta(host: site.host, port: site.port))
        let policy = match.policy
        switch policy.lowercased() {
        case "direct":
            return LPProbe(host: site.host, policy: policy, target: .direct, node: nil)
        case "reject":
            return LPProbe(host: site.host, policy: policy, target: .blocked, node: nil)
        default:
            return LPProbe(host: site.host, policy: policy, target: .exit, node: names.contains(policy) ? policy : nil)
        }
    }

    // MARK: 走过去

    private func depart(_ section: AppModel.Section, from point: CGPoint, in size: CGSize) {
        guard !reduceMotion else { app.go(to: section); return }
        withAnimation(LPMotion.emphasized) {
            departing = UnitPoint(x: point.x / max(size.width, 1), y: point.y / max(size.height, 1))
        }
        Task {
            try? await Task.sleep(for: .milliseconds(260))
            app.go(to: section)
        }
    }

    private func askWhy(_ text: String, geometry g: LPMapGeometry) {
        guard let target = SiteTarget(text) else {
            app.showToast("请输入域名或完整网址，例如 github.com", kind: .info)
            return
        }
        ask = ""
        app.routes.focus(RouteSubject(host: target.host, port: Int(target.port), source: .dashboard))
        // 镜头从探针的终点推近：去的正是它在图上的去向。
        if let probe {
            depart(.why, from: probePoint(probe, geometry: g, star: starPoint(g)), in: g.size)
        } else {
            app.go(to: .why)
        }
    }

    /// 点一颗星就是走这条路。只有能手动切的节点才点得动；其余的只报名字。
    private func pick(_ name: String) {
        guard running, name != starID, let group = selectable[name] else { return }
        Task {
            do {
                try await engine.menuBarSelect(group: group, member: name)
                await refreshExit()
            } catch {
                app.showToast(error.localizedDescription, kind: .error)
            }
        }
    }

    private func toggleTools() {
        LPMotion.run(LPMotion.spring) { toolsOpen.toggle() }
    }

    private func scanLAN() {
        if lanScanning {
            discovery.stop()
            lanScanning = false
            return
        }
        lanScanning = true
        // 结果从私有队列回来：回主线程再落到图上。
        discovery.start { list in
            Task { @MainActor in
                lanDevices = Array(list.prefix(8))
                lanScanning = false
            }
        }
    }

    // MARK: 出口

    private func starPoint(_ g: LPMapGeometry) -> CGPoint {
        starNode.map { g.point($0) } ?? g.point(90)
    }

    @ViewBuilder private func exitButtons(_ g: LPMapGeometry) -> some View {
        ForEach(worldNodes) { node in
            let point = g.point(node)
            let pickable = running && node.current == false && selectable[node.id] != nil
            Button { pick(node.id) } label: {
                Circle().fill(Color.clear).frame(width: 22, height: 22).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .position(point)
            .onHover { value in hoveredNode = value ? node.id : nil }
            .help(pickable ? "走 \(node.id)" : node.id)
            .accessibilityLabel(pickable ? "出口 \(node.id)，点此切换" : "出口 \(node.id)")
        }
    }

    /// 星的大字：出口名 + 地区与延迟。写在弧的外侧，底下垫一层纸，引线从它后面过。
    private func heroLabel(_ g: LPMapGeometry) -> some View {
        let node = starNode
        let star = starPoint(g)
        // 抬得比邻居的名字高出一截：弧上别的名字写在点上方 8pt，大字从 40pt 外开始。
        let ring = node?.region == .other ? g.otherRing : (node?.radius ?? 1)
        let radial = g.point(node?.angle ?? 90, ring + 62 / g.radius)
        // 「其他」那一簇被挪过位置，大字跟着星走，不跟着方位角。
        let out = CGPoint(x: node?.region == .other ? star.x : radial.x, y: radial.y)
        let left = 16 + g.railWidth + 118
        let x = min(max(out.x, left), max(left, g.size.width - 118))
        let title: String
        let detail: String
        if exitIsDirect {
            title = "直连出去"
            detail = "走代理的流量不经过任何出口"
        } else if case .failed = engine.state {
            title = node?.id ?? "没能启动"
            detail = status.issues.first?.text ?? engine.lastError ?? "启动失败。"
        } else if let node {
            title = node.id
            var parts = [node.region.title]
            if let group = status.exitGroup, !group.isEmpty { parts.append(group) }
            if let latency = latencies[node.id] { parts.append("\(latency) ms") }
            detail = parts.joined(separator: " · ")
        } else {
            title = "还没有出口"
            detail = names.isEmpty ? "导入一份配置，出口会落在世界弧上" : "连上之后，每个请求走哪条路都从这里经过。"
        }
        return Button { depart(.profiles, from: star, in: g.size) } label: {
            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(running && (node != nil || exitIsDirect) ? LP.text : LP.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(LP.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 236)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LP.paper.opacity(0.92)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(x: x, y: out.y)
        .help("当前出口 · 点开看线路与订阅")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("当前出口")
        .accessibilityValue(title)
    }

    // MARK: 四个地方

    private var stateText: String {
        if connected { return "已接管" }
        if running { return "运行中 · 未接管" }
        if case .failed = engine.state { return "没能启动" }
        return "尚未接管"
    }

    private var stateColor: Color {
        if case .failed = engine.state { return LP.danger }
        if connected { return LP.mint }
        if running { return LP.amber }
        return LP.textTertiary
    }

    private func centerLabel(_ g: LPMapGeometry) -> some View {
        HStack(spacing: 6) {
            StatusDot(color: stateColor, pulsing: connected, size: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text("这台 Mac")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LP.text)
                Text(stateText)
                    .font(.system(size: 10))
                    .foregroundStyle(LP.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(width: 130, height: 34, alignment: .leading)
        .position(x: g.center.x + 14 + 65, y: g.center.y)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("这台 Mac，\(stateText)")
    }

    private var judgeTitle: String {
        if running { return activeScene?.title ?? "规则模式" }
        if case .failed = engine.state { return "没能启动" }
        return "尚未接管"
    }

    /// 判据环：环上贴着的名字就是「怎么判」的入口。
    private func judgeLabel(_ g: LPMapGeometry) -> some View {
        let anchor = g.point(135, (g.shell + 14) / g.radius)
        return Button { depart(.rules, from: g.point(135, g.shell / g.radius), in: g.size) } label: {
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .semibold))
                    Text(judgeTitle)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text("\(engine.ruleCount) 条规则")
                    .font(.system(size: 10))
                    .foregroundStyle(LP.textTertiary)
            }
            .foregroundStyle(LP.text)
            .frame(width: 150, height: 34, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(LPHoverLabelStyle())
        .position(x: anchor.x - 76, y: anchor.y)
        .help("打开「怎么判」")
        .accessibilityLabel("判据，\(judgeTitle)，\(engine.ruleCount) 条规则，打开怎么判")
    }

    /// 弯：主路上的「改成什么」。星换了地方，弯跟着走。
    private func bendLabel(_ g: LPMapGeometry) -> some View {
        let bend = bendPoint(g, star: starPoint(g))
        // 名字写在弯的靠中心那一侧：那一半是空的。
        let onRight = bend.x < g.center.x
        let width: CGFloat = 150
        return Button { depart(.rewrite, from: bend, in: g.size) } label: {
            VStack(alignment: onRight ? .leading : .trailing, spacing: 1) {
                Text("改成什么")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(engine.profile.rewrites.count) 条重写 · 去广告 \(engine.adblockRuleCount) 条")
                    .font(.system(size: 10))
                    .foregroundStyle(LP.textTertiary)
                    .lineLimit(1)
            }
            .foregroundStyle(LP.text)
            .frame(width: width, height: 34, alignment: onRight ? .leading : .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(LPHoverLabelStyle())
        .position(x: onRight ? bend.x + 12 + width / 2 : bend.x - 12 - width / 2, y: bend.y)
        .help("打开「改成什么」")
        .accessibilityLabel("改路，\(engine.profile.rewrites.count) 条重写，去广告 \(engine.adblockRuleCount) 条，打开改成什么")
    }

    private func directLabel(_ g: LPMapGeometry) -> some View {
        Text("直连")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(LP.mint)
            .fixedSize()
            .position(x: g.direct.x + 16, y: g.direct.y)
            .allowsHitTesting(false)
    }

    // MARK: 地方

    @ViewBuilder private func places(_ g: LPMapGeometry) -> some View {
        let company = g.point(.company)
        companyWall(company)
        LPObservedPlace(model: app.company, place: .company,
                        active: { $0.active != nil },
                        status: { $0.active.map { "已启用 · \($0.name)" } ?? "未配置" }) {
            depart(.company, from: company, in: g.size)
        }
        .frame(width: 136)
        .position(x: company.x, y: company.y + 19)

        let home = g.point(.home)
        LPObservedPlace(model: app.home, place: .home,
                        active: { $0.saved != nil },
                        status: { $0.saved.map { "已绑定 · \($0.peerName)" } ?? "未绑定" }) {
            depart(.home, from: home, in: g.size)
        }
        .frame(width: 136)
        .position(x: home.x, y: home.y + 19)

        let lan = g.point(.lan)
        lanOrbit(lan)
        LPPlaceButton(place: .lan, status: lanStatus, active: !lanDevices.isEmpty) {
            depart(.nas, from: lan, in: g.size)
        }
        .frame(width: 120)
        .position(x: lan.x, y: lan.y + 19)
        .onHover { value in LPMotion.run(LPMotion.quick) { lanHovering = value } }
        if lanHovering || lanScanning {
            scanChip(lan)
        }

        let marks = g.point(.bookmarks)
        LPPlaceButton(place: .bookmarks, status: bookmarks.items.isEmpty ? "还没有" : "\(bookmarks.items.count) 个",
                      active: !bookmarks.items.isEmpty) {
            app.showBookmarks = true
        }
        .frame(width: 120)
        .position(x: marks.x, y: marks.y + 19)

        let tools = g.point(.tools)
        LPPlaceButton(place: .tools, status: toolsOpen ? "选一件" : "\(toolItems(g).count) 件", active: false) {
            toggleTools()
        }
        .frame(width: 120)
        .position(x: tools.x, y: tools.y + 19)
    }

    /// 公司内网的墙：一圈虚线，朝着中心那一侧留一道口子。
    private func companyWall(_ point: CGPoint) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(LP.text.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .frame(width: 124, height: 68)
            .overlay(alignment: .trailing) {
                // 口子正对图标那一行：墙的中心比图标低 14pt，所以要往上挪。
                Rectangle().fill(LP.paper).frame(width: 3, height: 14).offset(x: 1, y: -14)
            }
            .position(x: point.x, y: point.y + 14)
            .allowsHitTesting(false)
    }

    private var lanStatus: String {
        if lanScanning { return "扫描中…" }
        if !lanDevices.isEmpty { return "\(lanDevices.count) 台设备" }
        return "看设备"
    }

    /// 扫到的设备贴在局域网这一站的旁边，各占轨道上的一个位置；名字在悬停提示里，清单在 NAS 页。
    @ViewBuilder private func lanOrbit(_ point: CGPoint) -> some View {
        ForEach(Array(lanDevices.prefix(8).enumerated()), id: \.element.id) { index, device in
            let radians = (Double(index) * 45 - 90) * Double.pi / 180
            Circle()
                .fill(LP.mint)
                .frame(width: 5, height: 5)
                .overlay(Circle().strokeBorder(LP.paper, lineWidth: 1.5).frame(width: 8, height: 8))
                .position(x: point.x + CGFloat(cos(radians)) * 25, y: point.y + CGFloat(sin(radians)) * 25)
                .help("\(device.name) · \(device.host)")
                .accessibilityLabel("局域网设备 \(device.name)")
        }
    }

    private func scanChip(_ point: CGPoint) -> some View {
        Button { scanLAN() } label: {
            Text(lanScanning ? "停止" : "扫描")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LP.text)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(LP.sheet))
                .overlay(Capsule().strokeBorder(LP.lineStrong, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .position(x: point.x, y: point.y - 36)
        .help("在局域网里找 NAS")
        .accessibilityLabel(lanScanning ? "停止扫描局域网" : "扫描局域网里的 NAS")
    }

    // MARK: 工具

    private struct ToolItem {
        let title: String
        let icon: String
        let action: () -> Void
    }

    private func toolItems(_ g: LPMapGeometry) -> [ToolItem] {
        [
            ToolItem(title: "连接服务器", icon: "terminal") { depart(.ssh, from: g.point(.tools), in: g.size) },
            ToolItem(title: "分享与调试", icon: "link") { depart(.tools, from: g.point(.tools), in: g.size) },
            ToolItem(title: "抓包", icon: "waveform.path.ecg") { depart(.capture, from: g.point(.tools), in: g.size) },
            ToolItem(title: "排障", icon: "stethoscope") { depart(.diagnostics, from: g.point(.tools), in: g.size) },
            ToolItem(title: "App 分流", icon: "brain") { depart(.learn, from: g.point(.tools), in: g.size) },
            ToolItem(title: "设置", icon: "gearshape") { depart(.settings, from: g.point(.tools), in: g.size) },
            ToolItem(title: "导入配置", icon: "square.and.arrow.down") { app.beginImport() },
        ]
    }

    /// 工具的卫星：点一下「工具」，几件工具从它右边一列展开，各连一条短线。
    private func toolSatellites(_ g: LPMapGeometry) -> some View {
        let origin = g.point(.tools)
        let items = toolItems(g)
        let iconOnly = g.size.width < 860
        let width: CGFloat = iconOnly ? 26 : 120
        return ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            let y = origin.y + (Double(index) - Double(items.count - 1) / 2) * 28
            Rectangle()
                .fill(LP.line)
                .frame(width: 42, height: 1)
                .position(x: origin.x + 17 + 21, y: y)
                .allowsHitTesting(false)
            toolChip(item, iconOnly: iconOnly)
                .frame(width: width, height: 26, alignment: iconOnly ? .center : .leading)
                .position(x: origin.x + 60 + width / 2, y: y)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
        }
    }

    private func toolChip(_ item: ToolItem, iconOnly: Bool) -> some View {
        Button(action: item.action) {
            LPHoverChip(icon: item.icon, title: item.title, iconOnly: iconOnly)
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityLabel(item.title)
    }

    // MARK: 场景导轨

    /// 六个场景是一条导轨（模式选择器的读感），不是六颗胶囊：当前场景实心墨底，
    /// 绑过配置的是实心点，没绑的是空心圈——看一眼就知道哪几站能走。
    private func sceneRail(_ g: LPMapGeometry) -> some View {
        let all = Array(NetworkScene.allCases)
        let caption = g.size.width >= 860
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                LPLabel("场景")
                Spacer()
                if let activeScene {
                    Button("调整当前场景") { app.sceneToConfigure = activeScene }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(LP.textSecondary)
                }
            }
            HStack(spacing: 0) {
                ForEach(Array(all.enumerated()), id: \.offset) { offset, scene in
                    sceneSegment(scene)
                    if offset < all.count - 1,
                       activeScene != scene, offset + 1 < all.count, activeScene != all[offset + 1] {
                        Rectangle().fill(LP.line).frame(width: 1, height: 18)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous)
                    .fill(LP.sheet)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous)
                    .strokeBorder(LP.line, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous))
            if caption {
                Text(sceneCaption)
                    .font(.system(size: 12))
                    .foregroundStyle(LP.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(width: g.railWidth, height: caption ? 100 : 72, alignment: .topLeading)
        .position(x: 16 + g.railWidth / 2, y: 12 + (caption ? 50 : 36))
    }

    private func sceneSegment(_ scene: NetworkScene) -> some View {
        let active = activeScene == scene
        let bound = scenes.profileID(for: scene) != nil
        let boundName = scenes.profileID(for: scene).flatMap { id in
            app.engine.profiles.first(where: { $0.id == id })?.name
        }
        return Button { app.switchScene(scene) } label: {
            HStack(spacing: 6) {
                Circle()
                    .strokeBorder(active ? LP.accentOnInk : LP.textTertiary.opacity(0.7), lineWidth: 1)
                    .background(Circle().fill(active ? LP.accentOnInk : (bound ? LP.text.opacity(0.6) : Color.clear)))
                    .frame(width: 7, height: 7)
                Text(scene.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(active ? LP.onInk : (bound ? LP.text : LP.textSecondary))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 6)
            .frame(height: 36)
            .background(active ? LP.ink : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(app.networkBusy)
        .help(boundName.map { "\(scene.detail)\n绑定：\($0)" } ?? "\(scene.detail)\n还没绑定配置，点了先选一份")
        .accessibilityLabel("\(scene.title)，\(bound ? "切换场景" : "未绑定方案")")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var sceneCaption: String {
        guard let activeScene else {
            return "点一个场景就切过去；还没绑配置的，会先让你选一份。"
        }
        if let id = scenes.profileID(for: activeScene),
           let name = app.engine.profiles.first(where: { $0.id == id })?.name {
            return running ? "使用中：\(activeScene.title) · \(name)" : "已选择：\(activeScene.title) · 连接后使用 \(name)"
        }
        return "使用中：\(activeScene.title)"
    }

    // MARK: 最近决策

    private func decisionColor(_ kind: ResidentFlowKind) -> Color {
        switch kind {
        case .blocked: return LP.danger
        case .direct: return LP.mint
        case .proxy: return LP.accent
        case .other: return LP.textTertiary
        }
    }

    @ViewBuilder private func recentDecisions(_ g: LPMapGeometry) -> some View {
        let recent = status.recent.prefix(3)
        if running, !recent.isEmpty, g.size.width >= 900 {
            VStack(alignment: .trailing, spacing: 3) {
                LPLabel("最近决策")
                ForEach(Array(recent)) { flow in
                    Button {
                        askWhy(flow.host, geometry: g)
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(decisionColor(flow.kind))
                                .frame(width: 6, height: 6)
                            Text(flow.host)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(LP.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(flow.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(decisionColor(flow.kind))
                                .lineLimit(1)
                        }
                        .frame(height: 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("带着 \(flow.host) 去「为什么」看它为什么这样走")
                    .accessibilityLabel("\(flow.host)，\(flow.label)，去为什么页查看")
                }
            }
            .frame(width: 300, height: 76, alignment: .topTrailing)
            .position(x: g.size.width - 16 - 150, y: 12 + 38)
        }
    }

    // MARK: 问路

    /// 探针的牌子钉在哪：写在终点旁边，去向直接点名了一颗星时跟着那颗星走。
    private func probeAnchor(_ probe: LPProbe, _ g: LPMapGeometry) -> (destination: String, color: Color, point: CGPoint) {
        let star = starPoint(g)
        let end = probePoint(probe, geometry: g, star: star)
        switch probe.target {
        case .direct:
            // 下闸右侧、贴着直连的路：挂在直连星底下会压到旁边的「常用网站」。
            return ("直连", LP.mint, CGPoint(x: g.gateBottom.x + 16 + 110, y: g.gateBottom.y + 18))
        case .blocked:
            return ("拦截", LP.danger, CGPoint(x: end.x + 16 + 110, y: end.y - 18))
        case .exit:
            let node = probe.node.flatMap { name in worldNodes.first { $0.id == name } } ?? starNode
            // 牌子挂在星的里侧：外侧近处是星自己的大字。
            let ring = node?.region == .other ? g.otherRing : (node?.radius ?? 1)
            let inward = g.point(node?.angle ?? 90, max(0.3, ring - 34 / g.radius))
            return (probe.node ?? starNode?.id ?? probe.policy, LP.accent,
                    CGPoint(x: node?.region == .other ? star.x : inward.x, y: inward.y))
        }
    }

    /// 探针的牌子：域名 → 去向。
    @ViewBuilder private func probeTag(_ g: LPMapGeometry) -> some View {
        if let probe {
            let anchor = probeAnchor(probe, g)
            HStack(spacing: 6) {
                Circle().fill(anchor.color).frame(width: 6, height: 6)
                Text(probe.host)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 190, alignment: .leading)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                Text(anchor.destination)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 120, alignment: .leading)
            }
            .fixedSize()
            .foregroundStyle(LP.onInk)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(LP.ink))
            .position(anchor.point)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(probe.host) 走 \(anchor.destination)")
        }
    }

    private func askBar(_ g: LPMapGeometry) -> some View {
        LPAskField(text: $ask, placeholder: "输入域名，看它走哪条路", focus: $askFocused) { text in
            askWhy(text, geometry: g)
        }
        // 底边三分：左下是事实，右下是主操作，中间给问路框留出余量。
        .frame(width: min(380, g.size.width - 2 * (factsWidth(g) + 12)))
        .position(x: g.size.width / 2, y: g.size.height - 34)
    }

    // MARK: 角上的事实与主操作

    private func rate(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(LP.accent)
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(LP.text)
                .monospacedDigit()
        }
    }

    /// 左下角：实时的上下行与拦截数，下面一行是接管范围。这是图上唯一「此刻」的事实。
    @ViewBuilder private func cornerFacts(_ g: LPMapGeometry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if running {
                HStack(spacing: 12) {
                    rate("arrow.down", status.rates.downText)
                    rate("arrow.up", status.rates.upText)
                    if g.size.width >= 860 {
                        Text("拦截 \(status.blocked)")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(LP.textTertiary)
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: status.coverage.isCoveringTraffic ? "checkmark.shield" : "exclamationmark.shield")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(status.coverage.isCoveringTraffic ? LP.mint : LP.accent)
                if windowWidth >= 1100 {
                    Text(status.coverage.declaration)
                        .font(.system(size: 11))
                        .foregroundStyle(LP.textTertiary)
                        .lineLimit(1)
                }
            }
            .help(status.coverage.declaration)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.coverage.declaration)
        }
        .frame(width: factsWidth(g), height: running ? 40 : 18, alignment: .bottomLeading)
        .position(x: 16 + factsWidth(g) / 2, y: g.size.height - 14 - (running ? 20 : 9))
    }

    /// 窄窗口里这一栏只放得下速率一行。
    private func factsWidth(_ g: LPMapGeometry) -> CGFloat { g.size.width < 860 ? 176 : 250 }

    /// 右下角的主操作。窄窗口里省掉「导入配置」——侧栏和工具卫星里都有它。
    @ViewBuilder private func actions(_ g: LPMapGeometry) -> some View {
        let compact = g.size.width < 860
        HStack(spacing: 8) {
            if !connected, !compact {
                Button("导入配置") { app.beginImport() }
                    .buttonStyle(LPGhostButtonStyle())
            }
            if connected {
                Button("暂停接管") { Task { await app.pauseNetwork() } }
                    .buttonStyle(LPGhostButtonStyle())
            } else {
                Button(app.networkBusy ? "准备中…" : (running ? "接管网络" : "连接网络")) { app.connectNetwork() }
                    .buttonStyle(LPPrimaryButtonStyle())
                    .disabled(app.networkBusy || engine.configurationBusy || engine.state == .starting)
            }
        }
        .frame(width: compact ? 104 : 250, height: 28, alignment: .trailing)
        .position(x: g.size.width - 16 - (compact ? 52 : 125), y: g.size.height - 30)
    }
}

// MARK: - 小件

/// 一个地方：图标 + 名字 + 一句状态。悬停时图标描朱红。
private struct LPPlaceButton: View {
    let place: LPPlace
    let status: String
    let active: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(LP.sheet).frame(width: 34, height: 34)
                    Circle().strokeBorder(hovering ? LP.accent : LP.lineStrong, lineWidth: 1).frame(width: 34, height: 34)
                    Image(systemName: place.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(hovering ? LP.accent : LP.text)
                }
                Text(place.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LP.text)
                    .lineLimit(1)
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(active ? LP.mint : LP.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .scaleEffect(hovering ? 1.06 : 1)
        .lpAnimation(LPMotion.quick, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(place.title)，\(status)")
    }
}

/// 状态来自另一个可观察对象的地方（公司内网、回家）：只有它在变，地图其余部分不跟着重画。
private struct LPObservedPlace<Model: ObservableObject>: View {
    @ObservedObject var model: Model
    let place: LPPlace
    let active: (Model) -> Bool
    let status: (Model) -> String
    let action: () -> Void

    var body: some View {
        LPPlaceButton(place: place, status: status(model), active: active(model), action: action)
    }
}

/// 图上的一处名字：平时是墨色，悬停转朱红。
private struct LPHoverLabelStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LPHoverLabel(configuration: configuration)
    }

    private struct LPHoverLabel: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering || configuration.isPressed ? LP.accent : LP.text)
                .onHover { value in LPMotion.run(LPMotion.quick) { hovering = value } }
                .scaleEffect(hovering ? 1.04 : 1)
                .contentShape(Rectangle())
        }
    }
}

private struct LPHoverChip: View {
    let icon: String
    let title: String
    let iconOnly: Bool

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            if !iconOnly {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundStyle(hovering ? LP.accent : LP.text)
        .padding(.horizontal, iconOnly ? 0 : 9)
        .frame(minWidth: 24, minHeight: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(LP.sheet))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(hovering ? LP.accent : LP.lineStrong, lineWidth: 1))
        .contentShape(Rectangle())
        .scaleEffect(hovering ? 1.05 : 1)
        .onHover { value in LPMotion.run(LPMotion.quick) { hovering = value } }
    }
}

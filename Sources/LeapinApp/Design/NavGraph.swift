import SwiftUI
import LeapinRuntime

// MARK: - 星图导航（替代平铺 tab 列表）
//
// 网络是拓扑，导航就该是拓扑：这台 Mac 是根节点，四个动词是主星座，
// 工具是一簇卫星，导入 / 设置沉在底部。节点之间用细线连成星座，
// 当前位置的节点点亮、它那条连线跟着点亮；切换时新节点沿连线「跃」一下。
//
// 所有的点都是真的按钮（VoiceOver 按 button 读），位置手工摆过：
// 有意错开，避免读成一份缩进列表。

struct LPNavNodeSpec: Identifiable, Equatable {
    enum Kind { case root, verb, hub, tool, storage, action }

    let id: String
    let label: String
    let icon: String
    let kind: Kind
    /// 星图里的位置（画布坐标，pt）。
    let point: CGPoint
    /// 导入是动作不是页面：按下走 beginImport，永远不亮。
    var isImport: Bool = false

    var idOf: String { id }
}

enum LPNavGraphSpec {
    static let canvasWidth: CGFloat = 188
    static let canvasHeight: CGFloat = 574

    /// 连线：星图读取的是「谁连着谁」。动词节点的 id 就是 section 的 rawValue，
    /// 当前页面才点得亮对应的节点和连线。
    static let edges: [(String, String)] = [
        ("root", "dashboard"), ("root", "rules"), ("root", "rewrite"), ("root", "why"),
        ("root", "toolsHub"),
        ("toolsHub", "ssh"), ("toolsHub", "nas"), ("toolsHub", "home"), ("toolsHub", "company"), ("toolsHub", "tools"),
        ("root", "import"), ("import", "settings"),
    ]

    static let nodes: [LPNavNodeSpec] = [
        LPNavNodeSpec(id: "root", label: "这台 Mac", icon: "macwindow", kind: .root, point: CGPoint(x: 94, y: 26)),
        LPNavNodeSpec(id: "dashboard", label: "走哪", icon: "gauge.with.dots.needle.67percent", kind: .verb, point: CGPoint(x: 148, y: 92)),
        LPNavNodeSpec(id: "rules", label: "怎么判", icon: "arrow.triangle.branch", kind: .verb, point: CGPoint(x: 40, y: 156)),
        LPNavNodeSpec(id: "rewrite", label: "改成什么", icon: "arrow.triangle.2.circlepath", kind: .verb, point: CGPoint(x: 148, y: 220)),
        LPNavNodeSpec(id: "why", label: "为什么", icon: "waveform.path.ecg", kind: .verb, point: CGPoint(x: 40, y: 284)),
        LPNavNodeSpec(id: "toolsHub", label: "工具", icon: "satellite", kind: .hub, point: CGPoint(x: 94, y: 350)),
        LPNavNodeSpec(id: "ssh", label: "SSH", icon: "terminal", kind: .tool, point: CGPoint(x: 38, y: 408)),
        LPNavNodeSpec(id: "nas", label: "NAS", icon: "externaldrive.connected.to.line.below", kind: .tool, point: CGPoint(x: 150, y: 408)),
        LPNavNodeSpec(id: "home", label: "回家", icon: "house", kind: .tool, point: CGPoint(x: 38, y: 456)),
        LPNavNodeSpec(id: "company", label: "公司内网", icon: "building.2", kind: .tool, point: CGPoint(x: 150, y: 456)),
        LPNavNodeSpec(id: "tools", label: "分享与调试", icon: "link", kind: .tool, point: CGPoint(x: 94, y: 500)),
        LPNavNodeSpec(id: "import", label: "导入", icon: "square.and.arrow.down", kind: .storage, point: CGPoint(x: 52, y: 550), isImport: true),
        LPNavNodeSpec(id: "settings", label: "设置", icon: "gearshape", kind: .storage, point: CGPoint(x: 136, y: 550)),
    ]

    static func node(_ id: String) -> LPNavNodeSpec {
        nodes.first { $0.id == id } ?? nodes[0]
    }
}

/// 星图：连线画在 Canvas，节点是叠在上面的按钮。
struct LPNavGraph: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var engine = LeapinEngine.shared
    @State private var hovering: String?
    /// 刚「跃」过去的节点：切换瞬间给它一次弹出 + 光环。
    @State private var arrived: String?
    @State private var hoveredImport = false

    private var current: String? { app.section?.rawValue }

    var body: some View {
        ZStack(alignment: .topLeading) {
            edgesCanvas
                .frame(width: LPNavGraphSpec.canvasWidth, height: LPNavGraphSpec.canvasHeight)
            ForEach(LPNavGraphSpec.nodes) { node in
                nodeButton(node)
                    .position(node.point)
            }
        }
        .frame(width: LPNavGraphSpec.canvasWidth, height: LPNavGraphSpec.canvasHeight, alignment: .topLeading)
    }

    // MARK: 连线

    private var edgesCanvas: some View {
        Canvas { context, _ in
            for (fromID, toID) in LPNavGraphSpec.edges {
                guard let from = LPNavGraphSpec.nodes.first(where: { $0.id == fromID }),
                      let to = LPNavGraphSpec.nodes.first(where: { $0.id == toID }) else { continue }
                let lit = fromID == current || toID == current
                var path = Path()
                let fromPoint = edgeAnchor(from.point, to.point)
                let toPoint = edgeAnchor(to.point, from.point)
                path.move(to: fromPoint)
                path.addQuadCurve(to: toPoint, control: curveControl(fromPoint, toPoint))
                context.stroke(
                    path,
                    with: .color(lit ? LP.accent : LP.text.opacity(0.16)),
                    style: StrokeStyle(lineWidth: lit ? 2 : 1, lineCap: .round)
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 连线从节点的圆心画到圆心：节点本身有纸色底盘，会把穿过自己的线盖住。
    private func edgeAnchor(_ selfPoint: CGPoint, _ otherPoint: CGPoint) -> CGPoint {
        selfPoint
    }

    private func curveControl(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2 + (a.y - b.y) * 0.12,
                y: (a.y + b.y) / 2 + (b.x - a.x) * 0.12)
    }

    // MARK: 节点

    private func nodeButton(_ node: LPNavNodeSpec) -> some View {
        let selected = node.id == current && !node.isImport
        let nodeHovering = hovering == node.id
        let justArrived = arrived == node.id
        return Button {
            if node.isImport {
                app.beginImport()
            } else {
                if node.id != current { arrived = node.id }
                app.dispatch(.section(node.id))
            }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    if selected || justArrived {
                        Circle()
                            .fill(LP.accent.opacity(0.16))
                            .frame(width: 24, height: 24)
                    }
                    Circle()
                        .fill(nodeFill(node, selected: selected))
                        .frame(width: node.kind == .root ? 12 : 9,
                               height: node.kind == .root ? 12 : 9)
                    if node.kind == .root {
                        Circle()
                            .strokeBorder(LP.text.opacity(0.35), lineWidth: 1)
                            .frame(width: 18, height: 18)
                    }
                }
                .scaleEffect(justArrived && !reduceMotion ? 1.15 : 1)
                .frame(width: 24, height: 24)
                Label(node.label, systemImage: node.icon)
                    .font(.system(size: node.kind == .verb ? 12 : 11,
                                  weight: selected ? .semibold : .medium))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(nodeLabelColor(node, selected: selected, hovering: nodeHovering))
                    .lineLimit(1)
                    .frame(maxWidth: LPNavGraphSpec.canvasWidth - 8)
            }
            .padding(4)
            .contentShape(Rectangle())
            .opacity(node.isImport && !hoveredImport ? 0.85 : 1)
        }
        .buttonStyle(.plain)
        // 根节点的标签挪到圆点右侧：连线都从它向下发散，标签压在正下方会被亮线穿过。
        .offset(x: node.kind == .root ? 26 : 0, y: node.kind == .root ? -10 : 0)
        .onHover { entering in
            LPMotion.run(LPMotion.quick) {
                if entering { hovering = node.id; if node.isImport { hoveredImport = true } }
                else {
                    if hovering == node.id { hovering = nil }
                    if node.isImport { hoveredImport = false }
                }
            }
        }
        .lpAnimation(LPMotion.leap, value: justArrived)
        .help(node.label)
        .accessibilityLabel(node.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func nodeFill(_ node: LPNavNodeSpec, selected: Bool) -> Color {
        // 根节点 = 这台 Mac：它的颜色就是引擎状态（运行绿 / 出错红 / 停止灰）。
        if node.kind == .root {
            switch engine.state {
            case .running: return LP.mint
            case .starting: return LP.amber
            case .failed: return LP.danger
            case .stopped: return LP.text.opacity(0.55)
            }
        }
        if selected { return LP.accent }
        return LP.text.opacity(0.55)
    }

    private func nodeLabelColor(_ node: LPNavNodeSpec, selected: Bool, hovering: Bool) -> Color {
        if selected { return LP.text }
        if hovering { return LP.text }
        return LP.textSecondary
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

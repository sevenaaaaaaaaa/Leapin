import SwiftUI
import AppKit
import LeapinCore
import LeapinRuntime

// MARK: - v6 §4.4 · Spine Shelf（macOS）
//
// 资源页的默认视图：配置与订阅以竖排书脊立在架上。
// 点一条抽出详情卡（封面＋目录＋体检），把一条脊拖到另一条上做比较。
// 判断全部在 SpineModel.swift；这里只做翻译与绘制。

// MARK: Profile → 书脊

enum LPSpineBridge {
    /// 规则里可以用、但既不是出口也不是策略组名字的缺省关键字。
    private static let builtinPolicies: Set<String> = ["direct", "reject", "reject-drop", "pass", "match"]

    static func snapshot(meta: ProfileMeta, profile: Profile) -> LPSpineSnapshot {
        let outbounds = profile.outbounds.map(\.name)
        let groupNames = profile.groups.map(\.name)

        var known = builtinPolicies
        for name in outbounds + groupNames { known.insert(name.lowercased()) }

        // 规则行整份保留：差异比较要能说出「哪一条只在左边」。
        // 10 份 × 3000 条约 3 万条短字符串，桌面端可接受；不截断是因为截断后的差异会骗人。
        var dangling: [String] = []
        var seenDangling: Set<String> = []
        var tally: [String: Int] = [:]
        var lines: [String] = []
        lines.reserveCapacity(profile.rules.count)

        for rule in profile.rules {
            tally[rule.kind.rawValue, default: 0] += 1
            lines.append(LPSpineRuleLine.display(kind: rule.kind.rawValue.uppercased(),
                                                 value: rule.value,
                                                 policy: rule.policy))
            let policy = rule.policy.lowercased()
            if !known.contains(policy), seenDangling.insert(policy).inserted {
                dangling.append(rule.policy)
            }
        }

        let emptyGroups = profile.groups
            .filter { $0.proxies.isEmpty && $0.use.isEmpty && $0.filter == nil && !$0.includeAll }
            .map(\.name)

        let tallies = tally
            .sorted { a, b in a.value == b.value ? a.key < b.key : a.value > b.value }
            .map { LPSpineTally(name: $0.key, count: $0.value) }

        return LPSpineSnapshot(
            id: meta.id,
            name: meta.name,
            source: LPSpineSource.label(from: profile.sourcePath),
            updatedAt: meta.updatedAt,
            ruleCount: profile.rules.count,
            ruleLines: lines,
            tallies: tallies,
            groups: profile.groups.map {
                LPSpineGroup(name: $0.name,
                             type: $0.rawType ?? $0.type.rawValue,
                             memberCount: $0.proxies.count)
            },
            outbounds: outbounds,
            rewriteCount: profile.rewrites.count,
            scriptNames: profile.scripts.map(\.name),
            adblockEnabled: profile.adblock.enabled,
            adblockListCount: profile.adblock.blockLists.count,
            dnsPort: Int(profile.dns.listenPort),
            dnsUpstreamCount: profile.dns.upstreams.count,
            danglingPolicies: dangling,
            emptyGroups: emptyGroups
        )
    }
}

// MARK: 书架

struct LPSpineShelfActions {
    var pull: (LPSpineSnapshot) -> Void
    var compare: (LPSpineSnapshot, LPSpineSnapshot) -> Void
    var activate: (LPSpineSnapshot) -> Void
    var export: (LPSpineSnapshot, ProfileFormat) -> Void
    var delete: (LPSpineSnapshot) -> Void
    var importProfile: () -> Void
}

private enum LPSpineSpace {
    static let name = "lp.spine.shelf"
}

struct LPSpineShelf: View {
    var spines: [LPSpineSnapshot]
    var activeID: UUID?
    var actions: LPSpineShelfActions

    @State private var draggingID: UUID?
    @State private var translation: CGSize = .zero
    @State private var dropTargetID: UUID?
    @State private var frames: [UUID: CGRect] = [:]
    @State private var compareSource: LPSpineSnapshot?

    var body: some View {
        Group {
            if spines.isEmpty {
                emptyShelf
            } else {
                shelf
            }
        }
        .sheet(item: $compareSource) { source in
            LPSpineComparePicker(
                source: source,
                others: spines.filter { $0.id != source.id },
                onClose: { compareSource = nil },
                onPick: { target in
                    compareSource = nil
                    actions.compare(source, target)
                }
            )
        }
    }

    private var shelf: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: spines.count > 6) {
                HStack(alignment: .bottom, spacing: LPSpineShelfLayout.gap) {
                    ForEach(spines) { spine in
                        LPSpineView(
                            spine: spine,
                            active: spine.id == activeID,
                            dragging: draggingID == spine.id,
                            dropTarget: dropTargetID == spine.id,
                            translation: draggingID == spine.id ? translation : .zero,
                            onTap: { actions.pull(spine) },
                            onMore: { compareSource = spine },
                            actions: actions
                        )
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: LPSpineFrameKey.self,
                                    value: [spine.id: proxy.frame(in: .named(LPSpineSpace.name))]
                                )
                            }
                        )
                    }
                }
                .padding(.horizontal, 2)
                .padding(.top, 6)
                .padding(.bottom, 10)
                .coordinateSpace(name: LPSpineSpace.name)
                .onPreferenceChange(LPSpineFrameKey.self) { frames = $0 }
                .highPriorityGesture(shelfDrag)
            }
            board
        }
    }

    /// 架板：一条实线加一条浅线，书脊才像「立在」架上而不是浮着。
    private var board: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(LP.strokeStrong)
                .frame(height: 1)
            Rectangle()
                .fill(LP.stroke)
                .frame(height: 2)
                .padding(.top, 1)
        }
    }

    private var shelfDrag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(LPSpineSpace.name))
            .onChanged { value in
                if draggingID == nil {
                    draggingID = spines.first { frames[$0.id]?.contains(value.startLocation) == true }?.id
                    if draggingID != nil { LPHaptic.soft() }
                }
                guard draggingID != nil else { return }
                translation = value.translation
                let next = target(at: value.location, excluding: draggingID)
                if next != dropTargetID {
                    dropTargetID = next
                    if next != nil { LPHaptic.select() }
                }
            }
            .onEnded { value in
                let from = draggingID
                let to = target(at: value.location, excluding: from)
                draggingID = nil
                translation = .zero
                dropTargetID = nil
                guard let from,
                      let left = spines.first(where: { $0.id == from }),
                      let to,
                      let right = spines.first(where: { $0.id == to }) else { return }
                LPHaptic.success()
                actions.compare(left, right)
            }
    }

    /// 命中的判断在 LPSpineHitTest（可测），这里只把当前书架交给它。
    private func target(at point: CGPoint, excluding id: UUID?) -> UUID? {
        LPSpineHitTest.target(point: point, frames: frames, excluding: id)
    }

    private var emptyShelf: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: LPSpineShelfLayout.gap) {
                VStack(spacing: 8) {
                    Text("空")
                        .font(LPFont.mono(13))
                        .foregroundStyle(LP.textTertiary)
                    Rectangle()
                        .fill(LP.textTertiary.opacity(0.30))
                        .frame(width: 1, height: 120)
                }
                .frame(width: 48, height: LPSpineShelfLayout.height)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(LP.strokeStrong)
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 10) {
                    Text("书架还是空的")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LP.text)
                    Text("导入 Clash YAML、Surge conf、之前导出的 Leapin JSON，或粘贴订阅链接。导入后先检查，再启用。")
                        .font(.system(size: 13))
                        .foregroundStyle(LP.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 360, alignment: .leading)
                    Button("导入第一份配置") { actions.importProfile() }
                        .buttonStyle(LPPrimaryButtonStyle())
                        .accessibilityLabel("导入第一份配置")
                }
                .padding(.bottom, 42)

                Spacer(minLength: 0)
            }
            .padding(.bottom, 10)
            board
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LPSpineFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: 一条书脊

struct LPSpineView: View {
    var spine: LPSpineSnapshot
    var active: Bool
    var dragging: Bool
    var dropTarget: Bool
    var translation: CGSize
    var onTap: () -> Void
    var onMore: () -> Void
    var actions: LPSpineShelfActions

    @State private var hovering = false

    private var health: LPSpineHealth { LPSpineHealth.evaluate(spine) }
    private var width: CGFloat { LPSpineShelfLayout.width(for: spine) }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(levelColor(health.level))
                        .frame(width: 4, height: 4)
                    Spacer(minLength: 0)
                    Text("\(spine.ruleCount)")
                        .font(LPFont.mono(9.5, weight: .medium))
                        .foregroundStyle(active ? LP.accent : LP.textTertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 7)

                vertical(spine.name,
                         size: 12,
                         weight: active ? .semibold : .medium,
                         mono: false,
                         color: LP.text.opacity(active ? 1 : 0.92),
                         length: 140)

                Spacer(minLength: 0)

                vertical(spine.source,
                         size: 9,
                         weight: .regular,
                         mono: true,
                         color: LP.textTertiary,
                         length: 96)
                    .padding(.bottom, 9)
            }
            .padding(.top, 9)
            .frame(width: width, height: LPSpineShelfLayout.height)
            .background(LP.paper)
            .overlay(alignment: .leading) {
                // 「墨条」要跟着纸走：深色模式下纸是黑的，墨必须是浅的。
                Rectangle()
                    .fill(active ? LP.accent : LP.text.opacity(0.55))
                    .frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(dropTarget ? LP.accent : ((hovering || dragging) ? LP.strokeStrong : LP.stroke),
                                  lineWidth: dropTarget ? 1.5 : 1)
            )
            .shadow(color: .black.opacity(dragging ? 0.20 : (hovering ? 0.12 : 0.06)),
                    radius: dragging ? 10 : (hovering ? 6 : 3),
                    x: 0, y: dragging ? 4 : 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(translation)
        .scaleEffect(dragging ? 1.02 : 1)
        .zIndex(dragging ? 1 : 0)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: dropTarget)
        .help("点按抽出详情；拖到另一条书脊上比较")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("配置 \(spine.name)，\(spine.ruleCount) 条规则，来源 \(spine.source)")
        .accessibilityValue("\(health.label)，\(active ? "使用中" : "未启用")")
        .accessibilityHint("点按抽出详情；上下文菜单可以比较")
        .contextMenu {
            Button("抽出详情") { actions.pull(spine) }
            Button("比较…") { onMore() }
            Divider()
            Button("设为当前") { actions.activate(spine) }
                .disabled(active)
            Menu("导出…") {
                ForEach(ProfileFormat.allCases, id: \.self) { format in
                    Button(format.rawValue) { actions.export(spine, format) }
                }
            }
            Divider()
            Button("删除…", role: .destructive) { actions.delete(spine) }
        }
    }

    /// 竖排的一行字。中文名「字正立、从上往下」，文件名与西文整行转 90°——
    /// 判断在 LPSpineVertical，这里只画。
    @ViewBuilder
    private func vertical(_ text: String, size: CGFloat, weight: Font.Weight, mono: Bool,
                          color: Color, length: CGFloat) -> some View {
        switch LPSpineVertical.mode(for: text) {
        case .stacked:
            let capacity = LPSpineVertical.capacity(length: length, size: size)
            let shown = LPSpineVertical.stacked(text, capacity: capacity)
            VStack(spacing: 1) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, character in
                    Text(String(character))
                        .font(.system(size: size, weight: weight))
                        .foregroundStyle(color)
                }
            }
            .frame(width: 14, height: length, alignment: .top)
            .accessibilityHidden(true)
        case .rotated:
            Text(text)
                .font(.system(size: size, weight: weight, design: mono ? .monospaced : .default))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: length, height: 14, alignment: .leading)
                .rotationEffect(.degrees(90))
                .frame(width: 14, height: length)
                .accessibilityHidden(true)
        }
    }

    private func levelColor(_ level: LPSpineCheckLevel) -> Color {
        switch level {
        case .ok: return LP.mint
        case .warn: return LP.amber
        case .fail: return LP.danger
        }
    }
}

// MARK: 详情卡

struct LPSpineDetailSheet: View {
    var spine: LPSpineSnapshot
    var isActive: Bool
    var busy: Bool
    var onActivate: () -> Void
    var onExport: (ProfileFormat) -> Void
    var onDelete: () -> Void
    var onClose: () -> Void

    private var health: LPSpineHealth { LPSpineHealth.evaluate(spine) }

    var body: some View {
        VStack(spacing: 0) {
            header
            LPDivider()
            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    cover
                    VStack(alignment: .leading, spacing: 20) {
                        // 体检在前：开门就要看见「启用前得先修什么」，目录是背景资料。
                        healthPanel
                        catalog
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(24)
            }
            .frame(maxHeight: .infinity)
            LPDivider()
            actions
        }
        .frame(width: 800, height: 720)
        .foregroundStyle(LP.text)
        .background(LP.panel)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                LPEyebrow("抽出的书脊")
                Text(spine.name)
                    .font(LPFont.display(22, weight: .semibold))
                    .lineLimit(1)
                Text("\(spine.source) · \(Fmt.day(spine.updatedAt)) · \(spine.ruleCount) 条规则")
                    .font(LPFont.mono(11))
                    .foregroundStyle(LP.textTertiary)
            }
            Spacer(minLength: 8)
            Button("关闭") { onClose() }
                .buttonStyle(LPGhostButtonStyle())
                .accessibilityLabel("关闭详情")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var cover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(spine.name)
                .font(LPFont.display(19, weight: .semibold))
                .foregroundStyle(LP.text)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Text(spine.source)
                .font(LPFont.mono(10))
                .foregroundStyle(LP.textTertiary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(spine.ruleCount)")
                    .font(LPFont.num(24, weight: .semibold))
                    .foregroundStyle(LP.text)
                Text("条规则")
                    .font(.system(size: 11))
                    .foregroundStyle(LP.textTertiary)
            }
            .padding(.top, 6)
        }
        .padding(16)
        .frame(width: 200, height: 260, alignment: .topLeading)
        .background(LP.paper)
        .overlay(alignment: .leading) {
            Rectangle().fill(isActive ? LP.accent : LP.text.opacity(0.55)).frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(LP.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("封面：\(spine.name)，\(spine.ruleCount) 条规则，来源 \(spine.source)")
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "目录", subtitle: "这份配置里有什么", icon: "list.bullet.indent")
            if spine.tallies.isEmpty {
                Text("没有规则，目录是空的。")
                    .font(.system(size: 13))
                    .foregroundStyle(LP.textTertiary)
            } else {
                let maxCount = spine.tallies.map(\.count).max() ?? 1
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(spine.tallies.prefix(6)) { tally in
                        HStack(spacing: 10) {
                            Text(tally.name.uppercased())
                                .font(LPFont.mono(10.5))
                                .foregroundStyle(LP.textSecondary)
                                .frame(width: 112, alignment: .leading)
                                .lineLimit(1)
                            ZStack(alignment: .leading) {
                                Capsule().fill(LP.line).frame(width: 150, height: 4)
                                Capsule().fill(LP.text.opacity(0.55))
                                    .frame(width: max(2, 150 * CGFloat(tally.count) / CGFloat(maxCount)), height: 4)
                            }
                            Text("\(tally.count)")
                                .font(LPFont.mono(10.5))
                                .foregroundStyle(LP.textTertiary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(tally.name) \(tally.count) 条")
                    }
                    if spine.tallies.count > 6 {
                        Text("另有 \(spine.tallies.count - 6) 种类型")
                            .font(.system(size: 11))
                            .foregroundStyle(LP.textTertiary)
                    }
                }
            }

            LPDivider()

            keyValue("策略组", groupSummary)
            keyValue("出口", outboundSummary)
            keyValue("重写 / 脚本", "\(spine.rewriteCount) 行重写 · \(spine.scriptNames.count) 个脚本")
            keyValue("DNS", "端口 \(spine.dnsPort) · \(spine.dnsUpstreamCount) 个上游")
        }
    }

    private var groupSummary: String {
        if spine.groups.isEmpty { return "无，规则直接指向出口" }
        let head = spine.groups.prefix(4)
            .map { "\($0.name)（\($0.type) · \($0.memberCount)）" }
            .joined(separator: "、")
        return spine.groups.count > 4 ? "\(head) 等 \(spine.groups.count) 个" : head
    }

    private var outboundSummary: String {
        if spine.outbounds.isEmpty { return "无" }
        let head = spine.outbounds.prefix(5).joined(separator: "、")
        return spine.outbounds.count > 5 ? "\(head) 等 \(spine.outbounds.count) 个" : head
    }

    private func keyValue(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(LPFont.mono(11))
                .foregroundStyle(LP.textTertiary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.system(size: 12.5))
                .foregroundStyle(LP.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var healthPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SectionHeader(title: "体检结果", subtitle: "启用前先看这一栏", icon: "stethoscope")
                Spacer(minLength: 0)
                Badge(text: health.label, color: badgeColor(health.level))
            }
            VStack(spacing: 0) {
                ForEach(Array(health.checks.enumerated()), id: \.element.id) { index, check in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(badgeColor(check.level))
                            .frame(width: 5, height: 5)
                            .offset(y: -2)
                        Text(check.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LP.text)
                            .frame(width: 58, alignment: .leading)
                        Text(check.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(check.level == .ok ? LP.textTertiary : LP.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(check.name)：\(check.detail)")
                    if index < health.checks.count - 1 { LPDivider() }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if isActive {
                Badge(text: "使用中", color: LP.mint)
            } else {
                Button {
                    onActivate()
                } label: {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("设为当前")
                    }
                }
                .buttonStyle(LPPrimaryButtonStyle())
                .disabled(busy)
                .accessibilityLabel("设为当前配置")
            }

            Menu {
                ForEach(ProfileFormat.allCases, id: \.self) { format in
                    Button(format.rawValue) { onExport(format) }
                }
            } label: {
                Text("导出")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LP.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .lpPill()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("导出这份配置：Clash / Surge / JSON / 拦截表")
            .accessibilityLabel("导出配置")

            Spacer(minLength: 0)

            Button("删除…") { onDelete() }
                .buttonStyle(LPGhostButtonStyle())
                .disabled(isActive)
                .help(isActive ? "使用中的配置不能删除，先切换到别的配置" : "删除这份配置")
                .accessibilityLabel("删除配置 \(spine.name)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func badgeColor(_ level: LPSpineCheckLevel) -> Color {
        switch level {
        case .ok: return LP.mint
        case .warn: return LP.amber
        case .fail: return LP.danger
        }
    }
}

// MARK: 比较

struct LPSpineCompareSheet: View {
    var comparison: LPSpineComparison
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                LPEyebrow("两本书脊的差异")
                Text(comparison.headline)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LP.text)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    tag("左：\(comparison.leftName) · \(comparison.leftRuleCount) 条")
                    tag("右：\(comparison.rightName) · \(comparison.rightRuleCount) 条")
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            LPDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    differenceBlock("只有左边有（\(comparison.onlyLeftRules.count)）",
                                    comparison.onlyLeftRules,
                                    empty: "左边没有独有规则")
                    differenceBlock("只有右边有（\(comparison.onlyRightRules.count)）",
                                    comparison.onlyRightRules,
                                    empty: "右边没有独有规则")
                    HStack(alignment: .top, spacing: 24) {
                        nameBlock("策略组只在左", comparison.leftOnlyGroups)
                        nameBlock("策略组只在右", comparison.rightOnlyGroups)
                    }
                    HStack(alignment: .top, spacing: 24) {
                        nameBlock("出口只在左", comparison.leftOnlyOutbounds)
                        nameBlock("出口只在右", comparison.rightOnlyOutbounds)
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: .infinity)
            LPDivider()
            HStack {
                Spacer(minLength: 0)
                Button("关闭") { onClose() }
                    .buttonStyle(LPPrimaryButtonStyle())
                    .accessibilityLabel("关闭比较")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 640, height: 660)
        .foregroundStyle(LP.text)
        .background(LP.panel)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(LPFont.mono(10.5))
            .foregroundStyle(LP.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .lpPill()
    }

    private func differenceBlock(_ title: String, _ lines: [String], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LP.textSecondary)
            if lines.isEmpty {
                Text(empty)
                    .font(.system(size: 12))
                    .foregroundStyle(LP.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.prefix(6).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(LPFont.mono(10.5))
                            .foregroundStyle(LP.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if lines.count > 6 {
                        Text("还有 \(lines.count - 6) 条")
                            .font(.system(size: 11))
                            .foregroundStyle(LP.textTertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func nameBlock(_ title: String, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LP.textSecondary)
            if names.isEmpty {
                Text("没有")
                    .font(.system(size: 12))
                    .foregroundStyle(LP.textTertiary)
            } else {
                Text(names.joined(separator: "、"))
                    .font(.system(size: 12))
                    .foregroundStyle(LP.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 拖动比较的无障碍等价物：从上下文菜单选另一条书脊。
struct LPSpineComparePicker: View {
    var source: LPSpineSnapshot
    var others: [LPSpineSnapshot]
    var onClose: () -> Void
    var onPick: (LPSpineSnapshot) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("和哪条书脊比较？")
                    .font(LPFont.display(18, weight: .semibold))
                    .foregroundStyle(LP.text)
                Text("基准是「\(source.name)」。选中的那条作为右边，结论按「右边比左边」来写。")
                    .font(.system(size: 12))
                    .foregroundStyle(LP.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            LPDivider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(others) { spine in
                        Button {
                            onPick(spine)
                        } label: {
                            HStack(spacing: 10) {
                                Text(spine.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(LP.text)
                                    .lineLimit(1)
                                Text("\(spine.ruleCount) 条")
                                    .font(LPFont.mono(10.5))
                                    .foregroundStyle(LP.textTertiary)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(LP.textTertiary)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("与 \(spine.name) 比较")
                        LPDivider()
                    }
                }
            }
            HStack {
                Spacer(minLength: 0)
                Button("取消") { onClose() }
                    .buttonStyle(LPGhostButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460, height: 420)
        .foregroundStyle(LP.text)
        .background(LP.panel)
    }
}

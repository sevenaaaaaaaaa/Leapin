import SwiftUI
import AppKit

// MARK: - Rows

/// A clickable list row with hover, pressed, selected and focus feedback.
/// Use this instead of `.onTapGesture` so rows stay keyboard reachable.
struct LPRow<Content: View>: View {
    var selected: Bool = false
    var accessibilityText: String? = nil
    var action: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            content()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? LP.selectionFill : (hovering ? LP.hover : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? LP.lineStrong : Color.clear, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            if selected {
                Capsule().fill(LP.accent).frame(width: 2, height: 15).padding(.leading, 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .lpAnimation(LPMotion.press, value: selected)
        .lpAnimation(LPMotion.press, value: hovering)
        .accessibilityLabel(accessibilityText ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Search

/// A filter field: 13pt, 28pt tall, paper and a hairline. A control, so it rounds
/// at the control radius like every other control — not a glass capsule.
struct LPSearchField: View {
    @Binding var text: String
    var placeholder: String
    var width: CGFloat = 320
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(focus.wrappedValue ? LP.accent : LP.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focus)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(LP.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous)
                .fill(LP.sheet)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous)
                .strokeBorder(focus.wrappedValue ? LP.accent.opacity(0.85) : LP.lineStrong,
                              lineWidth: focus.wrappedValue ? 1.5 : 1)
        )
        .lpAnimation(LPMotion.quick, value: focus.wrappedValue)
        .frame(maxWidth: width)
        .accessibilityLabel(placeholder)
    }
}

/// 「问一条路」：这一页的主输入，不是过滤器。
///
/// 比搜索框大一号、重一档，因为它问的是这一页自己的问题——「这个域名走哪」。
/// 回车即问；与 `LPSearchField` 的区别在字重和高度，不在结构。
struct LPAskField: View {
    @Binding var text: String
    var placeholder: String
    var icon: String = "arrow.triangle.branch"
    var focus: FocusState<Bool>.Binding
    var onSubmit: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(focus.wrappedValue ? LP.accent : LP.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .focused(focus)
                .onSubmit { onSubmit(text) }
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(LP.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除")
            }
            LPKeyCap(keys: "↩")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous)
                .fill(LP.sheet)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous)
                .strokeBorder(focus.wrappedValue ? LP.accent : LP.lineStrong,
                              lineWidth: focus.wrappedValue ? 1.5 : 1)
        )
        .lpAnimation(LPMotion.quick, value: focus.wrappedValue)
        .accessibilityLabel(placeholder)
    }
}

// MARK: - Chips

/// Filter chip with optional count. Selected state is announced to VoiceOver.
///
/// A selected chip is ink on paper — the same "you are here" as a selected sidebar
/// row. It is never a pale vermilion wash: that reads as a warning, and vermilion is
/// reserved for the one primary action on a screen.
struct LPChip: View {
    var title: String
    var count: Int? = nil
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let count {
                    Text("\(count)")
                        .font(LPFont.num(11, weight: .medium))
                        .opacity(0.72)
                }
            }
            .foregroundStyle(selected ? LP.paper : LP.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
        }
        .buttonStyle(LPChipButtonStyle(filled: selected))
        .fixedSize()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct LPChipButtonStyle: ButtonStyle {
    var filled: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        LPButtonFocusRing(shape: Capsule(style: .continuous)) {
            configuration.label
                .background(
                    Capsule(style: .continuous)
                        .fill(filled ? LP.text
                               : (configuration.isPressed ? LP.text.opacity(0.10)
                                  : (hovering ? LP.hover : Color.clear)))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(filled ? Color.clear : LP.lineStrong, lineWidth: 1)
                )
                .contentShape(Capsule(style: .continuous))
                .opacity(configuration.isPressed ? 0.82 : 1)
        }
        .onHover { hovering = $0 }
        .lpAnimation(LPMotion.press, value: hovering)
    }
}

// MARK: - Segmented picker

/// The paper stand-in for `.pickerStyle(.segmented)`. The system control is grey
/// AppKit; next to warm paper and vermilion it reads as a control from another app.
struct LPSegmentedPicker<Value: Hashable>: View {
    private let options: [(value: Value, title: String)]
    @Binding private var selection: Value
    @Namespace private var selectionSpace

    init(_ options: [(Value, String)], selection: Binding<Value>) {
        self.options = options
        _selection = selection
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                segment(option.value, title: option.title)
            }
        }
        .padding(2)
        .background(
            Capsule(style: .continuous)
                .fill(LP.text.opacity(0.07))
        )
    }

    private func segment(_ value: Value, title: String) -> some View {
        let on = value == selection
        return Button {
            LPMotion.run(LPMotion.standard) { selection = value }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? LP.text : LP.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background {
                    if on {
                        Capsule(style: .continuous)
                            .fill(LP.sheetRaised)
                            .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                            .matchedGeometryEffect(id: "selection", in: selectionSpace)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Header tabs

/// One tab in the shell header.
struct LPTab: Identifiable, Equatable {
    var id: String
    var title: String
}

/// What the current page hands the shell: its tabs, which one is on, and how to switch.
/// The closure is not part of equality — it only writes the page's own state.
struct LPHeaderTabs: Equatable {
    /// Which verb page these tabs belong to.
    var owner: String
    /// Which *instance* of that page registered them. `why` / `activity` / `diagnostics`
    /// are three instances of one page, and so are the two tabs of 走哪: the instance is
    /// what tells the outgoing one from the incoming one. Not part of equality.
    var instance: UUID = UUID()
    var items: [LPTab]
    var selected: String
    var onSelect: (String) -> Void

    static func == (lhs: LPHeaderTabs, rhs: LPHeaderTabs) -> Bool {
        lhs.owner == rhs.owner && lhs.items == rhs.items && lhs.selected == rhs.selected
    }
}

/// Tabs live in the header, not under it. Every verb page therefore starts its
/// content at the same row, and a tab can never be mistaken for a filter chip.
struct LPTabBar: View {
    var items: [LPTab]
    var selected: String
    /// Distance from the text box's bottom edge to the header's bottom rule, so the
    /// underline lands on that rule however tall the header is.
    var underlineDrop: CGFloat = 0
    /// 页头坐在墨色空间上：字换成墨上的白，悬停底色换成一层薄白。
    var onInk = false
    var onSelect: (String) -> Void

    @State private var hovered: String?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                tab(item)
            }
        }
    }

    private func tab(_ item: LPTab) -> some View {
        let on = item.id == selected
        let hovering = hovered == item.id
        let strong: Color = onInk ? LP.onInk : LP.text
        let soft: Color = onInk ? LP.onInkSecondary : LP.textSecondary
        let hoverFill: Color = onInk ? Color.white.opacity(0.08) : LP.hover
        let underline: Color = onInk ? LP.accentOnInk : LP.accent
        return Button {
            onSelect(item.id)
        } label: {
            // The underline overlays the text's own box, so it is exactly as wide as
            // the label. A bare Rectangle would take the whole proposed width, which
            // is how two tabs once split the window in half between them.
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on || hovering ? strong : soft)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(height: LPShell.titleLine)
                .background(
                    RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous)
                        .fill(on || !hovering ? Color.clear : hoverFill)
                )
                .contentShape(Rectangle())
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(underline)
                        .frame(height: 2)
                        .offset(y: underlineDrop)
                        .opacity(on ? 1 : 0)
                }
        }
        .buttonStyle(.plain)
        .onHover { value in
            LPMotion.run(LPMotion.quick) { hovered = value ? item.id : nil }
        }
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct LPHeaderTabsModifier: ViewModifier {
    @EnvironmentObject private var app: AppModel
    let tabs: LPHeaderTabs
    /// 这一个页面实例的身份证。
    ///
    /// 换页时旧页的 `onDisappear` 晚于新页的 `onAppear`。同一个动词页的不同 tab
    /// （为什么的 why / activity / diagnostics）是三个实例、同一个 owner：旧实例离场时
    /// 如果按 owner 清，清掉的是新实例刚登记的 tab——页头的 tab 就凭空消失了。
    @State private var instance = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { publish() }
            .onChange(of: tabs.selected) { _, _ in publish() }
            .onChange(of: tabs.items) { _, _ in publish() }
            .onDisappear {
                if app.headerTabs?.instance == instance { app.headerTabs = nil }
            }
    }

    private func publish() {
        var next = tabs
        next.instance = instance
        app.headerTabs = next
    }
}

extension View {
    /// Declare the tabs the shell header shows while this page is on screen.
    func lpHeaderTabs(owner: String, items: [LPTab], selected: String,
                      onSelect: @escaping (String) -> Void) -> some View {
        modifier(LPHeaderTabsModifier(
            tabs: LPHeaderTabs(owner: owner, items: items, selected: selected, onSelect: onSelect)))
    }
}

// MARK: - Pop-up row

/// 菜单里的一项。
enum LPPopUpItem {
    /// 一行可点的。`selected` 画成系统菜单自己的对勾，所以永远和别的菜单项对得齐。
    case item(_ title: String, selected: Bool = false, enabled: Bool = true, action: () -> Void)
    /// 一行带子菜单的。
    case submenu(_ title: String, [LPPopUpItem])
    /// 一行只作说明、不可点的。
    case note(_ text: String)
    case separator
}

/// 把 `[LPPopUpItem]` 变成一个 AppKit 菜单，并在给定的锚点下方弹出。
///
/// 为什么不直接用 `Menu`：它的 `.borderlessButton` 样式只肯把标签压成「图标 + 第一段
/// 文字」当标题，一行里的当前值于是被挤没；带边框的样式又是一枚系统灰按钮。直接弹
/// `NSMenu` 在任何窗口里都成立——包括菜单栏面板——嵌套子菜单和键盘操作也照常。
@MainActor
enum LPPopUpMenu {
    /// `autoDismiss` 只给离屏快照用：菜单是模态追踪的，没人来点就永远不收；到点自己取消追踪。
    /// 返回追踪持续了多久——快照据此确认菜单真的弹出过，而不是一调用就返回。
    @discardableResult
    static func show(_ items: [LPPopUpItem], below anchor: NSView,
                     autoDismiss: TimeInterval? = nil) -> TimeInterval {
        let menu = NSMenu()
        menu.items = items.map(make)
        if let autoDismiss {
            let timer = Timer(timeInterval: autoDismiss, target: LPPopUpTarget.shared,
                              selector: #selector(LPPopUpTarget.dismiss(_:)), userInfo: menu, repeats: false)
            // 菜单追踪期间主运行循环跑在 eventTracking 模式：定时器必须登记在这个模式里才会响。
            RunLoop.main.add(timer, forMode: .eventTracking)
        }
        // 弹出点是菜单左上角在锚点坐标系里的位置：行的左下角，于是菜单从这一行下面展开。
        // 靠近屏幕下沿时 AppKit 会自己把它翻到上面去。
        anchor.layoutSubtreeIfNeeded()
        let started = Date()
        menu.popUp(positioning: nil, at: CGPoint(x: 8, y: -2), in: anchor)
        return Date().timeIntervalSince(started)
    }

    private static func make(_ item: LPPopUpItem) -> NSMenuItem {
        switch item {
        case .item(let title, let selected, let enabled, let action):
            let entry = NSMenuItem(title: title, action: #selector(LPPopUpTarget.perform(_:)), keyEquivalent: "")
            entry.target = LPPopUpTarget.shared
            entry.representedObject = LPPopUpAction(action)
            entry.state = selected ? .on : .off
            entry.isEnabled = enabled
            return entry
        case .submenu(let title, let items):
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            entry.submenu = NSMenu()
            entry.submenu?.items = items.map(make)
            return entry
        case .note(let text):
            let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            return entry
        case .separator:
            return .separator()
        }
    }
}

@MainActor
private final class LPPopUpTarget: NSObject {
    static let shared = LPPopUpTarget()

    @objc func perform(_ sender: NSMenuItem) {
        (sender.representedObject as? LPPopUpAction)?.run()
    }

    @objc func dismiss(_ timer: Timer) {
        (timer.userInfo as? NSMenu)?.cancelTracking()
    }
}

private final class LPPopUpAction {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

/// 一行「名字 + 当前值 + 下拉提示」，点开一个菜单。
struct LPPopUpRow: View {
    var title: String
    var value: String
    var enabled: Bool = true
    var help: String? = nil
    var menu: () -> [LPPopUpItem]

    @State private var hovering = false
    /// 行自己所在的那个 AppKit 视图：菜单要有个锚点才知道从哪里弹出。
    @State private var anchor: NSView?

    var body: some View {
        Button {
            guard let anchor else { return }
            LPPopUpMenu.show(menu(), below: anchor)
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(LP.textSecondary)
                    .frame(width: 30, alignment: .leading)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(enabled ? LP.text : LP.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(enabled ? LP.textTertiary : LP.textTertiary.opacity(0.5))
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering && enabled ? LP.hover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .lpAnimation(LPMotion.quick, value: hovering)
        .background(LPPopUpAnchor { anchor = $0 })
        .help(help ?? title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(value)")
        .accessibilityHint(enabled ? "点开选择" : "")
    }
}

private struct LPPopUpAnchor: NSViewRepresentable {
    let onReady: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // 布局之后才报：此刻拿到的是这一行真正的那个视图，不是下一帧重建出来的。
        DispatchQueue.main.async { onReady(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Key hints

struct LPKeyCap: View {
    var keys: String
    var body: some View {
        Text(keys)
            .font(LPFont.mono(11, weight: .medium))
            .foregroundStyle(LP.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                LP.text.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
    }
}

// MARK: - Progress

/// Thin determinate/indeterminate progress line used for long-running work.
struct LPProgressLine: View {
    var value: Double? = nil
    @State private var phase: CGFloat = -0.3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(LP.stroke.opacity(0.6))
                if let value {
                    Capsule().fill(LP.brand)
                        .frame(width: max(3, geo.size.width * min(max(value, 0), 1)))
                } else {
                    Capsule().fill(LP.brand)
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: geo.size.width * phase)
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                                phase = 1.1
                            }
                        }
                }
            }
        }
        .frame(height: 3)
        .clipShape(Capsule())
        .accessibilityLabel("进度")
    }
}

// MARK: - Empty state with a way out

struct LPEmptyState: View {
    var icon: String
    var title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(LP.textTertiary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LP.text)
            if let message {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(LP.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(LPGhostButtonStyle())
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(26)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Confirmation

extension View {
    /// Destructive actions always go through a visible confirmation.
    func lpConfirm(_ title: String,
                   message: String,
                   isPresented: Binding<Bool>,
                   confirmTitle: String = "确认",
                   destructive: Bool = true,
                   action: @escaping () -> Void) -> some View {
        confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            Button(confirmTitle, role: destructive ? .destructive : nil, action: action)
            Button("取消", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

// MARK: - Copy helper

enum LPClipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Brand mark

/// 品牌标记：墨底 + 两个纸色端点 + 中间一个朱红点，一条线穿过去。
/// 与 App 图标（`scripts/make-icon.py`）是同一个母题——「一条路」的图标形态。
struct LPMark: View {
    var size: CGFloat = 28

    var body: some View {
        let end = size * 0.072
        let middle = size * 0.054
        let line = max(1, size * 0.036)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(LP.ink)
            HStack(spacing: 0) {
                dot(end, LP.onInk)
                track(line)
                dot(middle, LP.accentOnInk)
                track(line)
                dot(end, LP.onInk)
            }
            .padding(.horizontal, size * 0.21)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func dot(_ radius: CGFloat, _ color: Color) -> some View {
        Circle().fill(color).frame(width: radius * 2, height: radius * 2)
    }

    private func track(_ height: CGFloat) -> some View {
        Rectangle()
            .fill(LP.onInk.opacity(0.32))
            .frame(height: height)
            .frame(maxWidth: .infinity)
    }
}

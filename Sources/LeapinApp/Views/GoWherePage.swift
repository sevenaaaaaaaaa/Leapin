import SwiftUI
import LeapinRuntime

/// 「走哪」动词页：总览 / 配置与订阅 两个 tab。
///
/// 总览 tab 现在就是现有的 `DashboardView`，配置 tab 是现有的 `ProfilesView`；
/// T-08 重写首屏（四入口 + 接管范围）时只换总览这一页，不动 tab 容器。
@MainActor
struct GoWherePage: View {

    enum Tab: String, CaseIterable, Identifiable {
        case overview, profiles

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "总览"
            case .profiles: return "配置与订阅"
            }
        }

        var icon: String {
            switch self {
            case .overview: return "gauge.with.dots.needle.67percent"
            case .profiles: return "doc.on.doc"
            }
        }
    }

    let initialTab: Tab

    @State private var tab: Tab

    init(initialTab: Tab = .overview) {
        self.initialTab = initialTab
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Rectangle().fill(LP.stroke).frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// v5 §6.3 与 §12 第 5 条：tab 是页头下方**左对齐的过滤条**，不是悬浮控件；
    /// 选中用 2px 朱红下划线，不用系统 segmented 的填充底。
    private var tabBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(WorkbenchVerb.goWhere.question)
                .font(LPType.body)
                .foregroundStyle(LP.textTertiary)
            HStack(spacing: 20) {
                ForEach(Tab.allCases) { item in
                    tabButton(item)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, LPSpace.page)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func tabButton(_ item: Tab) -> some View {
        let active = tab == item
        return Button {
            tab = item
        } label: {
            VStack(spacing: 6) {
                Text(item.title)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? LP.text : LP.textSecondary)
                Rectangle()
                    .fill(active ? LP.accent : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .overview: DashboardView()
        // 作为 tab 时不再画 ProfilesView 自己的页面大标题：页头已经写了「走哪」，
        // tab 也写了「配置与订阅」，第三遍就是重复。业务与动作全部保留。
        case .profiles: ProfilesView(showsPageHeader: false)
        }
    }
}

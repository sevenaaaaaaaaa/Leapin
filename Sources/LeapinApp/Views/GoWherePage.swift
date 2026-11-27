import SwiftUI
import LeapinRuntime

/// 「走哪」动词页：星图 / 配置与订阅 两个 tab。
///
/// tab 住在页头里（`lpHeaderTabs`）：这一页只剩内容——星图是 `LPNetworkMap`，
/// 配置 tab 是 `ProfilesView`。选中的是哪一个仍然是这里的状态，页头只负责画。
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

    @EnvironmentObject private var app: AppModel
    @State private var tab: Tab

    init(initialTab: Tab = .overview) {
        self.initialTab = initialTab
        _tab = State(initialValue: initialTab)
    }

    private static let owner = "gowhere"
    private static let tabs: [LPTab] = Tab.allCases.map { LPTab(id: $0.rawValue, title: $0.title) }

    var body: some View {
        Group {
            switch tab {
            case .overview:
                LPNetworkMap(scenes: app.scenes, bookmarks: app.bookmarks)
            // 作为 tab 时不画 ProfilesView 自己的页面大标题：页头已经写了「走哪」，
            // tab 也写了「配置与订阅」，第三遍就是重复。业务与动作全部保留。
            case .profiles: ProfilesView(showsPageHeader: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lpHeaderTabs(owner: Self.owner, items: Self.tabs, selected: tab.rawValue) { id in
            guard let next = Tab(rawValue: id) else { return }
            LPMotion.run(LPMotion.press) { tab = next }
        }
    }
}

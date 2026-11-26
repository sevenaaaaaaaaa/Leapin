import Foundation
import LeapinCore
import LeapinRuntime

/// 「改成什么」四类（重写 / Mock / 脚本 / 去广告）共用的一张列表，和唯一一个落地入口。
///
/// M2 的分工见 docs/tasks/product-v4.md T-09：四个 tab 不再各自拿一份列表、各自写一个
/// 保存函数。四类的行都从这里派生；四类的新增 / 修改 / 删除 / 启停都只从
/// 唯一的应用方法走一次。页面只剩两件事：渲染行，把 Outcome 交给 toast。
///
/// 为什么是 struct 而不是 ObservableObject：数据源只有 LeapinEngine.shared 的 profile
/// 一份，页面本来就在观察引擎；再存一份 @Published 副本就是第二个真相，两份列表会各自
/// 漂移。所以这里只有方法，没有状态。
@MainActor
struct RewriteDeck {

    /// Deck 没有状态，构造它不该要求主线程：视图的默认参数就在非隔离上下文里取值。
    nonisolated init() {}

    /// 四类。rawValue 用英文，标题才是产品话术；顺序就是页面 tab 的顺序。
    enum Kind: String, CaseIterable, Identifiable {
        case rewrite, mock, script, adblock

        var id: String { rawValue }

        var title: String {
            switch self {
            case .rewrite: return "重写"
            case .mock: return "Mock"
            case .script: return "脚本"
            case .adblock: return "去广告"
            }
        }

        var icon: String {
            switch self {
            case .rewrite: return "arrow.triangle.2.circlepath"
            case .mock: return "theatermasks"
            case .script: return "curlybraces"
            case .adblock: return "hand.raised"
            }
        }

        /// 空列表时的标题：写清这一类收什么，而不是留一块空白。
        var emptyTitle: String {
            switch self {
            case .rewrite: return "还没有重写规则"
            case .mock: return "还没有 Mock"
            case .script: return "还没有脚本"
            case .adblock: return "还没有自定义过滤来源"
            }
        }

        var emptyDetail: String {
            switch self {
            case .rewrite:
                return "可以改请求头、改响应正文，或把域名重定向出去。"
            case .mock:
                return "Mock 在连接源站之前就返回，请求仍然会出现在抓包里。"
            case .script:
                return "脚本存在配置里，这个 tab 先只看名字与启停状态；编辑器随后补。"
            case .adblock:
                return "默认使用内置 leapin-ads.txt（约 100 条），这里加额外的 ABP / hosts 来源。"
            }
        }

        /// 能直接用的示例行。空列表给的不是一块空白，而是几行可以照着改的例子；
        /// 编辑器里的「模板」也是这一份，两处不会各写一套语法。
        var samples: [(title: String, line: String)] {
            switch self {
            case .rewrite:
                return [
                    ("添加请求头", #"http-request ^https?://api\.example\.com/ header-add X-Debug 1"#),
                    ("改响应头", #"http-response ^https?://api\.example\.com/ header-replace Cache-Control no-store"#),
                    ("替换正文", #"http-response ^https?://api\.example\.com/user body-replace "\"vip\":false" "\"vip\":true""#),
                    ("重定向", #"http-request ^https?://old\.example\.com/ redirect https://new.example.com 302"#),
                ]
            case .mock:
                return [
                    ("Mock 接口", #"http-request ^https?://api\.example\.com/mock mock 200 application/json {"ok":true}"#),
                    ("重定向", #"http-request ^https?://old\.example\.com/ redirect https://new.example.com 302"#),
                ]
            case .script, .adblock:
                return []
            }
        }
    }

    /// 一条列表行。四类共用同一种行，tab 只决定取哪一类。
    struct Row: Identifiable, Equatable {
        /// 稳定键：重写 / Mock 是 rewrite-行号，脚本是脚本名，去广告是来源本身。
        var id: String
        var kind: Kind
        /// 主行：规则摘要 / 脚本名 / 来源。
        var title: String
        /// 次行：原始行 / 阶段 / 补充说明。
        var detail: String
        /// 小徽记：请求 / 响应。没有阶段概念的类目留空。
        var badge: String? = nil
        /// 脚本与开关类才看这个值。
        var enabled: Bool = true
        /// 解析失败的行照旧留在列表里，写清为什么会被跳过。
        var issue: String? = nil
        /// 在原数组里的位置：重写是 profile.rewrites 的行号，脚本是 profile.scripts 的下标。
        var index: Int? = nil
    }

    /// 一次落地请求。四类的每一种改动都是这里的一个 case——没有第二个保存 / 应用函数，
    /// 也就没有第二条生效路径可走偏。
    enum Change {
        /// 重写 tab：新增（index 为 nil）或原地修改一行。
        case rewrite(line: String, at: Int?)
        /// Mock tab：同一条 profile.rewrites，只是这一行的动作是 mock。
        case mock(line: String, at: Int?)
        /// 脚本 tab：只切启用状态，不碰脚本内容。
        ///
        /// 用下标而不是名字：`Row.id` 是位置（同名脚本也能各切各的），名字做键时
        /// 开关会落到第一条同名脚本上（T-14 评审 B1）。
        case script(index: Int, enabled: Bool)
        /// 去广告 tab：过滤来源的增删。
        case addBlockList(String)
        case removeBlockList(String)
        /// 去广告 tab：白名单整份替换。
        case allowList([String])
    }

    /// 落地结果。四类共用同一种结果，所以「生效了没 / 失败原因」在四个 tab 里读起来一样。
    struct Outcome {
        var message: String
        var kind: LPToastKind
        /// 可撤销的改动带上撤销动作；页面只负责把 actionTitle 与 action 一并交给 toast。
        var undo: (() -> Void)? = nil
    }

    private var engine: LeapinEngine { LeapinEngine.shared }

    // MARK: - 列表模型

    /// 某一类的行。四类共用 Row，所以页面可以只写一套渲染。
    func rows(for kind: Kind) -> [Row] {
        switch kind {
        case .rewrite: return rewriteRows(mock: false)
        case .mock: return rewriteRows(mock: true)
        case .script: return scriptRows
        case .adblock: return blockListRows
        }
    }

    func count(for kind: Kind) -> Int {
        rows(for: kind).count
    }

    /// 白名单是整段文本，不拆成行卡片：它按「整份替换」保存，逐行增删反而多一步。
    var allowList: [String] { engine.profile.adblock.allowList }

    var allowListText: String { allowList.joined(separator: "\n") }

    /// 过滤规则条数（内置表 + 用户来源），去广告 tab 的仪表条用。
    var adblockRuleCount: Int { engine.adblockRuleCount }

    private func rewriteRows(mock: Bool) -> [Row] {
        engine.profile.rewrites.enumerated().compactMap { index, line -> Row? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            switch RewriteEngine.parse(trimmed) {
            case .success(let rule):
                // 一条重写行只落在重写或 Mock 一个 tab 里；两处都出现会让人以为要改两次。
                guard (rule.action == .mock) == mock else { return nil }
                return Row(id: "rewrite-\(index)",
                           kind: mock ? .mock : .rewrite,
                           title: rule.summary,
                           detail: line,
                           badge: rule.phase == .request ? "请求" : "响应",
                           index: index)
            case .failure(let issue):
                // 解析不了的行留在重写 tab：它不是 Mock，而且用户需要看见它为什么被跳过。
                guard !mock else { return nil }
                return Row(id: "rewrite-\(index)",
                           kind: .rewrite,
                           title: "无法解析",
                           detail: line,
                           issue: issue.reason,
                           index: index)
            }
        }
    }

    private var scriptRows: [Row] {
        engine.profile.scripts.enumerated().map { index, record in
            // id 用位置而不是名字：配置允许两条同名脚本，名字做 id 会让 ForEach 只切第一个开关。
            Row(id: "script-\(index)",
                kind: .script,
                title: record.name,
                detail: Self.phaseTitle(record.phase),
                enabled: record.enabled,
                index: index)
        }
    }

    private var blockListRows: [Row] {
        engine.profile.adblock.blockLists.enumerated().map { index, source in
            Row(id: source,
                kind: .adblock,
                title: source,
                detail: source.hasPrefix("http") ? "远程来源 · 启动时下载" : "本地文件 · 启动时读取",
                index: index)
        }
    }

    private static func phaseTitle(_ phase: String) -> String {
        switch phase {
        case "http.request": return "请求阶段"
        case "http.response": return "响应阶段"
        case "dns": return "DNS 阶段"
        case "cron": return "定时"
        case "network.changed": return "网络变化"
        default: return phase
        }
    }

    // MARK: - 唯一落地入口

    /// 四类唯一的应用入口。任何一个 tab 的改动都必须从这里过，这样生效提示、被跳过的
    /// 原因和撤销动作只有一套；加第五类时也瞒不过这一处。
    @discardableResult
    func applyRewrite(_ change: Change) -> Outcome {
        switch change {
        case let .rewrite(line: line, at: index):
            return commitLine(line, at: index, label: "重写规则")
        case let .mock(line: line, at: index):
            return commitLine(line, at: index, label: "Mock")
        case let .script(index: index, enabled: enabled):
            return commitScript(index: index, enabled: enabled)
        case let .addBlockList(source: source):
            return commitAddBlockList(source)
        case let .removeBlockList(source: source):
            return commitRemoveBlockList(source)
        case let .allowList(list: list):
            return commitAllowList(list)
        }
    }

    /// 重写与 Mock 改的是同一个数组，所以共用这一条写路径；label 只决定提示语。
    private func commitLine(_ line: String, at index: Int?, label: String) -> Outcome {
        var next = engine.profile.rewrites
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        var removed = false
        if let index, index < next.count {
            if trimmed.isEmpty {
                next.remove(at: index)
                removed = true
            } else {
                next[index] = trimmed
            }
        } else if !trimmed.isEmpty {
            next.append(trimmed)
        } else {
            return Outcome(message: "没有可保存的内容", kind: .warning)
        }

        let issues = engine.replaceRewrites(next)
        if let issue = issues.first {
            // 写进去了，只是有行被跳过——照旧告诉用户是哪一行，不假装成功。
            return Outcome(message: "有一条规则被跳过：\(issue.reason)", kind: .warning)
        }
        return Outcome(message: removed ? "已删除\(label)" : "\(label)已更新", kind: .success)
    }

    private func commitScript(index: Int, enabled: Bool) -> Outcome {
        var next = engine.profile.scripts
        // 下标在两次刷新之间可能失效（后台 reload 换了脚本集）：宁可让用户重开页面，
        // 也不要静默切错一条。
        guard index >= 0, index < next.count else {
            return Outcome(message: "脚本列表已变化，请重新打开这一页再试", kind: .warning)
        }
        let name = next[index].name
        guard next[index].enabled != enabled else {
            return Outcome(message: "脚本 \(name) 已经是这个状态", kind: .info)
        }
        next[index].enabled = enabled
        let disabled = engine.replaceScripts(next)
        if let reason = disabled[name] {
            return Outcome(message: "\(name) 没起来：\(reason)", kind: .warning)
        }
        return Outcome(message: enabled ? "脚本 \(name) 已启用" : "脚本 \(name) 已停用",
                       kind: enabled ? .success : .info)
    }

    private func commitAddBlockList(_ source: String) -> Outcome {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return Outcome(message: "来源不能为空", kind: .warning) }
        guard !engine.profile.adblock.blockLists.contains(value) else {
            return Outcome(message: "该来源已存在", kind: .warning)
        }
        engine.updateProfile(restart: true) { $0.adblock.blockLists.append(value) }
        return Outcome(message: "已添加来源，正在重新加载", kind: .success)
    }

    private func commitRemoveBlockList(_ source: String) -> Outcome {
        let target = engine
        target.updateProfile(restart: true) { $0.adblock.blockLists.removeAll { $0 == source } }
        return Outcome(message: "已移除来源", kind: .info, undo: {
            target.updateProfile(restart: true) { profile in
                if !profile.adblock.blockLists.contains(source) {
                    profile.adblock.blockLists.append(source)
                }
            }
        })
    }

    private func commitAllowList(_ list: [String]) -> Outcome {
        let target = engine
        let previous = target.profile.adblock.allowList
        guard previous != list else {
            return Outcome(message: "白名单没有变化", kind: .info)
        }
        target.updateProfile(restart: true) { $0.adblock.allowList = list }
        return Outcome(message: "白名单已保存（\(list.count) 条）", kind: .success, undo: {
            target.updateProfile(restart: true) { $0.adblock.allowList = previous }
        })
    }
}

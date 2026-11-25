import Foundation
import CoreGraphics   // CGRect 的成员（insetBy / minX）只在 CoreGraphics 里，Foundation 只给壳

// MARK: - v6 §4.4 · 书脊资源库的模型层
//
// 这一层不 import SwiftUI，也不 import LeapinCore：书脊的排序、体检、比较
// 全是纯函数，能用 `scripts/spine-selftest.swift` 在命令行直接跑。
// 视图（`SpineShelf.swift`）只负责把 Profile 翻译成 LPSpineSnapshot，
// 再把结果画出来——判断不写在 body 里。

// MARK: 快照

/// 一条书脊要显示与判断的全部事实，全部来自一份已保存的配置。
struct LPSpineSnapshot: Equatable, Identifiable {
    var id: UUID
    var name: String
    /// 来源：订阅主机、文件名，或「本机」。
    var source: String
    var updatedAt: Date
    var ruleCount: Int
    /// 规则的可比较形态，保留原始优先级顺序。
    var ruleLines: [String]
    /// 规则类型分布，目录用。
    var tallies: [LPSpineTally]
    var groups: [LPSpineGroup]
    var outbounds: [String]
    var rewriteCount: Int
    var scriptNames: [String]
    var adblockEnabled: Bool
    var adblockListCount: Int
    var dnsPort: Int
    var dnsUpstreamCount: Int
    /// 规则里指向了不存在的策略（出口/组都没有这个名字）。
    var danglingPolicies: [String]
    /// 成员为空的策略组。
    var emptyGroups: [String]

    init(id: UUID, name: String, source: String, updatedAt: Date,
         ruleCount: Int = 0, ruleLines: [String] = [], tallies: [LPSpineTally] = [],
         groups: [LPSpineGroup] = [], outbounds: [String] = [],
         rewriteCount: Int = 0, scriptNames: [String] = [],
         adblockEnabled: Bool = false, adblockListCount: Int = 0,
         dnsPort: Int = 0, dnsUpstreamCount: Int = 0,
         danglingPolicies: [String] = [], emptyGroups: [String] = []) {
        self.id = id
        self.name = name
        self.source = source
        self.updatedAt = updatedAt
        self.ruleCount = ruleCount
        self.ruleLines = ruleLines
        self.tallies = tallies
        self.groups = groups
        self.outbounds = outbounds
        self.rewriteCount = rewriteCount
        self.scriptNames = scriptNames
        self.adblockEnabled = adblockEnabled
        self.adblockListCount = adblockListCount
        self.dnsPort = dnsPort
        self.dnsUpstreamCount = dnsUpstreamCount
        self.danglingPolicies = danglingPolicies
        self.emptyGroups = emptyGroups
    }
}

struct LPSpineTally: Equatable, Identifiable {
    var name: String
    var count: Int
    var id: String { name }
}

struct LPSpineGroup: Equatable, Identifiable {
    var name: String
    var type: String
    var memberCount: Int
    var id: String { name }
}

// MARK: 来源标签

enum LPSpineSource {
    /// 订阅链接取主机名，文件取文件名，粘贴进来的文本没有来源就是「本机」。
    /// 认不出来的串原样保留——猜错来源比不显示来源更糟。
    static func label(from raw: String?) -> String {
        guard let raw else { return "本机" }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "本机" }
        if let host = URL(string: text)?.host, !host.isEmpty { return host }
        if text.contains("/") {
            let last = text.split(separator: "/").last.map(String.init) ?? text
            return last.isEmpty ? "本机" : last
        }
        return text
    }
}

// MARK: 体检

enum LPSpineCheckLevel: Int, Comparable {
    case ok = 0
    case warn = 1
    case fail = 2

    static func < (a: LPSpineCheckLevel, b: LPSpineCheckLevel) -> Bool { a.rawValue < b.rawValue }
}

struct LPSpineCheck: Equatable, Identifiable {
    var name: String
    var detail: String
    var level: LPSpineCheckLevel
    var id: String { name }
}

struct LPSpineHealth: Equatable {
    var checks: [LPSpineCheck]

    var level: LPSpineCheckLevel { checks.map(\.level).max() ?? .ok }
    var failCount: Int { checks.filter { $0.level == .fail }.count }
    var warnCount: Int { checks.filter { $0.level == .warn }.count }

    /// 一句话结论。体检不合格时先说「修什么」，不写「有问题」。
    var label: String {
        switch level {
        case .fail: return "\(failCount) 项需修复"
        case .warn: return "\(warnCount) 项待处理"
        case .ok: return "可以启用"
        }
    }

    /// `now` 是参数而不是 Date()，体检结论才可重跑、可测。
    static func evaluate(_ spine: LPSpineSnapshot, now: Date = Date()) -> LPSpineHealth {
        var checks: [LPSpineCheck] = []

        if spine.ruleCount > 0 {
            checks.append(.init(name: "规则", detail: "\(spine.ruleCount) 条", level: .ok))
        } else {
            checks.append(.init(name: "规则", detail: "没有规则：所有流量只会落到默认出口", level: .fail))
        }

        if spine.danglingPolicies.isEmpty {
            checks.append(.init(name: "引用", detail: "每条规则都指向存在的出口或组", level: .ok))
        } else {
            let names = spine.danglingPolicies.prefix(3).joined(separator: "、")
            let more = spine.danglingPolicies.count > 3 ? " 等 \(spine.danglingPolicies.count) 个" : ""
            checks.append(.init(name: "引用",
                                detail: "指向不存在的策略：\(names)\(more)",
                                level: .fail))
        }

        if !spine.emptyGroups.isEmpty {
            let names = spine.emptyGroups.prefix(3).joined(separator: "、")
            checks.append(.init(name: "策略组",
                                detail: "\(spine.emptyGroups.count) 个组没有成员：\(names)",
                                level: .fail))
        } else if spine.groups.isEmpty {
            checks.append(.init(name: "策略组", detail: "没有策略组，规则直接指向出口", level: .ok))
        } else {
            checks.append(.init(name: "策略组", detail: "\(spine.groups.count) 个，成员齐全", level: .ok))
        }

        if spine.outbounds.isEmpty {
            checks.append(.init(name: "出口", detail: "没有出口，规则无处可去", level: .fail))
        } else {
            checks.append(.init(name: "出口", detail: "\(spine.outbounds.count) 个：\(spine.outbounds.prefix(3).joined(separator: "、"))", level: .ok))
        }

        if spine.dnsPort == 0 {
            checks.append(.init(name: "DNS", detail: "监听端口为 0，解析不会生效", level: .fail))
        } else if spine.dnsPort == 5353 {
            checks.append(.init(name: "DNS", detail: "5353 被 mDNSResponder 占用，换一个端口", level: .fail))
        } else if spine.dnsUpstreamCount == 0 {
            checks.append(.init(name: "DNS", detail: "端口 \(spine.dnsPort)，但没有上游服务器", level: .warn))
        } else {
            checks.append(.init(name: "DNS", detail: "端口 \(spine.dnsPort)，\(spine.dnsUpstreamCount) 个上游", level: .ok))
        }

        // 运行时总会把内置的 leapin-ads.txt 拼进列表（TouchFlowEngine 里 ensureBundledLists），
        // 所以「没加自己的列表」不是缺陷，只是没扩展。写成 warn 会让每份配置都亮黄灯。
        if spine.adblockEnabled && spine.adblockListCount == 0 {
            checks.append(.init(name: "去广告", detail: "内置列表", level: .ok))
        } else if spine.adblockEnabled {
            checks.append(.init(name: "去广告", detail: "内置列表 + \(spine.adblockListCount) 个自加", level: .ok))
        } else {
            checks.append(.init(name: "去广告", detail: "关闭", level: .ok))
        }

        let age = now.timeIntervalSince(spine.updatedAt)
        let days = max(0, Int(age / 86_400))
        if days > 30 {
            checks.append(.init(name: "更新", detail: "\(days) 天没更新", level: .warn))
        } else if days == 0 {
            checks.append(.init(name: "更新", detail: "今天更新过", level: .ok))
        } else {
            checks.append(.init(name: "更新", detail: "\(days) 天前更新", level: .ok))
        }

        return LPSpineHealth(checks: checks)
    }
}

// MARK: 比较

struct LPSpineComparison: Equatable {
    var leftID: UUID
    var rightID: UUID
    var leftName: String
    var rightName: String
    var commonRules: Int
    var onlyLeftRules: [String]
    var onlyRightRules: [String]
    var leftOnlyGroups: [String]
    var rightOnlyGroups: [String]
    var leftOnlyOutbounds: [String]
    var rightOnlyOutbounds: [String]
    var leftRuleCount: Int
    var rightRuleCount: Int

    /// right - left 的总条数差。注意它不等于「右侧独有多少条」：
    /// 有一条进就有一条出，两回事要分开说。
    var ruleDelta: Int { rightRuleCount - leftRuleCount }
    var identicalRules: Bool { onlyLeftRules.isEmpty && onlyRightRules.isEmpty }

    /// 一句结论：先说总量差，再说各自独有。两个数都给，读者不用自己减。
    var headline: String {
        guard leftID != rightID else { return "同一条书脊，没有可比较的差异" }
        if identicalRules {
            if leftOnlyGroups.isEmpty && rightOnlyGroups.isEmpty {
                return "两份配置的规则完全相同"
            }
            return "规则相同，策略组不同"
        }
        let counts: String
        if ruleDelta == 0 {
            counts = "规则数相同（\(leftRuleCount) 条），但内容不同"
        } else {
            let word = ruleDelta > 0 ? "多" : "少"
            counts = "\(rightName) 比 \(leftName) \(word) \(abs(ruleDelta)) 条（\(rightRuleCount) 对 \(leftRuleCount)）"
        }
        return "\(counts)：右侧独有 \(onlyRightRules.count) 条、左侧独有 \(onlyLeftRules.count) 条"
    }
}

enum LPSpineCompare {
    static func run(_ left: LPSpineSnapshot, _ right: LPSpineSnapshot) -> LPSpineComparison {
        let leftSet = Set(left.ruleLines)
        let rightSet = Set(right.ruleLines)
        // 顺序按原优先级走：只看「有没有」，不改顺序。
        let onlyLeft = left.ruleLines.filter { !rightSet.contains($0) }
        let onlyRight = right.ruleLines.filter { !leftSet.contains($0) }
        let common = leftSet.intersection(rightSet).count

        return LPSpineComparison(
            leftID: left.id,
            rightID: right.id,
            leftName: left.name,
            rightName: right.name,
            commonRules: common,
            onlyLeftRules: onlyLeft,
            onlyRightRules: onlyRight,
            leftOnlyGroups: difference(left.groups.map(\.name), right.groups.map(\.name)),
            rightOnlyGroups: difference(right.groups.map(\.name), left.groups.map(\.name)),
            leftOnlyOutbounds: difference(left.outbounds, right.outbounds),
            rightOnlyOutbounds: difference(right.outbounds, left.outbounds),
            leftRuleCount: left.ruleCount,
            rightRuleCount: right.ruleCount
        )
    }

    /// 保持左表顺序的去重差集。
    static func difference(_ a: [String], _ b: [String]) -> [String] {
        let other = Set(b)
        var seen = Set<String>()
        return a.filter { !other.contains($0) && seen.insert($0).inserted }
    }
}

// MARK: 落点判定

/// 「拖到哪条书脊上」是一次命中测试，不是一个手势细节：拖错对象会让人以为两份配置一样。
/// 放在模型里，是为了能用矩形和点直接验，而不是靠手拖一遍看结果。
enum LPSpineHitTest {
    /// - Parameters:
    ///   - point: 手势书架坐标系里的位置
    ///   - frames: 每条书脊在书架坐标系里的框
    ///   - excluding: 正在被拖的那条，永远不算落点
    static func target(point: CGPoint, frames: [UUID: CGRect], excluding: UUID?) -> UUID? {
        // 字典无序；重叠时取最左的一条，结果才可复现。
        frames
            .filter { $0.key != excluding }
            .sorted(by: { $0.value.minX < $1.value.minX })
            .first { $0.value.insetBy(dx: LPSpineShelfLayout.dropInset,
                                      dy: LPSpineShelfLayout.dropInset).contains(point) }?
            .key
    }
}

// MARK: 竖排

/// 书脊上的字怎么站。
///
/// 中文书名在书脊上是「字正立、从上往下」，西文与文件名才是整行转 90°。
/// 这条规则放在模型里，是因为它决定排版是否可读，而不是一次随手调参。
enum LPSpineVertical {
    enum Mode: Equatable { case stacked, rotated }

    /// 带分隔符的串（文件名、英文名、路径）一律转排：把 "a.yaml" 拆成一列单字没人读得懂。
    static func mode(for text: String) -> Mode {
        let chars = Array(text)
        guard !chars.isEmpty else { return .rotated }
        if chars.contains(where: { " ._-/:".contains($0) }) { return .rotated }
        let cjk = chars.filter(isCJK).count
        guard cjk * 2 >= chars.count else { return .rotated }
        return chars.count <= 12 ? .stacked : .rotated
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x3040...0x30FF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    /// 竖排格子能放几个字。行距按 1.15 倍字号留，太挤会连成一条。
    static func capacity(length: CGFloat, size: CGFloat) -> Int {
        guard size > 0 else { return 0 }
        return max(1, Int(length / (size * 1.15)))
    }

    /// 放不下时截断并补省略号；省略号也占一格。
    static func stacked(_ text: String, capacity: Int) -> String {
        let chars = Array(text)
        guard chars.count > capacity else { return text }
        guard capacity > 1 else { return "" }
        return String(chars.prefix(capacity - 1)) + "…"
    }
}

// MARK: 书架尺寸

/// 书脊的厚度跟着规则数走：越厚的配置规则越多，一眼能分出主次。
/// 四个档位，不做连续映射——连续映射会让相邻两份看起来只差 1px。
enum LPSpineShelfLayout {
    static let height: CGFloat = 300
    static let gap: CGFloat = 12
    static let minWidth: CGFloat = 46
    static let maxWidth: CGFloat = 70
    /// 落点边缘收 4pt：贴着缝松手不算「叠上去」。
    static let dropInset: CGFloat = 4

    static func width(ruleCount: Int) -> CGFloat {
        switch ruleCount {
        case ..<1: return 52          // 空配置也占一本书的位置，不能比有规则的还厚
        case 1...50: return minWidth
        case 51...500: return 54
        case 501...5_000: return 62
        default: return maxWidth
        }
    }

    static func width(for spine: LPSpineSnapshot) -> CGFloat { width(ruleCount: spine.ruleCount) }
}

// MARK: 规则行

enum LPSpineRuleLine {
    /// 一行规则的可读形态：`DOMAIN-SUFFIX,google.com → PROXY`。
    /// 书脊展示和差异比较用同一串：比较结果里出现的每一行，都必须是用户能在详情里看到的那一行。
    static func display(kind: String, value: String, policy: String) -> String {
        "\(kind),\(value) → \(policy)"
    }
}

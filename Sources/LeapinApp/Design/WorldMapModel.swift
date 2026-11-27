import Foundation
import CoreGraphics

// MARK: - 网络星图的纯逻辑（不 import SwiftUI，命令行可直接跑）
//
// 首页是一张图：这台 Mac 在中心，出口按地区散在外圈。这里只回答两件事——
// 一个出口名属于哪个地区，以及同一个地区的节点怎样在弧上排开。
// 观感与绘制在 NetworkMap.swift。

/// 出口按地区归簇。方位角是从这台 Mac「看出去」的抽象方向：90° 正上方、
/// 0° 正右、180° 正左。不是真实经纬度，但每个地区有固定的方位，换一份配置节点也不乱跳。
public enum LPRegion: String, CaseIterable, Sendable {
    case america, japanKorea, hkTaiwan, southeastAsia, europe, other

    public var angle: Double {
        switch self {
        case .america: return 36
        case .japanKorea: return 63
        case .hkTaiwan: return 90
        case .southeastAsia: return 117
        case .europe: return 144
        case .other: return 90
        }
    }

    public var title: String {
        switch self {
        case .america: return "美洲"
        case .japanKorea: return "日本 · 韩国"
        case .hkTaiwan: return "香港 · 台湾"
        case .southeastAsia: return "东南亚"
        case .europe: return "欧洲"
        case .other: return "其他"
        }
    }

    /// 「其他」没有自己的方位：它升到弧的正上方更外一圈，不和任何地区抢位置。
    /// 视子窗口高度放得下放不下，画不下时视图只写个数。
    public var ring: CGFloat { self == .other ? 1.46 : 1 }

    static let words: [(LPRegion, [String])] = [
        (.hkTaiwan, ["香港", "台湾", "台灣", "台北", "台中", "高雄", "澳门", "澳門",
                     "hong kong", "hongkong", "taiwan", "taipei"]),
        (.japanKorea, ["日本", "东京", "東京", "大阪", "韩国", "韓國", "首尔", "首爾",
                       "japan", "tokyo", "osaka", "korea", "seoul"]),
        (.southeastAsia, ["新加坡", "狮城", "獅城", "马来", "马来西亚", "吉隆坡", "泰国", "曼谷", "越南",
                          "菲律宾", "印尼", "印度", "迪拜", "阿联酋",
                          "singapore", "malaysia", "kuala", "thailand", "bangkok", "vietnam",
                          "philippine", "indonesia", "india", "dubai", "uae"]),
        (.america, ["美国", "美國", "美西", "美东", "美東", "洛杉矶", "圣何塞", "西雅图", "硅谷", "纽约",
                    "达拉斯", "芝加哥", "加拿大", "巴西", "阿根廷",
                    "united states", "america", "los angeles", "san jose", "seattle",
                    "silicon valley", "new york", "dallas", "chicago", "canada", "brazil", "argentina"]),
        (.europe, ["欧洲", "歐洲", "英国", "英國", "伦敦", "倫敦", "德国", "德國", "法兰克福", "法国", "法國",
                   "巴黎", "荷兰", "荷蘭", "俄罗斯", "俄羅斯", "莫斯科", "瑞典", "瑞士", "芬兰", "意大利",
                   "波兰", "西班牙", "乌克兰", "土耳其",
                   "europe", "kingdom", "london", "germany", "frankfurt", "france", "paris",
                   "netherlands", "amsterdam", "russia", "moscow", "sweden", "switzerland",
                   "finland", "italy", "poland", "spain", "ukraine", "turkey"]),
    ]

    /// 两个字母的国家码只在它是独立记号时才算。
    static let codes: [(LPRegion, [String])] = [
        (.hkTaiwan, ["hk", "tw", "mo"]),
        (.japanKorea, ["jp", "kr"]),
        (.southeastAsia, ["sg", "my", "th", "vn", "ph", "id", "ae"]),
        (.america, ["us", "usa", "ca", "br", "ar"]),
        (.europe, ["uk", "de", "fr", "nl", "ru", "it", "es", "pl", "ua", "se", "fi", "tr"]),
    ]

    public static func of(_ name: String) -> LPRegion {
        let lower = name.lowercased()
        for (region, keywords) in words where keywords.contains(where: { lower.contains($0) }) {
            return region
        }
        for (region, codes) in codes where codes.contains(where: { hasCode(lower, $0) }) {
            return region
        }
        return .other
    }

    /// `HK-01`、`[jp]`、`香港 SG` 里的码算数；`turkey` 里的 `kr`、`america` 里的 `ca` 不算。
    static func hasCode(_ raw: String, _ code: String) -> Bool {
        let text = raw.lowercased()
        var cursor = text.startIndex
        while let range = text.range(of: code, range: cursor..<text.endIndex) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : " "
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : " "
            if !before.isLetter, !after.isLetter { return true }
            cursor = range.upperBound
        }
        return false
    }
}

/// 一个出口在世界弧上的落位。
public struct LPWorldNode: Identifiable, Equatable, Sendable {
    public let id: String
    public let region: LPRegion
    /// 方位角（度，90 = 正上）。
    public let angle: Double
    /// 到中心的距离，以世界弧半径为单位。
    public let radius: CGFloat
    public let current: Bool
    public let labelled: Bool

    public init(id: String, region: LPRegion, angle: Double, radius: CGFloat, current: Bool, labelled: Bool) {
        self.id = id; self.region = region; self.angle = angle; self.radius = radius
        self.current = current; self.labelled = labelled
    }
}

public enum LPWorldLayout {
    /// 「其他」的步子更小：它悬在弧的正上方，左右要给场景导轨和最近决策让位。
    public static let otherStep: Double = 5

    /// 画弧的范围（度）。美洲在最右，欧洲在最左，中间从右到左是日韩、港台、东南亚。
    public static let arcStart: Double = 26
    public static let arcEnd: Double = 154
    /// 弧上最多画这么多节点；再多就只画点、不画名字。
    public static let maxNodes = 48

    /// 订阅里常见的说明性伪节点：名字写着流量、到期、官网，拨是拨得出去，但没人会把它当出口。
    /// 它们不进图——否则全堆在「其他」那一簇，把真正的出口挤没。
    static let placeholders = ["流量", "到期", "过期", "重置", "套餐", "官网", "官網", "客服", "网址", "網址",
                               "频道", "頻道", "电报", "電報", "traffic", "expire", "expiry", "reset", "remaining"]

    public static func isPlaceholder(_ name: String) -> Bool {
        let lower = name.lowercased()
        return placeholders.contains { lower.contains($0) }
    }

    /// 把出口名排到弧上：先按地区归簇，簇内围着地区的方位散开，全部落在同一层弧上。
    /// 密的地方名字稀疏着写（由视图按间距决定标哪几个），点一个不少。
    public static func nodes(names: [String], current: String?, labelled: Set<String>) -> [LPWorldNode] {
        let shown = Array(names.filter { !isPlaceholder($0) }.prefix(maxNodes))
        let groups = Dictionary(grouping: shown, by: LPRegion.of)
        var out: [LPWorldNode] = []
        for region in LPRegion.allCases {
            guard let members = groups[region], !members.isEmpty else { continue }
            let step = region == .other ? min(otherStep, 30.0 / Double(members.count))
                                         : min(12.0, 36.0 / Double(members.count))
            for (index, name) in members.enumerated() {
                let offset = (Double(index) - Double(members.count - 1) / 2) * step
                out.append(LPWorldNode(
                    id: name, region: region, angle: region.angle + offset, radius: region.ring,
                    current: name == current,
                    labelled: shown.count <= 24 || labelled.contains(name) || name == current))
            }
        }
        return out
    }

    /// 极坐标落点：角度 90° 在正上方。
    public static func point(center: CGPoint, radius: CGFloat, angle: Double, factor: CGFloat = 1) -> CGPoint {
        let radians = angle * Double.pi / 180
        return CGPoint(x: center.x + radius * factor * CGFloat(cos(radians)),
                       y: center.y - radius * factor * CGFloat(sin(radians)))
    }
}

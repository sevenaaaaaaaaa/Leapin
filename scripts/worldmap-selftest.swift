import Foundation

// 网络星图模型层的命令行自测。跑法（在仓库根目录）：
//
//   swiftc -O Sources/LeapinApp/Design/WorldMapModel.swift scripts/worldmap-selftest.swift \
//     -o /tmp/worldmap_selftest && /tmp/worldmap_selftest
//
// 只编模型文件，不编 SwiftUI：出口归簇与弧上落位必须能脱离界面复跑。

@main
struct WorldMapSelfTest {
    static var pass = 0
    static var failures: [String] = []

    static func check(_ name: String, _ condition: Bool, _ note: String = "") {
        if condition {
            pass += 1
        } else {
            failures.append(note.isEmpty ? name : "\(name) — \(note)")
        }
    }

    static func main() {
        regions()
        codes()
        placeholders()
        layout()
        points()

        for line in failures { print("FAIL \(line)") }
        print("WORLDMAP \(failures.isEmpty ? "PASS" : "FAIL") \(pass)/\(pass + failures.count)")
        if !failures.isEmpty { exit(1) }
    }

    // MARK: 地区

    static func regions() {
        let cases: [(String, LPRegion)] = [
            ("香港 01", .hkTaiwan), ("台湾 IEPL", .hkTaiwan), ("Hong Kong 03", .hkTaiwan),
            ("日本 02", .japanKorea), ("Tokyo 03", .japanKorea), ("韩国 首尔", .japanKorea), ("Seoul-01", .japanKorea),
            ("新加坡", .southeastAsia), ("Singapore-01", .southeastAsia), ("吉隆坡", .southeastAsia), ("迪拜", .southeastAsia),
            ("美国 洛杉矶", .america), ("Los Angeles", .america), ("美西 02", .america), ("加拿大", .america),
            ("德国 法兰克福", .europe), ("Frankfurt", .europe), ("伦敦", .europe), ("土耳其", .europe),
            ("node-01.example.com", .other), ("", .other), ("套餐到期剩余流量：10G", .other),
        ]
        for (name, region) in cases {
            check("归簇 \(name)", LPRegion.of(name) == region, "得到 \(LPRegion.of(name))，应为 \(region)")
        }
        check("每个地区有方位", LPRegion.allCases.allSatisfy { (26...154).contains($0.angle) })
        check("每个地区有名字", LPRegion.allCases.allSatisfy { !$0.title.isEmpty })
        check("其他压在外圈", LPRegion.other.ring > 1)
    }

    // MARK: 国家码

    static func codes() {
        let hits = [("hk-01", "hk"), ("[jp]", "jp"), ("香港 sg", "sg"), ("hk01", "hk"), ("US-01", "us"), ("de", "de")]
        for (text, code) in hits {
            check("码算数 \(text)/\(code)", LPRegion.hasCode(text, code), text)
        }
        // 子串里的两个字母不算国家码。
        let misses = [("turkey", "kr"), ("america", "ca"), ("rus", "us"), ("hk01", "kr"), ("seoul", "se"), ("dubai", "ae")]
        for (text, code) in misses {
            check("子串不算 \(text)/\(code)", !LPRegion.hasCode(text, code), text)
        }
        check("关键词先于国家码", LPRegion.of("hk-tokyo") == .japanKorea, "\(LPRegion.of("hk-tokyo"))")
    }

    // MARK: 伪节点

    static func placeholders() {
        let fake = ["剩余流量：97.6 GB", "套餐到期：2027-01-01", "距离下次重置剩余：27 天", "官网：example.com",
                    "Traffic 1.2 TB", "Expires in 12 days", "重置日：1 号"]
        for name in fake {
            check("伪节点 \(name)", LPWorldLayout.isPlaceholder(name), "应当不进图")
        }
        let real = ["香港 01", "Tokyo-03", "美国 洛杉矶", "IEPL-新加坡", "node-01"]
        for name in real {
            check("真节点 \(name)", !LPWorldLayout.isPlaceholder(name), "不该被过滤")
        }
        let mixed = LPWorldLayout.nodes(names: fake + ["香港 01"], current: "香港 01", labelled: [])
        check("伪节点不进图", mixed.map(\.id) == ["香港 01"], "\(mixed.map(\.id))")
        // 伪节点不占「最多 48 个」的名额。
        let crowded = LPWorldLayout.nodes(names: fake + (1...48).map { "香港 \($0)" }, current: nil, labelled: [])
        check("名额留给真出口", crowded.count == 48, "\(crowded.count)")
    }

    // MARK: 落位

    static func layout() {
        check("没有出口就没有节点", LPWorldLayout.nodes(names: [], current: nil, labelled: []).isEmpty)

        let two = LPWorldLayout.nodes(names: ["香港 01", "日本 02"], current: "日本 02", labelled: [])
        check("两个出口两个点", two.count == 2)
        let hk = two.first { $0.id == "香港 01" }
        let jp = two.first { $0.id == "日本 02" }
        check("香港落在 90°", hk?.angle == 90 && hk?.region == .hkTaiwan && hk?.radius == 1, "\(String(describing: hk))")
        check("日本落在 63°", jp?.angle == 63 && jp?.region == .japanKorea, "\(String(describing: jp))")
        check("当前出口只有一个", two.filter(\.current).map(\.id) == ["日本 02"])
        check("出口少时都写名字", two.allSatisfy(\.labelled))
        // 地区按固定顺序枚举，不随出口在配置里的先后变：同一份配置，图上位置永远一样。
        check("落位与顺序无关", two.map(\.region) == LPWorldLayout.nodes(names: ["日本 02", "香港 01"], current: nil, labelled: []).map(\.region))

        // 同一地区六个点：围着 90° 散开成 6° 一步，全落在同一层弧上。
        let six = LPWorldLayout.nodes(names: (1...6).map { "香港 0\($0)" }, current: nil, labelled: [])
        check("六个点同簇", six.count == 6 && six.allSatisfy { $0.region == .hkTaiwan })
        check("角度对称", six.first!.angle == 90 - 15 && six.last!.angle == 90 + 15,
              "\(six.first!.angle)…\(six.last!.angle)")
        check("同一层弧", six.allSatisfy { $0.radius == 1 })
        check("彼此不重合", Set(six.map { "\($0.angle)/\($0.radius)" }).count == 6)

        // 当前出口是簇里的一员，位置不因为它成了星而挪动。
        let plain = LPWorldLayout.nodes(names: (1...6).map { "香港 0\($0)" }, current: nil, labelled: [])
        let lifted = LPWorldLayout.nodes(names: (1...6).map { "香港 0\($0)" }, current: "香港 03", labelled: [])
        check("星在簇里原位", lifted.first { $0.current }?.angle == plain.first { $0.id == "香港 03" }?.angle
              && lifted.first { $0.current }?.radius == 1, "\(String(describing: lifted.first { $0.current }))")

        // 出口多了就只画点：除了点过的和当前出口，都不写名字。
        let many = LPWorldLayout.nodes(names: (1...60).map { "node-\($0)" }, current: "node-7", labelled: ["node-9"])
        check("最多 48 个点", many.count == LPWorldLayout.maxNodes, "\(many.count)")
        check("超过 48 的不画", !many.contains { $0.id == "node-49" })
        check("多了只留点", many.filter(\.labelled).map(\.id) == ["node-7", "node-9"], "\(many.filter(\.labelled).map(\.id))")
        check("其他在正上方外圈", many.allSatisfy { $0.region == .other && $0.radius == LPRegion.other.ring })
        check("其他步子小", many.last!.angle - many.first!.angle < 60, "\(many.first!.angle)…\(many.last!.angle)")

        // 当前出口不在名单里（选的是策略组名）：不点亮任何点。
        let groupOnly = LPWorldLayout.nodes(names: ["香港 01"], current: "Proxy", labelled: [])
        check("组名不点亮", !groupOnly.contains(where: \.current))

        // 不同地区各在各的方位，不会挤到一起。
        let world = LPWorldLayout.nodes(names: ["美国 01", "日本 01", "香港 01", "新加坡 01", "德国 01", "x-01"],
                                        current: nil, labelled: [])
        let angles = Dictionary(uniqueKeysWithValues: world.map { ($0.region, $0.angle) })
        check("美洲 36°", angles[.america] == 36)
        check("日韩 63°", angles[.japanKorea] == 63)
        check("港台 90°", angles[.hkTaiwan] == 90)
        check("东南亚 117°", angles[.southeastAsia] == 117)
        check("欧洲 144°", angles[.europe] == 144)
    }

    // MARK: 极坐标

    static func points() {
        let center = CGPoint(x: 100, y: 100)
        func near(_ a: CGPoint, _ x: CGFloat, _ y: CGFloat) -> Bool {
            abs(a.x - x) < 0.001 && abs(a.y - y) < 0.001
        }
        check("90° 在正上", near(LPWorldLayout.point(center: center, radius: 50, angle: 90), 100, 50))
        check("0° 在正右", near(LPWorldLayout.point(center: center, radius: 50, angle: 0), 150, 100))
        check("180° 在正左", near(LPWorldLayout.point(center: center, radius: 50, angle: 180), 50, 100))
        check("270° 在正下", near(LPWorldLayout.point(center: center, radius: 50, angle: 270), 100, 150))
        check("倍数沿方位外推", near(LPWorldLayout.point(center: center, radius: 50, angle: 90, factor: 1.2), 100, 40))
    }
}

import Foundation
import LeapinCore

/// Order-aware "can this rule ever win?" preview for the rule editor.
///
/// The rule index in LeapinPolicy is authoritative for runtime matching; this
/// pass only needs the profile being edited, so rows can be flagged as dead the
/// moment they are added, without a reload or a trip through the engine.
/// It is deliberately conservative: when a case is ambiguous it reports nothing.
enum RuleDiagnosticsScan {

    static func scan(_ rules: [Rule]) -> [Int: RuleDiagnostic] {
        var out: [Int: RuleDiagnostic] = [:]
        var firstSeen: [String: (index: Int, policy: String)] = [:]
        var suffixFirst: [String: Int] = [:]
        var ipv4First: [(net: UInt32, prefix: Int, index: Int)] = []
        var terminated: Int?

        for (index, rule) in rules.enumerated() {
            if let stop = terminated {
                out[index] = diagnose(rule, index, .unreachable,
                                      "位于第 \(stop + 1) 条 MATCH 之后，永远不会被求值",
                                      shadowedBy: stop)
                continue
            }
            if rule.kind == .match {
                terminated = index
                continue
            }

            let value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.isEmpty {
                out[index] = diagnose(rule, index, .neverMatch, "匹配值为空，不会命中任何连接")
                continue
            }
            if rule.kind == .domainRegex, (try? NSRegularExpression(pattern: rule.value)) == nil {
                out[index] = diagnose(rule, index, .neverMatch, "正则无法编译，永远不会命中")
                continue
            }

            // Same matcher already seen: the engine keeps the first one.
            let key = "\(rule.kind.rawValue)|\(value)|\(rule.modifiers.joined(separator: ","))|\(rule.negate)"
            if let first = firstSeen[key] {
                if first.policy.caseInsensitiveCompare(rule.policy) == .orderedSame {
                    out[index] = diagnose(rule, index, .duplicate,
                                          "与第 \(first.index + 1) 条完全相同，后者永远不会命中",
                                          shadowedBy: first.index)
                } else {
                    out[index] = diagnose(rule, index, .shadowed,
                                          "与第 \(first.index + 1) 条匹配范围相同，首条优先（策略 \(first.policy)）",
                                          shadowedBy: first.index)
                }
                continue
            }
            firstSeen[key] = (index, rule.policy)

            if rule.kind == .domainSuffix || rule.kind == .domain {
                let includeSelf = rule.kind == .domain
                if let covering = coveringSuffix(value, in: suffixFirst, includeSelf: includeSelf) {
                    out[index] = diagnose(rule, index, .shadowed,
                                          "已被第 \(covering + 1) 条 DOMAIN-SUFFIX 覆盖，永远不会命中",
                                          shadowedBy: covering)
                } else if rule.kind == .domainSuffix {
                    suffixFirst[value] = index
                }
                continue
            }

            if rule.kind == .ipCIDR {
                guard let prefix = IPv4Prefix(value) else {
                    out[index] = diagnose(rule, index, .neverMatch,
                                          "CIDR 无法解析（需要 a.b.c.d/0-32，IPv6 请用 IP-CIDR6）")
                    continue
                }
                if ipv4First.count <= 4096,
                   let covering = ipv4First.first(where: {
                       $0.prefix <= prefix.prefix
                           && (prefix.net & RuleDiagnosticsScan.mask($0.prefix)) == ($0.net & RuleDiagnosticsScan.mask($0.prefix))
                   }) {
                    out[index] = diagnose(rule, index, .shadowed,
                                          "已被第 \(covering.index + 1) 条更宽的 IP-CIDR 覆盖，永远不会命中",
                                          shadowedBy: covering.index)
                }
                ipv4First.append((prefix.net, prefix.prefix, index))
            }
        }

        return out
    }

    // MARK: - Helpers

    private static func diagnose(_ rule: Rule, _ index: Int, _ kind: RuleDiagnostic.Kind,
                                 _ reason: String, shadowedBy: Int? = nil) -> RuleDiagnostic {
        RuleDiagnostic(ruleID: rule.id, raw: rule.raw, index: index, kind: kind,
                       reason: reason, shadowedByIndex: shadowedBy)
    }

    /// Walks the parent labels of a host and returns the earliest rule that covers it.
    private static func coveringSuffix(_ value: String, in suffixes: [String: Int],
                                       includeSelf: Bool) -> Int? {
        var labels = value.split(separator: ".").map(String.init)
        if !includeSelf {
            guard labels.count > 1 else { return nil }
            labels.removeFirst()
        }
        while !labels.isEmpty {
            if let index = suffixes[labels.joined(separator: ".")] { return index }
            labels.removeFirst()
        }
        return nil
    }

    private static func mask(_ prefix: Int) -> UInt32 {
        if prefix <= 0 { return 0 }
        if prefix >= 32 { return .max }
        return ~UInt32(0) << UInt32(32 - prefix)
    }

    private struct IPv4Prefix {
        var net: UInt32
        var prefix: Int

        init?(_ text: String) {
            let parts = text.split(separator: "/")
            guard parts.count == 2,
                  let bits = Int(parts[1]), (0...32).contains(bits) else { return nil }
            let octets = parts[0].split(separator: ".")
            guard octets.count == 4 else { return nil }
            var address: UInt32 = 0
            for octet in octets {
                guard let byte = UInt8(octet) else { return nil }
                address = address << 8 | UInt32(byte)
            }
            prefix = bits
            net = address & RuleDiagnosticsScan.mask(bits)
        }
    }
}

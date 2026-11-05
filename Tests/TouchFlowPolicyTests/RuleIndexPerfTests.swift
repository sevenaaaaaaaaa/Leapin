import XCTest
import Foundation
@testable import TouchFlowPolicy
import TouchFlowCore

/// P3 performance gate: 100k mixed rules must decide in under 2 ms at p95.
///
/// The 100k profile is expensive to build, so the test skips unless TF_PERF=1.
/// It is meant for a release build:
///
///     TF_PERF=1 swift test -c release --scratch-path .build-index-perf \
///         --filter RuleIndexPerf
final class RuleIndexPerfTests: XCTestCase {

    private struct Measurement {
        let rules: Int
        let loadMilliseconds: Double
        let p50Milliseconds: Double
        let p95Milliseconds: Double
        let p99Milliseconds: Double
    }

    func testHundredThousandRulesDecisionLatency() throws {
        guard ProcessInfo.processInfo.environment["TF_PERF"] == "1" else {
            throw XCTSkip("perf gate disabled; run with TF_PERF=1 in a release build")
        }

        let ruleCount = 100_000
        let rules = makeRules(ruleCount)
        let metas = makeMetas(3_000)

        // Warm the caches and the resolver before the timed load so the number
        // reflects steady-state construction, not first-touch page faults.
        _ = RuleEngine(profile: makeProfile(rules))

        let loadStart = DispatchTime.now().uptimeNanoseconds
        let engine = RuleEngine(profile: makeProfile(rules))
        let loadNanos = DispatchTime.now().uptimeNanoseconds - loadStart
        XCTAssertEqual(engine.ruleCount, rules.count)

        // Warm-up: 200 decisions through the index.
        for index in 0..<200 {
            _ = engine.decide(metas[index % metas.count])
        }

        let measured = 2_000
        var samples: [Double] = []
        samples.reserveCapacity(measured)
        for index in 0..<measured {
            let meta = metas[index % metas.count]
            let start = DispatchTime.now().uptimeNanoseconds
            _ = engine.decide(meta)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)
            samples.append(elapsed)
        }

        samples.sort()
        let p50 = percentile(samples, 0.50)
        let p95 = percentile(samples, 0.95)
        let p99 = percentile(samples, 0.99)
        let loadMilliseconds = Double(loadNanos) / 1_000_000
        let outcome = Measurement(rules: rules.count,
                                  loadMilliseconds: loadMilliseconds,
                                  p50Milliseconds: p50 / 1_000_000,
                                  p95Milliseconds: p95 / 1_000_000,
                                  p99Milliseconds: p99 / 1_000_000)

        print(String(format: "[RuleIndexPerf] rules=%d load=%.1fms p50=%.3fms p95=%.3fms p99=%.3fms",
                     outcome.rules, outcome.loadMilliseconds,
                     outcome.p50Milliseconds, outcome.p95Milliseconds,
                     outcome.p99Milliseconds))

        // Roadmap P3 acceptance.
        XCTAssertLessThan(outcome.p95Milliseconds, 2.0,
                          "p95 \(outcome.p95Milliseconds) ms exceeds the 2 ms budget")
        XCTAssertLessThan(outcome.loadMilliseconds, 300.0,
                          "index build \(outcome.loadMilliseconds) ms exceeds the 300 ms budget")
    }

    // MARK: - Data

    private func makeProfile(_ rules: [Rule]) -> Profile {
        Profile(name: "perf", outbounds: [.direct, .reject,
                                         OutboundConfig(name: "PROXY", type: .http,
                                                        host: "127.0.0.1", port: 8080)],
                groups: [], rules: rules)
    }

    /// 40% DOMAIN-SUFFIX, 20% DOMAIN, 20% DOMAIN-KEYWORD, 20% IP-CIDR, then FINAL.
    private func makeRules(_ count: Int) -> [Rule] {
        var rules: [Rule] = []
        rules.reserveCapacity(count + 1)
        for index in 0..<count {
            switch index % 10 {
            case 0, 1, 2, 3:
                let site = "site\(index)"
                let zone = index % 500
                rules.append(Rule(kind: .domainSuffix,
                                  value: "\(site).example\(zone).com",
                                  policy: "PROXY", modifiers: [], negate: false,
                                  raw: "DOMAIN-SUFFIX,\(site).example\(zone).com,PROXY"))
            case 4, 5:
                rules.append(Rule(kind: .domain,
                                  value: "exact\(index).example.com",
                                  policy: "REJECT", modifiers: [], negate: false,
                                  raw: "DOMAIN,exact\(index).example.com,REJECT"))
            case 6, 7:
                rules.append(Rule(kind: .domainKeyword,
                                  value: "kw\(index % 2_000)",
                                  policy: "PROXY", modifiers: [], negate: false,
                                  raw: "DOMAIN-KEYWORD,kw\(index % 2_000),PROXY"))
            default:
                let a = (index / 7) % 256
                let b = (index / 3) % 256
                rules.append(Rule(kind: .ipCIDR,
                                  value: "10.\(a).\(b).0/24",
                                  policy: "REJECT", modifiers: [], negate: false,
                                  raw: "IP-CIDR,10.\(a).\(b).0/24,REJECT"))
            }
        }
        rules.append(Rule(kind: .match, value: "", policy: "DIRECT",
                          modifiers: [], negate: false, raw: "MATCH,DIRECT"))
        return rules
    }

    private func makeMetas(_ count: Int) -> [ConnectionMeta] {
        (0..<count).map { index in
            let host: String
            switch index % 5 {
            case 0:
                host = "site\(index).example\(index % 500).com"
            case 1:
                host = "cdn.site\(index).example\(index % 500).com"
            case 2:
                host = "exact\(index).example.com"
            case 3:
                host = "my-kw\(index % 2_000)-tracker.test"
            default:
                host = "unmatched-\(index).random.test"
            }
            let ip: String? = index % 3 == 0
                ? "10.\((index / 7) % 256).\((index / 3) % 256).\(index % 256)"
                : nil
            return ConnectionMeta(host: host, port: 443, network: "tcp",
                                  destinationIP: ip)
        }
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let position = Int(Double(sorted.count - 1) * fraction)
        return sorted[min(max(position, 0), sorted.count - 1)]
    }
}

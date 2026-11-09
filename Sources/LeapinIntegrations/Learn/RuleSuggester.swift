import Foundation
import LeapinCore

/// Turns learned apps plus captured flows into DOMAIN-SUFFIX rule suggestions.
///
/// Confidence is a heuristic blend of evidence strength:
/// user-supplied domain 0.85, app seen in flows with a matching source app 0.90,
/// catalogue domain confirmed by traffic 0.92, catalogue-only 0.75, traffic-only 0.60.
/// Everything is clamped to 0.50...0.95 and capped at `maxSuggestions` entries.
public enum RuleSuggester {
    public static let maxSuggestions = 200
    public static let defaultPolicy = "PROXY"

    public static func suggest(apps: [LearnedApp], flows: [FlowEvent], catalog: [LearnedApp]) -> [RuleSuggestion] {
        var candidates: [String: Candidate] = [:]

        // 1. Domains we already know from the app list.
        for app in apps {
            for domain in app.domains {
                guard let clean = normalizeHost(domain) else { continue }
                let base: Double
                switch app.source {
                case "catalog": base = 0.75
                case "flow": base = 0.80
                case "ocr": base = 0.78
                default: base = 0.85
                }
                let rationale = app.source == "catalog"
                    ? "来自内置应用目录：\(clean) 是「\(app.name)」的常见域名，未见抓包确认"
                    : "用户 / 识别结果提供的域名：\(clean) 属于「\(app.name)」"
                add(&candidates, domain: clean, appName: app.name,
                    confidence: base, rationale: rationale)
            }
        }

        // 2. Catalogue domains for apps that only appear by name.
        for app in apps where app.domains.isEmpty {
            guard let catalogApp = matchCatalog(app, catalog: catalog) else { continue }
            for domain in catalogApp.domains {
                guard let clean = normalizeHost(domain) else { continue }
                add(&candidates, domain: clean, appName: catalogApp.name,
                    confidence: 0.72,
                    rationale: "「\(app.name)」匹配到内置目录的「\(catalogApp.name)」，\(clean) 为其常见域名")
            }
        }

        // 3. Traffic evidence from captured flows.
        var hitCounts: [String: Int] = [:]
        for flow in flows {
            guard let host = normalizeHost(flow.host) else { continue }
            hitCounts[host, default: 0] += 1
        }

        for (host, count) in hitCounts {
            // Which app does this host belong to?
            let sourceApp = flows.first { normalizeHost($0.host) == host }?.sourceApp?
                .trimmingCharacters(in: .whitespaces)
            var appName = (sourceApp?.isEmpty == false ? sourceApp : nil)
            var matchedDomain: String?
            var matchedByCatalogue = false

            if appName == nil || appName?.hasSuffix(".app") == true {
                if let hit = matchHost(host, apps: apps) {
                    appName = hit.app.name
                    matchedDomain = hit.domain
                } else if let hit = matchHost(host, apps: catalog) {
                    appName = hit.app.name
                    matchedDomain = hit.domain
                    matchedByCatalogue = true
                }
            } else if let hit = matchHost(host, apps: apps) {
                matchedDomain = hit.domain
            }

            let domain = matchedDomain ?? host
            let name = appName ?? host
            let base: Double
            if matchedByCatalogue { base = 0.92 }
            else if appName != nil && matchedDomain != nil { base = 0.90 }
            else if appName != nil { base = 0.80 }
            else { base = 0.60 }
            let rationale = "抓包中出现 \(count) 次：\(host) → \(name)"
            add(&candidates, domain: domain, appName: name,
                confidence: base, rationale: rationale)
        }

        // 4. Deduplicate, sort, cap.
        let suggestions = candidates.values.map { candidate -> RuleSuggestion in
            let confidence = min(0.95, max(0.50, candidate.confidence))
            let rule = Rule(kind: .domainSuffix, value: candidate.domain,
                            policy: defaultPolicy, raw: "DOMAIN-SUFFIX,\(candidate.domain),\(defaultPolicy)")
            return RuleSuggestion(id: "\(candidate.domain)#\(candidate.appName)",
                                  appName: candidate.appName,
                                  domain: candidate.domain,
                                  rule: rule,
                                  confidence: confidence,
                                  rationale: candidate.rationale)
        }
        .sorted { lhs, rhs in
            if abs(lhs.confidence - rhs.confidence) > 0.0001 { return lhs.confidence > rhs.confidence }
            if lhs.domain.count != rhs.domain.count { return lhs.domain.count < rhs.domain.count }
            return lhs.domain < rhs.domain
        }
        return Array(suggestions.prefix(maxSuggestions))
    }

    // MARK: - Helpers

    struct Candidate {
        var appName: String
        var domain: String
        var confidence: Double
        var rationale: String
    }

    static func add(_ candidates: inout [String: Candidate], domain: String, appName: String,
                    confidence: Double, rationale: String) {
        if let existing = candidates[domain] {
            guard confidence > existing.confidence else { return }
        }
        candidates[domain] = Candidate(appName: appName, domain: domain,
                                       confidence: confidence, rationale: rationale)
    }

    /// Accepts a bare host, a URL or `host:port`; rejects IPs and local names.
    static func normalizeHost(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.isEmpty == false else { return nil }
        if value.contains("://"), let host = URL(string: value)?.host { value = host }
        if let colon = value.lastIndex(of: ":"), value[value.index(after: colon)...].allSatisfy({ $0.isNumber }),
           value.filter({ $0 == ":" }).count == 1 {
            value = String(value[..<colon])
        }
        while value.hasSuffix(".") { value.removeLast() }
        guard value.contains("."), value.count >= 4 else { return nil }
        if value.hasSuffix(".local") || value.hasSuffix(".lan") || value.hasSuffix(".arpa") { return nil }
        let labels = value.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2,
              tld.allSatisfy({ $0.isLetter }) else { return nil }
        if labels.allSatisfy({ $0.allSatisfy { $0.isNumber } }) { return nil }
        if value == "localhost" { return nil }
        return value
    }

    static func matches(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    static func matchHost(_ host: String, apps: [LearnedApp]) -> (app: LearnedApp, domain: String)? {
        var best: (app: LearnedApp, domain: String)?
        for app in apps {
            for domain in app.domains {
                guard let clean = normalizeHost(domain), matches(host, domain: clean) else { continue }
                if best == nil || clean.count > (best?.domain.count ?? 0) {
                    best = (app, clean)
                }
            }
        }
        return best
    }

    static func matchCatalog(_ app: LearnedApp, catalog: [LearnedApp]) -> LearnedApp? {
        if let bundleID = app.bundleID?.lowercased() {
            for entry in catalog where entry.bundleID?.lowercased() == bundleID { return entry }
        }
        let name = app.name.lowercased().trimmingCharacters(in: .whitespaces)
        for entry in catalog where entry.name.lowercased() == name { return entry }
        for entry in catalog {
            let other = entry.name.lowercased()
            if other.count >= 2 && (name.contains(other) || other.contains(name)) { return entry }
        }
        return nil
    }
}

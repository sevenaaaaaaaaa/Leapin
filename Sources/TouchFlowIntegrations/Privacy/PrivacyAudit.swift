import Foundation
import TouchFlowCore

/// One app → tracker-domain hit found in captured traffic.
public struct PrivacyFinding: Sendable, Identifiable, Hashable {
    public var id: String
    public var app: String
    public var domain: String
    public var category: String
    /// 1 = low (analytics), 2 = medium (attribution/analytics SDK), 3 = high (ad exchange / pixel).
    public var severity: Int

    public init(id: String? = nil, app: String, domain: String, category: String, severity: Int) {
        self.id = id ?? "\(app)|\(domain)"
        self.app = app
        self.domain = domain
        self.category = category
        self.severity = severity
    }
}

public struct PrivacyReport: Sendable, Hashable {
    public var findings: [PrivacyFinding]
    public var trackersBlocked: Int
    /// 0...100, 100 = cleanest.
    public var score: Int

    public init(findings: [PrivacyFinding] = [], trackersBlocked: Int = 0, score: Int = 100) {
        self.findings = findings
        self.trackersBlocked = trackersBlocked
        self.score = score
    }

    public var severityCounts: [Int: Int] {
        findings.reduce(into: [:]) { counts, finding in
            counts[finding.severity, default: 0] += 1
        }
    }
}

/// Scores how clean the captured traffic is with respect to known trackers.
///
/// Formula (documented so the UI can explain it):
///   base = 100
///   − for every distinct (app, tracker-domain) pair: 3 × severity (severity 1...3)
///   − 5 extra for each app that talks to 3 or more distinct trackers
///   score = clamp(base, 0, 100), rounded
/// Empty input returns an empty report with score 100.
public enum PrivacyAudit {
    public static func audit(flows: [FlowEvent], trackerDomains: Set<String>) -> PrivacyReport {
        let trackers = trackerDomains.compactMap { normalizeHost($0) }
        guard flows.isEmpty == false, trackers.isEmpty == false else {
            return PrivacyReport()
        }

        var findings: [PrivacyFinding] = []
        var seen = Set<String>()
        var appDomains: [String: Set<String>] = [:]
        var trackersBlocked = 0

        for flow in flows {
            guard let host = normalizeHost(flow.host) else { continue }
            guard let tracker = matchTracker(host, among: trackers) else { continue }
            trackersBlocked += 1

            let app = (flow.sourceApp?.isEmpty == false ? flow.sourceApp : nil) ?? "未知应用"
            let key = "\(app)|\(tracker)"
            guard seen.insert(key).inserted else { continue }

            let category = TrackerCatalog.category(for: tracker) ?? "跟踪器"
            let severity = TrackerCatalog.severity(for: tracker) ?? 2
            findings.append(PrivacyFinding(id: key, app: app, domain: tracker,
                                           category: category, severity: severity))
            appDomains[app, default: []].insert(tracker)
        }

        var penalty = 0
        for finding in findings {
            penalty += 3 * min(3, max(1, finding.severity))
        }
        for (_, domains) in appDomains where domains.count >= 3 {
            penalty += 5
        }
        let score = min(100, max(0, 100 - penalty))
        let sorted = findings.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            if lhs.app != rhs.app { return lhs.app < rhs.app }
            return lhs.domain < rhs.domain
        }
        return PrivacyReport(findings: sorted, trackersBlocked: trackersBlocked, score: score)
    }

    /// Convenience overload that uses the built-in tracker catalogue.
    public static func audit(flows: [FlowEvent]) -> PrivacyReport {
        audit(flows: flows, trackerDomains: TrackerCatalog.domains)
    }

    static func normalizeHost(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.isEmpty == false else { return nil }
        if let colon = value.lastIndex(of: ":"), value[value.index(after: colon)...].allSatisfy({ $0.isNumber }),
           value.filter({ $0 == ":" }).count == 1 {
            value = String(value[..<colon])
        }
        while value.hasSuffix(".") { value.removeLast() }
        guard value.contains(".") else { return nil }
        return value
    }

    /// Longest suffix match wins, so `ads.doubleclick.net` maps to `doubleclick.net`.
    static func matchTracker(_ host: String, among trackers: [String]) -> String? {
        var best: String?
        for tracker in trackers where host == tracker || host.hasSuffix("." + tracker) {
            if best == nil || tracker.count > (best?.count ?? 0) { best = tracker }
        }
        return best
    }
}

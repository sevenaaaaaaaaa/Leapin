import Foundation

/// Well-known tracker / ad / analytics domains with a category and a severity
/// (1 = analytics only, 2 = attribution or SDK telemetry, 3 = ad exchange or pixel).
public enum TrackerCatalog {
    struct Entry {
        let domain: String
        let category: String
        let severity: Int
    }

    static let entries: [Entry] = [
        // Google
        Entry(domain: "google-analytics.com", category: "分析", severity: 2),
        Entry(domain: "analytics.google.com", category: "分析", severity: 2),
        Entry(domain: "googletagmanager.com", category: "分析", severity: 2),
        Entry(domain: "googlesyndication.com", category: "广告", severity: 3),
        Entry(domain: "googleadservices.com", category: "广告", severity: 3),
        Entry(domain: "doubleclick.net", category: "广告", severity: 3),
        Entry(domain: "2mdn.net", category: "广告", severity: 3),
        Entry(domain: "app-measurement.com", category: "分析", severity: 2),
        Entry(domain: "crashlytics.com", category: "崩溃上报", severity: 1),
        Entry(domain: "firebase-settings.crashlytics.com", category: "崩溃上报", severity: 1),

        // Meta / X / LinkedIn / others
        Entry(domain: "connect.facebook.net", category: "广告", severity: 3),
        Entry(domain: "graph.facebook.com", category: "广告", severity: 3),
        Entry(domain: "facebook.net", category: "广告", severity: 2),
        Entry(domain: "analytics.twitter.com", category: "分析", severity: 2),
        Entry(domain: "ads-twitter.com", category: "广告", severity: 3),
        Entry(domain: "ads.linkedin.com", category: "广告", severity: 3),
        Entry(domain: "ads.tiktok.com", category: "广告", severity: 3),
        Entry(domain: "analytics.tiktok.com", category: "分析", severity: 2),
        Entry(domain: "ads.pinterest.com", category: "广告", severity: 3),
        Entry(domain: "ads.reddit.com", category: "广告", severity: 3),
        Entry(domain: "ads.yahoo.com", category: "广告", severity: 3),
        Entry(domain: "ads.yandex.com", category: "广告", severity: 3),

        // Mobile attribution / analytics SDKs
        Entry(domain: "appsflyer.com", category: "归因", severity: 3),
        Entry(domain: "adjust.com", category: "归因", severity: 3),
        Entry(domain: "branch.io", category: "归因", severity: 2),
        Entry(domain: "kochava.com", category: "归因", severity: 3),
        Entry(domain: "amplitude.com", category: "分析", severity: 2),
        Entry(domain: "mixpanel.com", category: "分析", severity: 2),
        Entry(domain: "segment.io", category: "分析", severity: 2),
        Entry(domain: "segment.com", category: "分析", severity: 2),
        Entry(domain: "hotjar.com", category: "分析", severity: 1),
        Entry(domain: "fullstory.com", category: "分析", severity: 2),
        Entry(domain: "smartlook.com", category: "分析", severity: 1),
        Entry(domain: "flurry.com", category: "分析", severity: 2),
        Entry(domain: "mopub.com", category: "广告", severity: 3),

        // Crash / APM
        Entry(domain: "sentry.io", category: "崩溃上报", severity: 1),
        Entry(domain: "bugsnag.com", category: "崩溃上报", severity: 1),
        Entry(domain: "newrelic.com", category: "崩溃上报", severity: 1),
        Entry(domain: "datadoghq.com", category: "崩溃上报", severity: 1),
        Entry(domain: "bugly.qq.com", category: "崩溃上报", severity: 1),

        // Ad exchanges / SSPs
        Entry(domain: "criteo.com", category: "广告", severity: 3),
        Entry(domain: "criteo.net", category: "广告", severity: 3),
        Entry(domain: "taboola.com", category: "广告", severity: 3),
        Entry(domain: "outbrain.com", category: "广告", severity: 3),
        Entry(domain: "moatads.com", category: "广告", severity: 3),
        Entry(domain: "adnxs.com", category: "广告", severity: 3),
        Entry(domain: "rubiconproject.com", category: "广告", severity: 3),
        Entry(domain: "pubmatic.com", category: "广告", severity: 3),
        Entry(domain: "openx.net", category: "广告", severity: 3),
        Entry(domain: "casalemedia.com", category: "广告", severity: 3),
        Entry(domain: "adsrvr.org", category: "广告", severity: 3),
        Entry(domain: "bidswitch.net", category: "广告", severity: 3),
        Entry(domain: "smartadserver.com", category: "广告", severity: 3),
        Entry(domain: "scorecardresearch.com", category: "数据代理", severity: 3),
        Entry(domain: "quantserve.com", category: "数据代理", severity: 3),
        Entry(domain: "inmobi.com", category: "广告", severity: 3),
        Entry(domain: "applovin.com", category: "广告", severity: 3),
        Entry(domain: "unityads.unity3d.com", category: "广告", severity: 3),
        Entry(domain: "ironsrc.com", category: "广告", severity: 3),
        Entry(domain: "vungle.com", category: "广告", severity: 3),
        Entry(domain: "chartboost.com", category: "广告", severity: 3),
        Entry(domain: "mintegral.com", category: "广告", severity: 3),
        Entry(domain: "pangle.io", category: "广告", severity: 3),

        // China
        Entry(domain: "umeng.com", category: "分析", severity: 2),
        Entry(domain: "umengcloud.com", category: "分析", severity: 2),
        Entry(domain: "cnzz.com", category: "分析", severity: 2),
        Entry(domain: "hm.baidu.com", category: "分析", severity: 2),
        Entry(domain: "pos.baidu.com", category: "广告", severity: 3),
        Entry(domain: "talkingdata.com", category: "分析", severity: 2),
        Entry(domain: "growingio.com", category: "分析", severity: 2),
        Entry(domain: "sensorsdata.cn", category: "分析", severity: 2),
        Entry(domain: "getui.com", category: "分析", severity: 2),
        Entry(domain: "jpush.cn", category: "分析", severity: 2),
        Entry(domain: "51.la", category: "分析", severity: 2),
    ]

    public static let domains: Set<String> = Set(entries.map(\.domain))

    public static let categories: [String: String] = entries.reduce(into: [:]) { result, entry in
        result[entry.domain] = entry.category
    }

    public static let severities: [String: Int] = entries.reduce(into: [:]) { result, entry in
        result[entry.domain] = entry.severity
    }

    public static func category(for host: String) -> String? {
        match(host).map(\.category)
    }

    public static func severity(for host: String) -> Int? {
        match(host).map(\.severity)
    }

    static func match(_ host: String) -> Entry? {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var best: Entry?
        for entry in entries where value == entry.domain || value.hasSuffix("." + entry.domain) {
            if best == nil || entry.domain.count > (best?.domain.count ?? 0) { best = entry }
        }
        return best
    }
}

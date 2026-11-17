import Foundation
import LeapinCore

/// One entry of mihomo's `GET /proxies`: either a policy group (it has `all`)
/// or a dialable proxy (it carries a delay `history`).
public struct KernelProxy: Sendable, Identifiable, Equatable {
    public struct Sample: Sendable, Equatable {
        public var delayMs: Int
        public var at: Date?
        public init(delayMs: Int, at: Date? = nil) { self.delayMs = delayMs; self.at = at }
    }

    public var id: String { name }
    public var name: String
    public var type: String
    public var members: [String]
    public var selected: String?
    public var history: [Sample]
    public var alive: Bool
    public init(name: String, type: String, members: [String] = [], selected: String? = nil,
                history: [Sample] = [], alive: Bool = true) {
        self.name = name; self.type = type; self.members = members
        self.selected = selected; self.history = history; self.alive = alive
    }

    public var isGroup: Bool { !members.isEmpty }
    /// Only a Selector accepts `PUT /proxies/{name}`; url-test and load-balance
    /// groups pick their own member and the kernel rejects a manual choice.
    public var isSelectable: Bool {
        isGroup && ["selector", "select"].contains(type.lowercased())
    }
    /// DIRECT / REJECT / PASS-RULE style pseudo nodes: shown, never measured.
    public var isBuiltin: Bool {
        ["direct", "reject", "rejectdrop", "compatible", "pass", "passrule", "dns"].contains(type.lowercased())
    }
    /// DIRECT stays measurable as the baseline; REJECT / PASS-RULE answer without
    /// dialling, so a number for them would be meaningless.
    public var isTestable: Bool {
        guard !isGroup else { return false }
        return !["reject", "rejectdrop", "pass", "passrule", "compatible", "dns"].contains(type.lowercased())
    }

    /// The last measurement the kernel kept for this node.
    public var latestLatencyMs: Int? {
        history.last(where: { $0.delayMs > 0 })?.delayMs
    }
    public var latestSampleAt: Date? { history.last?.at }
    public var lastTestFailed: Bool { history.last.map { $0.delayMs <= 0 } ?? false }
}

extension KernelProxy {
    /// Parses `{"proxies": {"NAME": {...}}}`. Throws when the payload is not the
    /// shape mihomo documents, so a protocol change surfaces instead of an empty menu.
    public static func parse(_ data: Data) throws -> [KernelProxy] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proxies = root["proxies"] as? [String: [String: Any]] else {
            throw LeapinError.protocolError("内核返回了无法识别的代理数据")
        }
        return proxies.map { name, object in
            let history = (object["history"] as? [[String: Any]] ?? []).compactMap { sample -> Sample? in
                guard let delay = sample["delay"] as? Int else { return nil }
                return Sample(delayMs: delay, at: (sample["time"] as? String).flatMap(Self.date(from:)))
            }
            return KernelProxy(name: name,
                               type: object["type"] as? String ?? "",
                               members: object["all"] as? [String] ?? [],
                               selected: object["now"] as? String,
                               history: history,
                               alive: object["alive"] as? Bool ?? true)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// mihomo stamps history with RFC 3339 in its own time zone.
    static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// Groups first (GLOBAL on top), then the dialable nodes.
    public static func ordered(_ proxies: [KernelProxy]) -> [KernelProxy] {
        func rank(_ proxy: KernelProxy) -> (Int, String) {
            if proxy.name.uppercased() == "GLOBAL" { return (0, proxy.name) }
            if proxy.isSelectable { return (1, proxy.name) }
            if proxy.isGroup { return (2, proxy.name) }
            if proxy.isBuiltin { return (4, proxy.name) }
            return (3, proxy.name)
        }
        return proxies.sorted { lhs, rhs in
            let l = rank(lhs), r = rank(rhs)
            return l.0 == r.0 ? l.1.localizedStandardCompare(r.1) == .orderedAscending : l.0 < r.0
        }
    }
}

import Foundation
import LeapinCore

/// An application (or web service) that rules can be suggested for.
public struct LearnedApp: Sendable, Codable, Identifiable, Hashable {
    public var name: String
    public var bundleID: String?
    public var domains: [String]
    /// Where the entry came from: "catalog", "user", "ocr" or "flow".
    public var source: String

    /// Stable identity: bundle id when known, otherwise the display name.
    public var id: String { bundleID ?? name }

    public init(name: String, bundleID: String? = nil, domains: [String] = [], source: String = "user") {
        self.name = name
        self.bundleID = bundleID
        self.domains = domains
        self.source = source
    }

    public var primaryDomain: String? { domains.first }
}

/// Raw text recognition result from a screenshot.
public struct OCRResult: Sendable, Hashable {
    public var text: String
    public var lines: [String]
    /// Mean per-line confidence, 0...1.
    public var confidence: Double

    public init(text: String, lines: [String], confidence: Double) {
        self.text = text
        self.lines = lines
        self.confidence = confidence
    }
}

/// A proposed routing rule derived from learned apps and captured flows.
public struct RuleSuggestion: Sendable, Identifiable, Hashable {
    public var id: String
    public var appName: String
    public var domain: String
    public var rule: Rule
    public var confidence: Double
    public var rationale: String

    public init(id: String, appName: String, domain: String, rule: Rule,
                confidence: Double, rationale: String) {
        self.id = id
        self.appName = appName
        self.domain = domain
        self.rule = rule
        self.confidence = confidence
        self.rationale = rationale
    }
}

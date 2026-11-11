import XCTest
import LeapinCore
@testable import LeapinRuntime

final class NetworkDiagnosticsTests: XCTestCase {
    func testHEADUnsupportedIsNotReportedAsBrokenProxy() {
        let report = NetworkDiagnosticAnalyzer.analyze(NetworkDiagnosticInput(state: .running, systemProxyActive: true,
            target: "https://example.com/", proxy: HTTPProbeResult(url: "https://example.com/", statusCode: 405)))
        XCTAssertEqual(report.problemCount, 0)
        XCTAssertTrue(report.findings.contains(where: { $0.id == "head" }))
    }
    func testProxyFailureAndDirectSuccessAreLabeledDifferentMethods() {
        let report = NetworkDiagnosticAnalyzer.analyze(NetworkDiagnosticInput(state: .running, target: "https://example.com/",
            direct: HTTPProbeResult(url: "https://example.com/", statusCode: 200),
            proxy: HTTPProbeResult(url: "https://example.com/", error: "TLS certificate failed")))
        let finding = report.findings.first(where: { $0.id == "proxy-path" })
        XCTAssertTrue(finding?.isProblem == true)
        XCTAssertTrue(finding?.detail.contains("GET") == true)
        XCTAssertTrue(finding?.detail.contains("HEAD") == true)
        XCTAssertFalse(report.copyText.contains("已发生中间人攻击"))
    }
    func testCaptureChecksDistinguishUnsupportedAndUnknownTrust() {
        let managed = NetworkDiagnosticAnalyzer.analyze(NetworkDiagnosticInput(state: .running, kernel: .mihomo,
            managedRunning: true, captureEnabled: false, captureCheck: true))
        XCTAssertTrue(managed.findings.contains(where: { $0.id == "mitm-managed" && $0.isProblem }))
        XCTAssertTrue(managed.findings.contains(where: { $0.id == "capture-off" }))
        let native = NetworkDiagnosticAnalyzer.analyze(NetworkDiagnosticInput(state: .running, mitmEnabled: true,
            certificateExists: true, captureCheck: true))
        let ca = native.findings.first(where: { $0.id == "ca-present" })
        XCTAssertTrue(ca?.title.contains("未验证") == true)
        XCTAssertFalse(ca?.isProblem ?? true)
        XCTAssertTrue(native.findings.contains(where: { $0.id == "no-samples" && !$0.isProblem }))
    }
    func testLogTimeWindowClusteringAndSafeSummary() {
        let now = Date()
        let logs = [
            LogEntry(date: now.addingTimeInterval(-1000), level: .error, category: "dns", message: "DNS old"),
            LogEntry(date: now.addingTimeInterval(-5), level: .error, category: "tls", message: "TLS failed password: private-value"),
            LogEntry(date: now.addingTimeInterval(-4), level: .warning, category: "tls", message: "certificate failed uuid: private-uuid"),
            LogEntry(date: now, level: .info, category: "dns", message: "DNS trace success")]
        let report = NetworkDiagnosticAnalyzer.analyze(NetworkDiagnosticInput(state: .running, kernel: .mihomo,
            logs: logs, managedLogs: "DNS failed token: private-token\nTLS old event without timestamp", date: now))
        XCTAssertEqual(report.logClusters.first(where: { $0.source == "Leapin" })?.count, 2)
        XCTAssertNil(report.logClusters.first(where: { $0.source == "Mihomo" })?.first)
        XCTAssertFalse(report.logClusters.map(\.sample).joined().contains("private-value"))
        XCTAssertFalse(report.logClusters.map(\.sample).joined().contains("private-uuid"))
        XCTAssertFalse(report.copyText.contains("private-token"))
        XCTAssertFalse(report.copyText.contains("TLS old event"))
        XCTAssertTrue(report.findings.contains(where: { $0.id == "tls-hint" && !$0.isProblem }))
    }
    func testFailedPortStateHasSpecificNonDestructiveAction() {
        let report = NetworkDiagnosticAnalyzer.analyze(NetworkDiagnosticInput(state: .failed("Address already in use")))
        XCTAssertEqual(report.findings.first?.action, .settings)
        XCTAssertTrue(report.copyText.contains("不会自动结束"))
        XCTAssertTrue(report.findings.contains(where: { $0.id == "scope" }))
    }
}

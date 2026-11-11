import XCTest
@testable import LeapinIntegrations

final class SystemVPNConnectorTests: XCTestCase {
    func testListParsingAcceptsOnlyValidConfiguredIDs() {
        let id = UUID()
        let list = "Available connections:\n* (Disconnected) \(id.uuidString) IPSec --> VPN \"Fixture Company\" [IPSec]\n(Connected) not-a-service-id IPSec \"Reject\""
        let services = SystemVPNService.parse(list)
        XCTAssertEqual(services.count, 1); XCTAssertEqual(services.first?.id, id)
        XCTAssertEqual(services.first?.name, "Fixture Company")
    }
    func testStartVerifiesExistingServiceAndPassesNoCredentialsOrStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(); let executable = root.appendingPathComponent("scutil-fixture")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$0.args"
        if [ "$2" = list ]; then echo '* (Disconnected) \(id.uuidString) IPSec --> VPN "Fixture" [IPSec]'; fi
        if [ "$2" = status ]; then echo Connecting; fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let connector = SystemVPNConnector(executable: executable)
        let status = try await connector.start(id)
        XCTAssertEqual(status, "Connecting")
        do { _ = try await connector.start(UUID()); XCTFail("Must reject missing service") } catch {}
        let args = try String(contentsOf: executable.appendingPathExtension("args"), encoding: .utf8)
        XCTAssertTrue(args.contains("--nc start \(id.uuidString)"))
        XCTAssertFalse(args.contains("--password")); XCTAssertFalse(args.contains("--secret")); XCTAssertFalse(args.contains("stop"))
    }
}

import XCTest
@testable import LeapinCore

final class SmokeTests: XCTestCase {
    func testYAMLBasics() throws {
        let yaml = """
        name: demo
        rules:
          - DOMAIN,example.com,DIRECT
          - MATCH,PROXY
        ports:
          mixed: 7890
        """
        let dict = try MiniYAML.parseDictionary(yaml)
        XCTAssertEqual(dict["name"]?.string, "demo")
        XCTAssertEqual(dict["rules"]?.array?.count, 2)
        XCTAssertEqual(dict["ports"]?["mixed"]?.int, 7890)
    }
}

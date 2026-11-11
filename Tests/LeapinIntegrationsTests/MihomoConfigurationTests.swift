import XCTest
import LeapinCore
@testable import LeapinIntegrations

final class MihomoConfigurationTests: XCTestCase {
    func testManagedOverlayPreservesProtocolsAndOverridesEveryHostOwnedListener() throws {
        let source = """
        'mixed-port': 9999
        allow-lan: true
        listeners:
          - name: public
            type: mixed
            port: 9876
        tunnels:
          - network: tcp
            address: 0.0.0.0:9888
            target: 192.0.2.1:80
        tun:
          enable: true
        dns:
          enable: true
          listen: 0.0.0.0:53
        external-controller: 0.0.0.0:9090
        secret: original-secret
        mode: global
        proxies:
          - name: vless-node
            type: vless
            server: 192.0.2.1
            port: 443
            uuid: 11111111-1111-4111-8111-111111111111
            network: ws
            ws-opts:
              path: /transport
        rules:
          - MATCH,DIRECT
        """
        let output = try MihomoConfiguration.managed(source, proxyPort: 19001, controllerPort: 19002, secret: "new-secret")
        let old = try MiniYAML.parse(source)
        let new = try MiniYAML.parse(output)
        XCTAssertEqual(new["proxies"], old["proxies"])
        XCTAssertEqual(new["rules"], old["rules"])
        XCTAssertEqual(new["mode"]?.string, "global")
        XCTAssertEqual(new["mixed-port"]?.int, 19001)
        XCTAssertEqual(new["external-controller"]?.string, "127.0.0.1:19002")
        XCTAssertEqual(new["tun"]?["enable"]?.bool, false)
        XCTAssertEqual(new["dns"]?["enable"]?.bool, true)
        XCTAssertEqual(new["dns"]?["listen"]?.string, "")
        XCTAssertEqual(new["allow-lan"]?.bool, false)
        XCTAssertEqual(new["listeners"]?.array?.count, 0)
        XCTAssertFalse(output.contains("original-secret"))
        XCTAssertFalse(output.contains("9876"))
        XCTAssertFalse(output.contains("9888"))
        XCTAssertNil(new["tunnels"])
    }

    func testOverlayRejectsInvalidPortsAndMalformedYamlRatherThanDroppingIt() {
        XCTAssertThrowsError(try MihomoConfiguration.managed("rules: []", proxyPort: 0, controllerPort: 5, secret: "x"))
        XCTAssertThrowsError(try MihomoConfiguration.managed("rules: []", proxyPort: 5, controllerPort: 5, secret: "x"))
        XCTAssertThrowsError(try MihomoConfiguration.managed("rules:\n  - MATCH,DIRECT\n  malformed trailing line", proxyPort: 5, controllerPort: 6, secret: "x"))
    }

    func testKernelDiagnosticsRedactYamlSecretsAndNodeUris() {
        let input = "password: topsecret, token: 'another-secret'\nvless://uuid@example.com:443\nsecret=third-secret"
        let output = Redactor.redact(input)
        for value in ["topsecret", "another-secret", "uuid@example.com", "third-secret"] {
            XCTAssertFalse(output.contains(value))
        }
    }
}

extension MihomoConfigurationTests {
    func testSourceDNSPolicyRetainedWithoutExposingSourceListener() throws {
        let source = """
        dns:
          enable: false
          listen: 0.0.0.0:53
          enhanced-mode: redir-host
          ipv6: false
          respect-rules: true
          nameserver:
            - udp://127.0.0.1:15553
          nameserver-policy:
            '*.fixture.invalid': [udp://127.0.0.1:15554]
          fallback-filter:
            geoip: false
            ipcidr: [240.0.0.0/4]
        rules: [MATCH,DIRECT]
        """
        let before = try MiniYAML.parse(source)
        let result = try MihomoConfiguration.managed(source, proxyPort: 18080, controllerPort: 18081, secret: "test")
        let after = try MiniYAML.parse(result)
        for key in ["enhanced-mode", "ipv6", "respect-rules", "nameserver", "nameserver-policy", "fallback-filter"] {
            XCTAssertEqual(before["dns"]?[key], after["dns"]?[key], key)
        }
        XCTAssertEqual(after["dns"]?["listen"]?.string, "")
        XCTAssertEqual(after["dns"]?["enable"]?.bool, true)
        XCTAssertFalse(result.contains("0.0.0.0:53"))
    }
    func testTUNIsExplicitAndKeepsTailnetExcluded() throws {
        let standard = try MiniYAML.parse(MihomoConfiguration.managed("rules: [MATCH,DIRECT]", proxyPort: 18080, controllerPort: 18081, secret: "test"))
        XCTAssertEqual(standard["tun"]?["enable"]?.bool, false)
        let enabled = try MiniYAML.parse(MihomoConfiguration.managed("rules: [MATCH,DIRECT]", proxyPort: 18080, controllerPort: 18081, secret: "test", tun: true, tunDevice: "utun1001"))
        XCTAssertEqual(enabled["tun"]?["enable"]?.bool, true)
        XCTAssertEqual(enabled["tun"]?["device"]?.string, "utun1001")
        XCTAssertTrue(enabled["tun"]?["route-exclude-address"]?.stringArray?.contains("100.64.0.0/10") == true)
        XCTAssertThrowsError(try MihomoConfiguration.managed("dns: true", proxyPort: 1, controllerPort: 2, secret: "test"))
    }
}

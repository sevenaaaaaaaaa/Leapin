import XCTest
@testable import LeapinRuntime
import LeapinCore

/// The import preflight must separate two different facts:
/// "the native kernel cannot dial this" from "this subscription is unusable".
final class ImportCompatibilityTests: XCTestCase {
    private let clash = """
    proxies:
      - name: "香港 01"
        type: vless
        server: hk1.example.com
        port: 443
        uuid: 11111111-2222-3333-4444-555555555555
        network: ws
        tls: true
        skip-cert-verify: true
      - name: "美国 01"
        type: ss
        server: us1.example.com
        port: 8388
        cipher: aes-256-gcm
        password: secret
        skip-cert-verify: true
    proxy-groups:
      - name: Proxy
        type: select
        proxies: ["香港 01", "美国 01"]
    rules:
      - MATCH,Proxy
    """

    func testNativeBlockersNameTheProtocolButKeepTheSource() throws {
        let preparation = try ImportPreparation(text: clash, name: "一元机场", pathExtension: "yaml")

        XCTAssertTrue(preparation.nativeBlockers.contains { $0.contains("vless") },
                      "vless must be reported as a native limitation: \(preparation.nativeBlockers)")
        XCTAssertTrue(preparation.nativeBlockers.contains { $0.contains("跳过证书校验") },
                      "skip-cert-verify must be reported too: \(preparation.nativeBlockers)")

        // The original Clash text is what the Mihomo kernel runs, so the nodes have to
        // survive verbatim — that is the difference between "native can't" and "we lost it".
        XCTAssertTrue(preparation.clashSource.contains("type: vless"), "clash source lost the vless node")
        XCTAssertTrue(preparation.clashSource.contains("skip-cert-verify: true"), "clash source lost skip-cert-verify")
        XCTAssertEqual(preparation.externalConversionBlockers, [],
                       "a raw Clash source must not be reported as lossy for Mihomo")
    }

    func testCleanConfigHasNoNativeBlockers() throws {
        let simple = """
        proxies:
          - name: "Tokyo"
            type: ss
            server: t.example.com
            port: 8388
            cipher: aes-256-gcm
            password: secret
        rules:
          - MATCH,DIRECT
        """
        let preparation = try ImportPreparation(text: simple, name: "plain", pathExtension: "yaml")
        XCTAssertEqual(preparation.nativeBlockers, [])
    }
}

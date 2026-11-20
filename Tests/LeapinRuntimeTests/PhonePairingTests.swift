import XCTest
@testable import LeapinRuntime

/// The phone can only pair if the Mac reports an address it can actually reach,
/// so the LAN detection and the payload have to be right before the QR exists.
final class PhonePairingTests: XCTestCase {
    func testPrivateRangesAreRecognised() {
        XCTAssertTrue(PhonePairing.isPrivateIPv4("10.230.21.61"))
        XCTAssertTrue(PhonePairing.isPrivateIPv4("172.16.0.1"))
        XCTAssertTrue(PhonePairing.isPrivateIPv4("172.31.255.254"))
        XCTAssertTrue(PhonePairing.isPrivateIPv4("192.168.1.10"))
        XCTAssertTrue(PhonePairing.isPrivateIPv4("169.254.3.4"))
        XCTAssertFalse(PhonePairing.isPrivateIPv4("8.8.8.8"), "public DNS must never be offered as the Mac address")
        XCTAssertFalse(PhonePairing.isPrivateIPv4("172.32.0.1"), "172.32 is outside the private block")
        XCTAssertFalse(PhonePairing.isPrivateIPv4("not-an-ip"))
    }

    func testPairingURLShapeAndParse() {
        let pairing = PhonePairing(host: "192.168.1.8", port: 7900, token: "abc123",
                                   lanEnabled: true, controlRunning: true, blockers: [])
        XCTAssertEqual(pairing.pairingURL,
                       "leapin://pair?host=192.168.1.8&port=7900&token=abc123")

        // The phone parses this exact shape back into an endpoint.
        let url = URL(string: pairing.pairingURL)
        XCTAssertEqual(url?.scheme, "leapin")
        XCTAssertEqual(url?.host, "pair")
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "host" }?.value, "192.168.1.8")
        XCTAssertEqual(items.first { $0.name == "port" }?.value, "7900")
        XCTAssertEqual(items.first { $0.name == "token" }?.value, "abc123")
    }

    func testLANAddressIsPrivateWhenPresent() {
        guard let address = PhonePairing.lanAddress() else {
            return // a Mac with no Wi-Fi/Ethernet is a legitimate case
        }
        XCTAssertTrue(PhonePairing.isPrivateIPv4(address), "offered \(address) to a phone on the same Wi-Fi")
    }
}

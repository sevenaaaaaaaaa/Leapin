import Foundation
import XCTest
@testable import LeapinCore
@testable import LeapinNet

/// Trojan request format tests. The SHA-224 digests are standard FIPS 180-4
/// values cross-checked with `shasum -a 224`.
final class TrojanTests: XCTestCase {
    private let sha224OfPassword = "d63dc919e201d7bc4c825630d2cf25fdc93d4b2f0d46706d29038d01"

    func testSHA224KnownVectors() {
        XCTAssertEqual(SHA224.hexDigest("abc"), "23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7")
        XCTAssertEqual(SHA224.hexDigest(""), "d14a028c2a3a2bc9476102bb288234c415a2b01f828ea62ac5b3e42f")
        XCTAssertEqual(SHA224.hexDigest("password"), sha224OfPassword)
        XCTAssertEqual(SHA224.hash(Data("abc".utf8)).count, 28)
    }

    func testPasswordHashIsHexSHA224() {
        XCTAssertEqual(TrojanProtocol.passwordHash("password"), sha224OfPassword)
        XCTAssertEqual(TrojanProtocol.passwordHash("trojan-test"),
                       "bbc9e2a4490c88bbd7eb39aee70f5356a85499f3655174697ee4e198")
    }

    func testRequestHeadLayoutForDomain() throws {
        let head = try TrojanProtocol.requestHead(password: "password", host: "example.com", port: 443)
        let hash = Data(sha224OfPassword.utf8)
        // hash + CRLF + cmd + ATYP=3 + len + host + port + CRLF
        XCTAssertEqual(head.count, hash.count + 2 + 1 + 1 + 1 + "example.com".utf8.count + 2 + 2)
        XCTAssertEqual(head.prefix(hash.count), hash)
        var index = hash.count
        XCTAssertEqual(head[index], 0x0D)
        XCTAssertEqual(head[index + 1], 0x0A)
        index += 2
        XCTAssertEqual(head[index], TrojanProtocol.connectCommand)
        index += 1
        XCTAssertEqual(head[index], SOCKS5.AddressType.domain.rawValue)
        index += 1
        XCTAssertEqual(head[index], UInt8("example.com".utf8.count))
        index += 1
        XCTAssertEqual(String(decoding: head.subdata(in: index..<(index + 11)), as: UTF8.self), "example.com")
        index += 11
        XCTAssertEqual(Array(head.subdata(in: index..<(index + 2))), [0x01, 0xBB]) // 443
        index += 2
        XCTAssertEqual(Array(head.subdata(in: index..<(index + 2))), [0x0D, 0x0A])
    }

    func testRequestHeadLayoutForIPv4() throws {
        let head = try TrojanProtocol.requestHead(password: "password", host: "192.0.2.10", port: 8443)
        let hashCount = 56
        XCTAssertEqual(head[hashCount + 2], TrojanProtocol.connectCommand)
        XCTAssertEqual(head[hashCount + 3], SOCKS5.AddressType.ipv4.rawValue)
        XCTAssertEqual(Array(head.subdata(in: (hashCount + 4)..<(hashCount + 8))), [192, 0, 2, 10])
        XCTAssertEqual(Array(head.subdata(in: (hashCount + 8)..<(hashCount + 10))), [0x20, 0xFB]) // 8443
    }

    func testRequestHeadDefaultsAndUDPCommand() throws {
        XCTAssertEqual(TrojanProtocol.defaultPort, 443)
        XCTAssertEqual(TrojanProtocol.udpAssociateCommand, 0x03)
        let head = try TrojanProtocol.requestHead(password: "password",
                                                 host: "example.com",
                                                 port: 443,
                                                 command: TrojanProtocol.udpAssociateCommand)
        XCTAssertEqual(head[58], TrojanProtocol.udpAssociateCommand)
    }
}

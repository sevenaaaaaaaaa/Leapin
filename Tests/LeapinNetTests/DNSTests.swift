import Foundation
import XCTest
@testable import LeapinCore
@testable import LeapinNet

/// DNS codec, resolver policy, cache behaviour and local DNS server tests.
final class DNSTests: XCTestCase {
    private static let answerIPv4 = Data([93, 184, 216, 34])

    // MARK: - Codec

    func testQueryRoundTrip() throws {
        let query = DNSMessage.query("www.example.com", type: .a, id: 0x1234)
        let decoded = try DNSMessage.decode(query.encode())
        XCTAssertEqual(decoded.id, 0x1234)
        XCTAssertFalse(decoded.isResponse)
        XCTAssertTrue(decoded.recursionDesired)
        XCTAssertEqual(decoded.questions.count, 1)
        XCTAssertEqual(decoded.questions.first?.name, "www.example.com")
        XCTAssertEqual(decoded.questions.first?.type, .a)
        XCTAssertEqual(decoded.questions.first?.qclass, 1)
        XCTAssertTrue(decoded.answers.isEmpty)
    }

    func testReplyRoundTripWithMixedAnswers() throws {
        let query = DNSMessage.query("mixed.test", type: .a, id: 0xABCD)
        let answers = [
            DNSResourceRecord(name: "mixed.test", type: .cname, ttl: 120,
                              rdata: DNSMessage.encodeName("target.test")),
            DNSResourceRecord(name: "target.test", type: .a, ttl: 60,
                              rdata: Self.answerIPv4),
            DNSResourceRecord(name: "target.test", type: .aaaa, ttl: 60,
                              rdata: Data(repeating: 0x20, count: 16))
        ]
        let reply = DNSMessage.reply(to: query, rcode: .noError, answers: answers)
        let decoded = try DNSMessage.decode(reply.encode())
        XCTAssertEqual(decoded.id, 0xABCD)
        XCTAssertTrue(decoded.isResponse)
        XCTAssertTrue(decoded.isSuccess)
        XCTAssertEqual(decoded.questions.first?.name, "mixed.test")
        XCTAssertEqual(decoded.answers.count, 3)
        let cnameTargets = decoded.cnameRecords
        XCTAssertEqual(cnameTargets, ["target.test"])
        XCTAssertEqual(decoded.aRecords, ["93.184.216.34"])
        XCTAssertEqual(decoded.resolvedAddresses, ["93.184.216.34"])
        XCTAssertEqual(decoded.minimumTTL, 60)
    }

    func testDecodesCompressionPointerNames() throws {
        var bytes: [UInt8] = []
        func u16(_ value: UInt16) {
            bytes.append(UInt8(value >> 8))
            bytes.append(UInt8(value & 0xFF))
        }
        func u32(_ value: UInt32) {
            bytes.append(UInt8((value >> 24) & 0xFF))
            bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8(value & 0xFF))
        }
        u16(0x0102)      // id
        u16(0x8180)      // response + recursion desired/available
        u16(1)           // qdcount
        u16(1)           // ancount
        u16(0)           // nscount
        u16(0)           // arcount
        for label in ["example", "com"] {
            bytes.append(UInt8(label.utf8.count))
            bytes.append(contentsOf: label.utf8)
        }
        bytes.append(0)  // root
        u16(1)           // qtype A
        u16(1)           // qclass IN
        // Answer name is a 0xC00C pointer back to the question name at offset 12.
        bytes.append(0xC0)
        bytes.append(0x0C)
        u16(1)           // type A
        u16(1)           // class IN
        u32(60)          // ttl
        u16(4)           // rdlength
        bytes.append(contentsOf: [93, 184, 216, 34])

        let decoded = try DNSMessage.decode(Data(bytes))
        XCTAssertEqual(decoded.questions.first?.name, "example.com")
        XCTAssertEqual(decoded.answers.count, 1)
        XCTAssertEqual(decoded.answers.first?.name, "example.com")
        XCTAssertEqual(decoded.answers.first?.ipv4Address, "93.184.216.34")
    }

    func testDecodeRejectsTruncatedAndLoopingMessages() {
        XCTAssertThrowsError(try DNSMessage.decode(Data([0x00])))
        // Pointer that points at itself must be rejected, not loop forever.
        let looping = Data([0x00, 0x01, 0x81, 0x80, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01])
        XCTAssertThrowsError(try DNSMessage.decode(looping))
    }

    func testErrorsClearAnswers() {
        let query = DNSMessage.query("blocked.test", type: .a, id: 7)
        let reply = DNSMessage.reply(to: query,
                                     rcode: .nameError,
                                     answers: [DNSResourceRecord(name: "blocked.test", type: .a, ttl: 60,
                                                                 rdata: Self.answerIPv4)])
        XCTAssertEqual(reply.rcode, DNSRCode.nameError.rawValue)
        XCTAssertTrue(reply.answers.isEmpty)
        XCTAssertFalse(reply.isSuccess)
    }

    // MARK: - Resolver policy (no network)

    func testHostsHitSkipsNetworkEntirely() async throws {
        let resolver = DNSResolver(config: DNSConfig(mode: .system,
                                                     upstreams: [],
                                                     fallback: [],
                                                     hosts: ["local.test": "10.1.2.3, 10.1.2.4"]),
                                   blocker: nil)
        let addresses = try await resolver.resolve("local.test")
        XCTAssertEqual(addresses, ["10.1.2.3", "10.1.2.4"])
        // Lookup is case-insensitive.
        let uppercase = try await resolver.resolve("LOCAL.Test")
        XCTAssertEqual(uppercase, ["10.1.2.3", "10.1.2.4"])
    }

    func testIPLiteralResolvesToItself() async throws {
        let resolver = DNSResolver(config: DNSConfig(mode: .system, upstreams: [], fallback: []),
                                   blocker: nil)
        let literal = try await resolver.resolve("192.0.2.7")
        XCTAssertEqual(literal, ["192.0.2.7"])
        let v6 = try await resolver.resolve("::1")
        XCTAssertEqual(v6.count, 1)
    }

    func testBlockerProducesNXDOMAIN() async throws {
        let blocker = StaticBlocker(blocked: ["ads.test": "adlist"])
        let resolver = DNSResolver(config: DNSConfig(mode: .system,
                                                     upstreams: [],
                                                     fallback: [],
                                                     blockResponse: "nxdomain"),
                                   blocker: blocker)
        do {
            _ = try await resolver.resolve("ads.test")
            XCTFail("blocked domain must not resolve")
        } catch let error as LeapinError {
            guard case .blocked(let reason) = error else {
                XCTFail("expected .blocked, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("adlist"), "reason should carry the block source: \(reason)")
        }

        let reply = await resolver.respond(to: DNSMessage.query("ads.test", id: 0x55))
        XCTAssertEqual(reply.rcode, DNSRCode.nameError.rawValue)
        XCTAssertTrue(reply.answers.isEmpty)
        XCTAssertEqual(reply.id, 0x55)
        // A non-blocked name is not answered with NXDOMAIN by the blocker path.
        let allowed = await resolver.respond(to: DNSMessage.query("localhost", type: .a, id: 1))
        XCTAssertNotEqual(allowed.rcode, DNSRCode.nameError.rawValue)
    }

    func testBlockerCanReturnZeroAddress() async throws {
        let blocker = StaticBlocker(blocked: ["tracker.test": "easylist"])
        let resolver = DNSResolver(config: DNSConfig(mode: .system,
                                                     upstreams: [],
                                                     fallback: [],
                                                     blockResponse: "0.0.0.0"),
                                   blocker: blocker)
        let zeroed = try await resolver.resolve("tracker.test")
        XCTAssertEqual(zeroed, ["0.0.0.0"])
        let reply = await resolver.respond(to: DNSMessage.query("tracker.test", id: 9))
        XCTAssertEqual(reply.resolvedAddresses, ["0.0.0.0"])
        XCTAssertEqual(reply.rcode, DNSRCode.noError.rawValue)
    }

    // MARK: - Cache behaviour (against a local fake upstream)

    func testCacheServesSecondLookupWithoutQuerying() async throws {
        let upstream = try await makeUpstream()
        let resolver = makeResolver(upstream: upstream, cacheTTL: 300)

        let first = try await resolver.resolve("cache.test")
        XCTAssertEqual(first, ["93.184.216.34"])
        XCTAssertEqual(upstream.queryCount, 1)

        let countBefore = upstream.queryCount
        let second = try await resolver.resolve("cache.test")
        XCTAssertEqual(second, first)
        XCTAssertEqual(upstream.queryCount, countBefore, "second lookup must be served from cache")

        let cached = await resolver.cachedEntryCount()
        XCTAssertGreaterThanOrEqual(cached, 1)
    }

    func testCacheExpiresAfterTTL() async throws {
        let upstream = try await makeUpstream()
        let resolver = makeResolver(upstream: upstream, cacheTTL: 1)

        _ = try await resolver.resolve("expiring.test")
        let afterFirst = upstream.queryCount
        XCTAssertEqual(afterFirst, 1)

        try await Task.sleep(nanoseconds: 1_300_000_000)
        _ = try await resolver.resolve("expiring.test")
        XCTAssertGreaterThan(upstream.queryCount, afterFirst, "expired entry must trigger a new query")
    }

    func testFlushCacheForcesNewQuery() async throws {
        let upstream = try await makeUpstream()
        let resolver = makeResolver(upstream: upstream, cacheTTL: 300)

        _ = try await resolver.resolve("flush.test")
        let afterFirst = upstream.queryCount
        resolver.flushCache()
        // flushCache is documented as fire-and-forget, so wait for the actor.
        var cached = await resolver.cachedEntryCount()
        var waited = 0
        while cached != 0 && waited < 100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            cached = await resolver.cachedEntryCount()
            waited += 1
        }
        XCTAssertEqual(cached, 0)
        _ = try await resolver.resolve("flush.test")
        XCTAssertGreaterThan(upstream.queryCount, afterFirst)
    }

    func testNegativeAnswerIsCached() async throws {
        let upstream = try await FakeDNSServer.start { query in
            DNSMessage.reply(to: query, rcode: .nameError)
        }
        let resolver = DNSResolver(config: DNSConfig(mode: .doh,
                                                     upstreams: ["udp://127.0.0.1:\(upstream.port)"],
                                                     fallback: [],
                                                     cacheTTL: 300),
                                   blocker: nil)
        var firstError: Error?
        do {
            _ = try await resolver.resolve("nx.test")
        } catch {
            firstError = error
        }
        XCTAssertNotNil(firstError, "NXDOMAIN must fail resolution")
        let afterFirst = upstream.queryCount
        XCTAssertGreaterThan(afterFirst, 0)

        do {
            _ = try await resolver.resolve("nx.test")
            XCTFail("negative cache must keep failing")
        } catch let error as LeapinError {
            guard case .connectionFailed(let detail) = error else {
                XCTFail("expected negative-cache connectionFailed, got \(error)")
                return
            }
            XCTAssertTrue(detail.contains("negative cache"), "unexpected detail: \(detail)")
        }
        XCTAssertEqual(upstream.queryCount, afterFirst, "negative cache must not re-query")
    }

    func testConcurrentLookupsAreDeduplicated() async throws {
        let upstream = try await makeUpstream()
        let resolver = makeResolver(upstream: upstream, cacheTTL: 300)

        let results = await withTaskGroup(of: [String]?.self) { group -> [[String]?] in
            for _ in 0..<5 {
                group.addTask {
                    try? await resolver.resolve("concurrent.test")
                }
            }
            var collected: [[String]?] = []
            for await value in group { collected.append(value) }
            return collected
        }
        XCTAssertEqual(results.count, 5)
        for value in results {
            XCTAssertEqual(value, ["93.184.216.34"])
        }
        XCTAssertEqual(upstream.queryCount, 1, "in-flight lookups must share one query")
    }

    // MARK: - Local DNS server

    func testDNSServerAnswersUDPQueryThroughResolver() async throws {
        let upstream = try await makeUpstream()
        let resolver = makeResolver(upstream: upstream, cacheTTL: 300)
        let (server, port) = try startServer(resolver: resolver, fakeIP: nil)
        defer { server.stop() }

        let query = DNSMessage.query("server.test", type: .a, id: 0x4242)
        let raw = try await DNSDatagram.exchange(host: "127.0.0.1",
                                                port: port,
                                                payload: query.encode(),
                                                timeout: 3)
        let reply = try DNSMessage.decode(raw)
        XCTAssertEqual(reply.id, 0x4242)
        XCTAssertTrue(reply.isResponse)
        XCTAssertEqual(reply.resolvedAddresses, ["93.184.216.34"])
        XCTAssertGreaterThanOrEqual(upstream.queryCount, 1)
    }

    func testDNSServerServesHostsAndBlocksFromConfig() async throws {
        let blocker = StaticBlocker(blocked: ["blocked.test": "list"])
        let resolver = DNSResolver(config: DNSConfig(mode: .system,
                                                     upstreams: [],
                                                     fallback: [],
                                                     hosts: ["hosted.test": "10.9.8.7"],
                                                     blockResponse: "nxdomain"),
                                   blocker: blocker)
        let (server, port) = try startServer(resolver: resolver, fakeIP: nil)
        defer { server.stop() }

        let hostsReply = try await ask(port: port, name: "hosted.test", id: 11)
        XCTAssertEqual(hostsReply.resolvedAddresses, ["10.9.8.7"])

        let blockedReply = try await ask(port: port, name: "blocked.test", id: 12)
        XCTAssertEqual(blockedReply.rcode, DNSRCode.nameError.rawValue)
        XCTAssertTrue(blockedReply.answers.isEmpty)
    }

    func testDNSServerAllocatesFakeIPsInFakeIPMode() async throws {
        let resolver = DNSResolver(config: DNSConfig(mode: .fakeIP,
                                                     upstreams: [],
                                                     fallback: [],
                                                     fakeIPRange: "198.18.0.0/15"),
                                   blocker: nil)
        let pool = FakeIPPool(range: "198.18.0.0/15")
        let (server, port) = try startServer(resolver: resolver, fakeIP: pool)
        defer { server.stop() }

        let first = try await ask(port: port, name: "fake.test", id: 21)
        guard let address = first.resolvedAddresses.first else {
            XCTFail("fake-IP mode must answer with an address")
            return
        }
        XCTAssertTrue(pool.contains(ip: address), "\(address) must belong to the fake pool")
        XCTAssertEqual(pool.host(for: address), "fake.test")

        let again = try await ask(port: port, name: "fake.test", id: 22)
        XCTAssertEqual(again.resolvedAddresses.first, address, "fake IP must be stable per host")
    }

    func testDNSServerRejectsInvalidPort() {
        let resolver = DNSResolver(config: DNSConfig(mode: .system, upstreams: [], fallback: []),
                                   blocker: nil)
        let server = DNSServer(port: 0, resolver: resolver, blocker: nil, fakeIP: nil)
        XCTAssertThrowsError(try server.start()) { error in
            guard case LeapinError.invalidConfiguration = error else {
                XCTFail("expected invalidConfiguration, got \(error)")
                return
            }
        }
        XCTAssertFalse(server.isRunning)
    }

    // MARK: - Fake IP pool

    func testFakeIPPoolAllocatesSequentiallyAndReverses() {
        let pool = FakeIPPool(range: "198.18.0.0/15")
        let first = pool.ip(for: "one.test")
        let second = pool.ip(for: "two.test")
        XCTAssertTrue(pool.contains(ip: first))
        XCTAssertTrue(pool.contains(ip: second))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(pool.host(for: first), "one.test")
        XCTAssertEqual(pool.host(for: second), "two.test")
        XCTAssertEqual(pool.ip(for: "ONE.test"), first, "mapping must be stable and case-insensitive")
        XCTAssertEqual(pool.allocatedCount, 2)
        XCTAssertFalse(pool.contains(ip: "8.8.8.8"))
        XCTAssertNil(pool.host(for: "8.8.8.8"))

        pool.reset()
        XCTAssertEqual(pool.allocatedCount, 0)
        XCTAssertNil(pool.host(for: first))
    }

    func testFakeIPPoolFallsBackOnInvalidRange() {
        let pool = FakeIPPool(range: "not-a-cidr")
        let address = pool.ip(for: "fallback.test")
        XCTAssertTrue(pool.contains(ip: address), "\(address) should be inside the default pool")
    }

    // MARK: - Upstream parsing

    func testUpstreamParsing() {
        if case .doh(let url)? = DNSUpstream.parse("https://1.1.1.1/dns-query") {
            XCTAssertEqual(url.host, "1.1.1.1")
            XCTAssertEqual(url.path, "/dns-query")
        } else {
            XCTFail("https upstream should parse as DoH")
        }
        if case .dot(let host, let port)? = DNSUpstream.parse("tls://1.0.0.1") {
            XCTAssertEqual(host, "1.0.0.1")
            XCTAssertEqual(port, 853)
        } else {
            XCTFail("tls:// should parse as DoT")
        }
        if case .dot(let host, let port)? = DNSUpstream.parse("tls://dns.example:8853") {
            XCTAssertEqual(host, "dns.example")
            XCTAssertEqual(port, 8853)
        } else {
            XCTFail("DoT with explicit port should parse")
        }
        if case .udp(let host, let port)? = DNSUpstream.parse("223.5.5.5") {
            XCTAssertEqual(host, "223.5.5.5")
            XCTAssertEqual(port, 53)
        } else {
            XCTFail("bare host should parse as UDP")
        }
        if case .udp(let host, let port)? = DNSUpstream.parse("udp://9.9.9.9:5353") {
            XCTAssertEqual(host, "9.9.9.9")
            XCTAssertEqual(port, 5353)
        } else {
            XCTFail("udp:// should parse as UDP")
        }
        XCTAssertNil(DNSUpstream.parse("quic://1.1.1.1"))
    }

    // MARK: - Helpers

    private func makeUpstream() async throws -> FakeDNSServer {
        try await FakeDNSServer.start { query in
            guard let question = query.questions.first else { return nil }
            if question.type == .a {
                return DNSMessage.reply(to: query,
                                        rcode: .noError,
                                        answers: [DNSResourceRecord(name: question.name,
                                                                    type: .a,
                                                                    ttl: 60,
                                                                    rdata: Data([93, 184, 216, 34]))])
            }
            return DNSMessage.reply(to: query, rcode: .noError, answers: [])
        }
    }

    private func makeResolver(upstream: FakeDNSServer, cacheTTL: Int) -> DNSResolver {
        DNSResolver(config: DNSConfig(mode: .doh,
                                      upstreams: ["udp://127.0.0.1:\(upstream.port)"],
                                      fallback: [],
                                      cacheTTL: cacheTTL),
                    blocker: nil)
    }

    private func startServer(resolver: DNSResolver, fakeIP: FakeIPPool?) throws -> (DNSServer, UInt16) {
        var lastError: Error?
        for _ in 0..<8 {
            let candidate = UInt16.random(in: 20_000...60_000)
            let server = DNSServer(port: candidate, resolver: resolver, blocker: nil, fakeIP: fakeIP)
            do {
                try server.start()
                return (server, candidate)
            } catch {
                lastError = error
                server.stop()
            }
        }
        throw lastError ?? LeapinError.connectionFailed("could not bind a DNS test port")
    }

    private func ask(port: UInt16, name: String, id: UInt16) async throws -> DNSMessage {
        let query = DNSMessage.query(name, type: .a, id: id)
        let raw = try await DNSDatagram.exchange(host: "127.0.0.1",
                                                port: port,
                                                payload: query.encode(),
                                                timeout: 3)
        return try DNSMessage.decode(raw)
    }
}

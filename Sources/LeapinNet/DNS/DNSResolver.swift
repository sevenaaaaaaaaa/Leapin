import Foundation
import Network
import LeapinCore

// MARK: - Upstream description

/// One configured DNS upstream.
public enum DNSUpstream: Sendable, Hashable {
    case doh(URL)
    case dot(host: String, port: UInt16)
    case udp(host: String, port: UInt16)

    /// Parses `https://…`, `tls://host[:port]`, `udp://host[:port]` or a bare `host[:port]`.
    public static func parse(_ raw: String) -> DNSUpstream? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            guard let url = URL(string: text) else { return nil }
            return .doh(url)
        }
        let dotted = text
        if lower.hasPrefix("tls://") {
            let rest = String(dotted.dropFirst("tls://".count))
            guard let parsed = NetAddress.parseAuthority(rest, defaultPort: 853), !parsed.host.isEmpty else { return nil }
            return .dot(host: parsed.host, port: parsed.port == 0 ? 853 : parsed.port)
        }
        if lower.hasPrefix("udp://") {
            let rest = String(dotted.dropFirst("udp://".count))
            guard let parsed = NetAddress.parseAuthority(rest, defaultPort: 53), !parsed.host.isEmpty else { return nil }
            return .udp(host: parsed.host, port: parsed.port == 0 ? 53 : parsed.port)
        }
        if lower.hasPrefix("quic://") || lower.hasPrefix("h3://") {
            return nil
        }
        guard let parsed = NetAddress.parseAuthority(text, defaultPort: 53), !parsed.host.isEmpty else { return nil }
        return .udp(host: parsed.host, port: parsed.port == 0 ? 53 : parsed.port)
    }

    public var description: String {
        switch self {
        case .doh(let url): return "doh:\(url.absoluteString)"
        case .dot(let host, let port): return "dot:\(host):\(port)"
        case .udp(let host, let port): return "udp:\(host):\(port)"
        }
    }
}

// MARK: - Cache state

private struct DNSCacheEntry: Sendable {
    var addresses: [String]
    var negative: Bool
    var expiresAt: Date
}

private actor ResolverState {
    private var cache: [String: DNSCacheEntry] = [:]
    private var inflight: [String: Task<[String], Error>] = [:]

    func cached(_ key: String) -> DNSCacheEntry? {
        guard let entry = cache[key] else { return nil }
        if entry.expiresAt <= Date() {
            cache.removeValue(forKey: key)
            return nil
        }
        return entry
    }

    func store(_ key: String, _ entry: DNSCacheEntry) {
        cache[key] = entry
    }

    /// Atomically returns an in-flight task for `key` or installs a new one.
    func taskOrInsert(_ key: String, make: @Sendable () -> Task<[String], Error>) -> (task: Task<[String], Error>, isNew: Bool) {
        if let existing = inflight[key] { return (existing, false) }
        let task = make()
        inflight[key] = task
        return (task, true)
    }

    func finish(_ key: String) {
        inflight.removeValue(forKey: key)
    }

    func removeAll() {
        cache.removeAll()
    }

    func count() -> Int { cache.count }
}

// MARK: - Resolver

public final class DNSResolver: NameResolving, @unchecked Sendable {
    public let config: DNSConfig
    private let blocker: DomainBlocking?
    private let state = ResolverState()
    private let upstreams: [DNSUpstream]
    private let fallbacks: [DNSUpstream]
    private let hosts: [String: [String]]
    private let session: URLSession
    private let queue = DispatchQueue(label: "com.leapin.dns.resolver", attributes: .concurrent)

    public init(config: DNSConfig, blocker: DomainBlocking? = nil) {
        self.config = config
        self.blocker = blocker

        var parsed: [DNSUpstream] = []
        for raw in config.upstreams {
            if let upstream = DNSUpstream.parse(raw) {
                parsed.append(upstream)
            } else {
                LPLog.shared.warn("dns", "ignoring unsupported upstream: \(raw)")
            }
        }
        var parsedFallback: [DNSUpstream] = []
        for raw in config.fallback {
            if let upstream = DNSUpstream.parse(raw) {
                parsedFallback.append(upstream)
            } else {
                LPLog.shared.warn("dns", "ignoring unsupported fallback upstream: \(raw)")
            }
        }
        self.upstreams = parsed
        self.fallbacks = parsedFallback

        var hostMap: [String: [String]] = [:]
        for (key, value) in config.hosts {
            let addresses = value
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" })
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !addresses.isEmpty {
                hostMap[key.lowercased()] = addresses
            }
        }
        self.hosts = hostMap

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.httpShouldUsePipelining = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    // MARK: NameResolving

    public func resolve(_ host: String) async throws -> [String] {
        let name = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw LeapinError.invalidConfiguration("empty host name")
        }

        if NetAddress.isIPLiteral(name) { return [name] }

        if let literal = hosts[name.lowercased()] { return literal }

        if let verdict = blocker?.verdict(for: name, thirdParty: false), verdict.blocked {
            let reason = verdict.reason ?? "blocked"
            LPLog.shared.debug("dns", "blocked \(name): \(reason)")
            if config.blockResponse.lowercased() == "0.0.0.0" { return ["0.0.0.0"] }
            throw LeapinError.blocked("dns: \(name) (\(reason))")
        }

        let key = name.lowercased()
        if config.cacheTTL > 0, let entry = await state.cached(key) {
            if entry.negative {
                throw LeapinError.connectionFailed("dns: negative cache for \(name)")
            }
            return entry.addresses
        }

        let (task, isNew) = await state.taskOrInsert(key) { [self] in
            Task { try await lookupAll(name) }
        }
        if !isNew { return try await task.value }

        do {
            let addresses = try await task.value
            await state.finish(key)
            return addresses
        } catch {
            await state.finish(key)
            throw error
        }
    }

    public func flushCache() {
        Task { await state.removeAll() }
    }

    /// Number of cached entries (test/introspection aid).
    public func cachedEntryCount() async -> Int {
        await state.count()
    }

    // MARK: Trace (P1 control plane)

    /// Resolves `host` exactly like `resolve` but reports which stage answered and
    /// how long each stage took. Read-only: it never inserts cache entries and never
    /// throws — failures are reported in `error`.
    public func trace(_ host: String) async -> DNSTrace {
        let started = Date()
        var steps: [DNSTraceStep] = []
        func step(_ stage: String, _ detail: String, since: Date) {
            steps.append(DNSTraceStep(stage: stage, detail: detail,
                                      elapsedMs: Date().timeIntervalSince(since) * 1000))
        }
        func elapsed() -> Double { Date().timeIntervalSince(started) * 1000 }

        let name = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return DNSTrace(host: host, source: .failed, elapsedMs: elapsed(),
                            steps: steps, error: "empty host name")
        }

        var stageStart = Date()
        if NetAddress.isIPLiteral(name) {
            step("literal", "ip literal \(name)", since: stageStart)
            return DNSTrace(host: name, source: .literal, resolved: [name],
                            elapsedMs: elapsed(), steps: steps)
        }

        stageStart = Date()
        if let literal = hosts[name.lowercased()] {
            step("hosts", "hosts entry -> \(literal.joined(separator: ", "))", since: stageStart)
            return DNSTrace(host: name, source: .hosts, resolved: literal,
                            elapsedMs: elapsed(), steps: steps)
        }
        step("hosts", "no hosts entry", since: stageStart)

        stageStart = Date()
        if let verdict = blocker?.verdict(for: name, thirdParty: false), verdict.blocked {
            let reason = verdict.reason ?? "blocked"
            step("blocker", "blocked: \(reason)", since: stageStart)
            if config.blockResponse.lowercased() == "0.0.0.0" {
                return DNSTrace(host: name, source: .blocker, resolved: ["0.0.0.0"],
                                elapsedMs: elapsed(), steps: steps, error: "blocked: \(reason)")
            }
            return DNSTrace(host: name, source: .blocker, elapsedMs: elapsed(),
                            steps: steps, error: "blocked: \(reason)")
        }
        step("blocker", "not blocked", since: stageStart)

        let key = name.lowercased()
        stageStart = Date()
        if config.cacheTTL > 0, let entry = await state.cached(key) {
            let remaining = max(0, Int(entry.expiresAt.timeIntervalSinceNow.rounded(.up)))
            if entry.negative {
                step("cache", "negative cache hit", since: stageStart)
                return DNSTrace(host: name, source: .negativeCache,
                                elapsedMs: elapsed(), cacheTTL: remaining,
                                steps: steps, error: "negative cache for \(name)")
            }
            step("cache", "cache hit -> \(entry.addresses.joined(separator: ", "))", since: stageStart)
            return DNSTrace(host: name, source: .cache, resolved: entry.addresses,
                            elapsedMs: elapsed(), cacheTTL: remaining, steps: steps)
        }
        step("cache", "cache miss", since: stageStart)

        let chain = upstreams + fallbacks

        if config.mode == .system || chain.isEmpty {
            stageStart = Date()
            do {
                let addresses = try await systemLookup(name)
                step("system", "getaddrinfo -> \(addresses.joined(separator: ", "))", since: stageStart)
                return DNSTrace(host: name, source: .upstream, resolved: addresses,
                                upstream: "system", elapsedMs: elapsed(), steps: steps)
            } catch {
                step("system", "getaddrinfo failed: \(error.localizedDescription)", since: stageStart)
                return DNSTrace(host: name, source: .failed, elapsedMs: elapsed(),
                                steps: steps, error: error.localizedDescription)
            }
        }

        step("upstream", "trying \(chain.count) upstream(s)", since: Date())
        var lastError = "no upstream responded for \(name)"
        for type in [DNSRecordType.a, DNSRecordType.aaaa] {
            for upstream in chain {
                let attempt = Date()
                do {
                    let query = DNSMessage.query(name, type: type, id: UInt16.random(in: 1...65534))
                    let response = try await exchange(query.encode(), via: upstream)
                    let message = try DNSMessage.decode(response)
                    step("upstream", "\(upstream.description) \(type.name)", since: attempt)
                    let addresses = type == .a ? message.aRecords : message.aaaaRecords
                    if !addresses.isEmpty {
                        return DNSTrace(host: name, source: .upstream, resolved: addresses,
                                        upstream: upstream.description, elapsedMs: elapsed(),
                                        cacheTTL: Int(message.minimumTTL), steps: steps)
                    }
                    if message.isSuccess {
                        lastError = "no \(type.name) record for \(name) from \(upstream.description)"
                    } else {
                        lastError = "upstream \(upstream.description) returned rcode \(message.rcode) for \(name)"
                    }
                    // A decodable response ends the search for this record type,
                    // mirroring firstSuccess() in the resolve path.
                    break
                } catch {
                    step("upstream", "\(upstream.description) \(type.name) failed: \(error.localizedDescription)",
                         since: attempt)
                    lastError = error.localizedDescription
                    continue
                }
            }
        }

        return DNSTrace(host: name, source: .failed, elapsedMs: elapsed(),
                        steps: steps, error: lastError)
    }

    // MARK: Lookup pipeline

    private func lookupAll(_ name: String) async throws -> [String] {
        if config.mode == .system || (upstreams.isEmpty && fallbacks.isEmpty) {
            return try await systemLookup(name)
        }

        var lastError: Error = LeapinError.connectionFailed("dns: no upstream responded for \(name)")
        let chain = upstreams + fallbacks

        for type in [DNSRecordType.a, DNSRecordType.aaaa] {
            if let message = try await firstSuccess(name: name, type: type, chain: chain) {
                let addresses = type == .a ? message.aRecords : message.aaaaRecords
                if !addresses.isEmpty {
                    await cache(key: name.lowercased(), addresses: addresses, ttl: message.minimumTTL, negative: false)
                    return addresses
                }
                if message.isSuccess {
                    lastError = LeapinError.connectionFailed("dns: no \(type.name) record for \(name)")
                } else {
                    lastError = LeapinError.connectionFailed("dns: upstream returned rcode \(message.rcode) for \(name)")
                }
            }
        }
        await cache(key: name.lowercased(), addresses: [], ttl: 30, negative: true)
        throw lastError
    }

    /// Tries each upstream in order until one returns a decodable response.
    private func firstSuccess(name: String, type: DNSRecordType, chain: [DNSUpstream]) async throws -> DNSMessage? {
        for upstream in chain {
            do {
                let query = DNSMessage.query(name, type: type, id: UInt16.random(in: 1...65534))
                let response = try await exchange(query.encode(), via: upstream)
                return try DNSMessage.decode(response)
            } catch {
                LPLog.shared.debug("dns", "\(upstream.description) failed for \(name): \(error.localizedDescription)")
                continue
            }
        }
        return nil
    }

    private func cache(key: String, addresses: [String], ttl: UInt32, negative: Bool) async {
        guard config.cacheTTL > 0 else { return }
        let effective = min(max(Double(ttl), negative ? 30 : 10), Double(config.cacheTTL))
        let entry = DNSCacheEntry(addresses: addresses, negative: negative, expiresAt: Date().addingTimeInterval(effective))
        await state.store(key, entry)
    }

    // MARK: Raw query handling (used by DNSServer)

    /// Answers a decoded query, honouring hosts, the blocker and the cache.
    public func respond(to message: DNSMessage) async -> DNSMessage {
        guard let question = message.questions.first else {
            return DNSMessage.reply(to: message, rcode: .formatError)
        }
        let name = question.name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let queryType = question.type

        if let literal = hosts[name.lowercased()] {
            let records = Self.records(name: name, type: queryType, addresses: literal, ttl: UInt32(max(config.cacheTTL, 60)))
            return DNSMessage.reply(to: message, rcode: .noError, answers: records)
        }

        if let verdict = blocker?.verdict(for: name, thirdParty: false), verdict.blocked {
            if config.blockResponse.lowercased() == "0.0.0.0" && (queryType == .a || queryType == .aaaa) {
                let records = Self.records(name: name, type: queryType, addresses: ["0.0.0.0"], ttl: 60)
                return DNSMessage.reply(to: message, rcode: .noError, answers: records)
            }
            return DNSMessage.reply(to: message, rcode: .nameError)
        }

        if NetAddress.isIPLiteral(name) {
            let records = Self.records(name: name, type: queryType, addresses: [name], ttl: 60)
            return DNSMessage.reply(to: message, rcode: .noError, answers: records)
        }

        let chain = upstreams + fallbacks
        if config.mode == .system || chain.isEmpty {
            do {
                let addresses = try await systemLookup(name)
                let records = Self.records(name: name, type: queryType, addresses: addresses, ttl: 60)
                return DNSMessage.reply(to: message, rcode: .noError, answers: records)
            } catch {
                return DNSMessage.reply(to: message, rcode: .serverFailure)
            }
        }

        for upstream in chain {
            do {
                let response = try await exchange(message.encode(), via: upstream)
                var decoded = try DNSMessage.decode(response)
                decoded.id = message.id
                return decoded
            } catch {
                LPLog.shared.debug("dns", "forward \(upstream.description) failed: \(error.localizedDescription)")
                continue
            }
        }
        return DNSMessage.reply(to: message, rcode: .serverFailure)
    }

    static func records(name: String, type: DNSRecordType, addresses: [String], ttl: UInt32) -> [DNSResourceRecord] {
        var out: [DNSResourceRecord] = []
        for address in addresses {
            if type == .aaaa, let bytes = NetAddress.ipv6Bytes(address) {
                out.append(DNSResourceRecord(name: name, type: .aaaa, ttl: ttl, rdata: bytes))
            } else if let bytes = NetAddress.ipv4Bytes(address) {
                out.append(DNSResourceRecord(name: name, type: .a, ttl: ttl, rdata: bytes))
            } else if let bytes = NetAddress.ipv6Bytes(address) {
                out.append(DNSResourceRecord(name: name, type: .aaaa, ttl: ttl, rdata: bytes))
            }
        }
        return out
    }

    // MARK: Transports

    private func exchange(_ payload: Data, via upstream: DNSUpstream) async throws -> Data {
        switch upstream {
        case .doh(let url):
            return try await dohExchange(url: url, payload: payload)
        case .dot(let host, let port):
            return try await doTExchange(host: host, port: port, payload: payload)
        case .udp(let host, let port):
            return try await udpExchange(host: host, port: port, payload: payload)
        }
    }

    private func dohExchange(url: URL, payload: Data) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 5

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw LeapinError.connectionFailed("doh \(url.host ?? "?"): HTTP \(http.statusCode)")
        }
        guard !data.isEmpty else {
            throw LeapinError.connectionFailed("doh \(url.host ?? "?"): empty body")
        }
        return data
    }

    private func doTExchange(host: String, port: UInt16, payload: Data) async throws -> Data {
        let options = TLSFactory.clientOptions(serverName: host, alpn: ["dot"])
        let params = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 853, using: params)
        let socket = NetSocket(connection: connection, description: "dot:\(host):\(port)")
        do {
            try await socket.start(timeout: 5)
            var framed = Data([UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
            framed.append(payload)
            try await socket.write(framed)
            let buffered = BufferedStream(socket)
            let lengthData = try await buffered.readExactly(2)
            guard lengthData.count == 2 else {
                throw LeapinError.connectionFailed("dot \(host): short length prefix")
            }
            let bytes = Array(lengthData)
            let length = Int(bytes[0]) << 8 | Int(bytes[1])
            guard length > 0 else {
                throw LeapinError.connectionFailed("dot \(host): empty response")
            }
            let body = try await buffered.readExactly(length)
            socket.close()
            return body
        } catch {
            socket.close()
            throw error
        }
    }

    private func udpExchange(host: String, port: UInt16, payload: Data) async throws -> Data {
        try await DNSDatagram.exchange(host: host, port: port, payload: payload, timeout: 4)
    }

    // MARK: System resolver

    private func systemLookup(_ host: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                                     ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                                     ai_addr: nil, ai_next: nil)
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &result)
                guard status == 0, let first = result else {
                    continuation.resume(throwing: LeapinError.connectionFailed(
                        "getaddrinfo(\(host)) failed: \(String(cString: gai_strerror(status)))"))
                    return
                }
                defer { freeaddrinfo(first) }
                var addresses: [String] = []
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let info = cursor {
                    if let sockaddrPointer = info.pointee.ai_addr {
                        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        let length = socklen_t(info.pointee.ai_addrlen)
                        let error = getnameinfo(sockaddrPointer, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
                        if error == 0 {
                            let text = String(cString: buffer)
                            if !text.isEmpty && !addresses.contains(text) { addresses.append(text) }
                        }
                    }
                    cursor = info.pointee.ai_next
                }
                if addresses.isEmpty {
                    continuation.resume(throwing: LeapinError.connectionFailed("getaddrinfo(\(host)) returned no addresses"))
                } else {
                    continuation.resume(returning: addresses)
                }
            }
        }
    }
}

// MARK: - UDP transport

/// One-shot UDP DNS exchange built on Network.framework datagrams.
public enum DNSDatagram {
    public static func exchange(host: String, port: UInt16, payload: Data, timeout: TimeInterval) async throws -> Data {
        let options = NWProtocolUDP.Options()
        let params = NWParameters(dtls: nil, udp: options)
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? 53
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: params)
        let queue = DispatchQueue(label: "com.leapin.dns.udp")

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let guardBox = OnceBox()
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            connection.send(content: payload, completion: .contentProcessed { error in
                                if let error, guardBox.claim() {
                                    continuation.resume(throwing: LeapinError.connectionFailed("udp send: \(error.localizedDescription)"))
                                    connection.cancel()
                                    return
                                }
                                connection.receiveMessage { data, _, _, error in
                                    guard guardBox.claim() else { return }
                                    if let error {
                                        continuation.resume(throwing: LeapinError.connectionFailed("udp receive: \(error.localizedDescription)"))
                                    } else if let data, !data.isEmpty {
                                        continuation.resume(returning: data)
                                    } else {
                                        continuation.resume(throwing: LeapinError.connectionFailed("udp: empty response from \(host)"))
                                    }
                                    connection.cancel()
                                }
                            })
                        case .failed(let error):
                            if guardBox.claim() {
                                continuation.resume(throwing: LeapinError.connectionFailed("udp \(host): \(error.localizedDescription)"))
                            }
                        case .cancelled:
                            if guardBox.claim() {
                                continuation.resume(throwing: LeapinError.connectionFailed("udp \(host): cancelled"))
                            }
                        default:
                            break
                        }
                    }
                    connection.start(queue: queue)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0.2) * 1_000_000_000))
                throw LeapinError.timeout
            }
            do {
                guard let first = try await group.next() else {
                    throw LeapinError.connectionFailed("udp \(host): no response")
                }
                group.cancelAll()
                connection.cancel()
                return first
            } catch {
                group.cancelAll()
                connection.cancel()
                throw error
            }
        }
    }
}

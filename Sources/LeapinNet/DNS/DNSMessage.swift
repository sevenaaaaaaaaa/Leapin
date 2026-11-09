import Foundation
import LeapinCore

// MARK: - Types

public enum DNSRecordType: UInt16, Sendable, CaseIterable {
    case a = 1
    case ns = 2
    case cname = 5
    case soa = 6
    case ptr = 12
    case mx = 15
    case txt = 16
    case aaaa = 28
    case srv = 33
    case opt = 41
    case https = 65

    public var name: String {
        switch self {
        case .a: return "A"
        case .ns: return "NS"
        case .cname: return "CNAME"
        case .soa: return "SOA"
        case .ptr: return "PTR"
        case .mx: return "MX"
        case .txt: return "TXT"
        case .aaaa: return "AAAA"
        case .srv: return "SRV"
        case .opt: return "OPT"
        case .https: return "HTTPS"
        }
    }
}

public enum DNSRCode: UInt8, Sendable {
    case noError = 0
    case formatError = 1
    case serverFailure = 2
    case nameError = 3
    case notImplemented = 4
    case refused = 5
}

public struct DNSQuestion: Sendable, Hashable {
    public var name: String
    public var type: DNSRecordType
    public var qclass: UInt16

    public init(name: String, type: DNSRecordType = .a, qclass: UInt16 = 1) {
        self.name = name
        self.type = type
        self.qclass = qclass
    }
}

public struct DNSResourceRecord: Sendable, Hashable {
    public var name: String
    public var type: DNSRecordType
    public var recordClass: UInt16
    public var ttl: UInt32
    public var rdata: Data

    public init(name: String, type: DNSRecordType, recordClass: UInt16 = 1, ttl: UInt32, rdata: Data) {
        self.name = name
        self.type = type
        self.recordClass = recordClass
        self.ttl = ttl
        self.rdata = rdata
    }

    /// Decoded CNAME target, when this record is a CNAME.
    public var cnameTarget: String? {
        guard type == .cname else { return nil }
        return DNSMessage.decodeName(in: rdata, offset: 0).name
    }

    /// Decoded A record address.
    public var ipv4Address: String? {
        guard type == .a, rdata.count == 4 else { return nil }
        return NetAddress.string(fromIPv4: rdata)
    }

    /// Decoded AAAA record address.
    public var ipv6Address: String? {
        guard type == .aaaa, rdata.count == 16 else { return nil }
        return NetAddress.string(fromIPv6: rdata)
    }
}

public enum DNSCodecError: Error, LocalizedError, Sendable {
    case truncated(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .truncated(let detail): return "DNS message truncated: \(detail)"
        case .malformed(let detail): return "DNS message malformed: \(detail)"
        }
    }
}

// MARK: - Message

public struct DNSMessage: Sendable {
    public var id: UInt16
    public var isResponse: Bool
    public var opcode: UInt8
    public var isAuthoritative: Bool
    public var isTruncated: Bool
    public var recursionDesired: Bool
    public var recursionAvailable: Bool
    public var rcode: UInt8
    public var questions: [DNSQuestion]
    public var answers: [DNSResourceRecord]
    public var authorities: [DNSResourceRecord]
    public var additionals: [DNSResourceRecord]

    public init(id: UInt16 = 0,
                isResponse: Bool = false,
                opcode: UInt8 = 0,
                isAuthoritative: Bool = false,
                isTruncated: Bool = false,
                recursionDesired: Bool = true,
                recursionAvailable: Bool = false,
                rcode: UInt8 = 0,
                questions: [DNSQuestion] = [],
                answers: [DNSResourceRecord] = [],
                authorities: [DNSResourceRecord] = [],
                additionals: [DNSResourceRecord] = []) {
        self.id = id
        self.isResponse = isResponse
        self.opcode = opcode
        self.isAuthoritative = isAuthoritative
        self.isTruncated = isTruncated
        self.recursionDesired = recursionDesired
        self.recursionAvailable = recursionAvailable
        self.rcode = rcode
        self.questions = questions
        self.answers = answers
        self.authorities = authorities
        self.additionals = additionals
    }

    // MARK: Encoding

    public func encode() -> Data {
        var out = Data()
        out.append(UInt8(id >> 8))
        out.append(UInt8(id & 0xFF))

        var flags: UInt16 = 0
        if isResponse { flags |= 0x8000 }
        flags |= (UInt16(opcode & 0x0F) << 11)
        if isAuthoritative { flags |= 0x0400 }
        if isTruncated { flags |= 0x0200 }
        if recursionDesired { flags |= 0x0100 }
        if recursionAvailable { flags |= 0x0080 }
        flags |= UInt16(rcode & 0x0F)
        out.append(UInt8(flags >> 8))
        out.append(UInt8(flags & 0xFF))

        out.append(contentsOf: Self.u16(UInt16(truncatingIfNeeded: questions.count)))
        out.append(contentsOf: Self.u16(UInt16(truncatingIfNeeded: answers.count)))
        out.append(contentsOf: Self.u16(UInt16(truncatingIfNeeded: authorities.count)))
        out.append(contentsOf: Self.u16(UInt16(truncatingIfNeeded: additionals.count)))

        for question in questions {
            out.append(Self.encodeName(question.name))
            out.append(contentsOf: Self.u16(question.type.rawValue))
            out.append(contentsOf: Self.u16(question.qclass))
        }

        for record in answers {
            out.append(Self.encodeRecord(record))
        }
        for record in authorities {
            out.append(Self.encodeRecord(record))
        }
        for record in additionals {
            out.append(Self.encodeRecord(record))
        }
        return out
    }

    private static func encodeRecord(_ record: DNSResourceRecord) -> Data {
        var out = encodeName(record.name)
        out.append(contentsOf: u16(record.type.rawValue))
        out.append(contentsOf: u16(record.recordClass))
        out.append(contentsOf: u32(record.ttl))
        out.append(contentsOf: u16(UInt16(truncatingIfNeeded: record.rdata.count)))
        out.append(record.rdata)
        return out
    }

    /// Encodes a domain name in uncompressed wire format.
    public static func encodeName(_ name: String) -> Data {
        var out = Data()
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        if !trimmed.isEmpty {
            for label in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
                let bytes = Array(label.utf8)
                if bytes.count > 63 { continue }
                out.append(UInt8(bytes.count))
                out.append(contentsOf: bytes)
            }
        }
        out.append(0x00)
        return out
    }

    private static func u16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    private static func u32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    // MARK: Decoding

    public static func decode(_ data: Data) throws -> DNSMessage {
        let bytes = Array(data)
        guard bytes.count >= 12 else {
            throw DNSCodecError.truncated("header needs 12 bytes, got \(bytes.count)")
        }
        var offset = 0
        let id = readU16(bytes, &offset)
        let flags = readU16(bytes, &offset)
        let qdCount = Int(readU16(bytes, &offset))
        let anCount = Int(readU16(bytes, &offset))
        let nsCount = Int(readU16(bytes, &offset))
        let arCount = Int(readU16(bytes, &offset))

        var message = DNSMessage(id: id)
        message.isResponse = (flags & 0x8000) != 0
        message.opcode = UInt8((flags >> 11) & 0x0F)
        message.isAuthoritative = (flags & 0x0400) != 0
        message.isTruncated = (flags & 0x0200) != 0
        message.recursionDesired = (flags & 0x0100) != 0
        message.recursionAvailable = (flags & 0x0080) != 0
        message.rcode = UInt8(flags & 0x0F)

        for _ in 0..<qdCount {
            let (name, next) = try decodeNameChecked(bytes, offset: offset)
            offset = next
            guard offset + 4 <= bytes.count else {
                throw DNSCodecError.truncated("question record")
            }
            let type = DNSRecordType(rawValue: readU16(bytes, &offset))
            let qclass = readU16(bytes, &offset)
            message.questions.append(DNSQuestion(name: name, type: type ?? .a, qclass: qclass))
        }

        func records(_ count: Int) throws -> [DNSResourceRecord] {
            var out: [DNSResourceRecord] = []
            out.reserveCapacity(count)
            for _ in 0..<count {
                let (name, next) = try decodeNameChecked(bytes, offset: offset)
                offset = next
                guard offset + 10 <= bytes.count else {
                    throw DNSCodecError.truncated("resource record header")
                }
                let typeRaw = readU16(bytes, &offset)
                let recordClass = readU16(bytes, &offset)
                let ttl = readU32(bytes, &offset)
                let length = Int(readU16(bytes, &offset))
                guard offset + length <= bytes.count else {
                    throw DNSCodecError.truncated("rdata of \(length) bytes")
                }
                // OPT (EDNS0) pseudo-record: skip its payload semantics.
                let rdata = Data(bytes[offset..<offset + length])
                offset += length
                let type = DNSRecordType(rawValue: typeRaw) ?? .txt
                if typeRaw == 41 {
                    out.append(DNSResourceRecord(name: name.isEmpty ? "." : name, type: .opt, recordClass: recordClass, ttl: ttl, rdata: rdata))
                    continue
                }
                out.append(DNSResourceRecord(name: name, type: type, recordClass: recordClass, ttl: ttl, rdata: rdata))
            }
            return out
        }

        message.answers = try records(anCount)
        message.authorities = try records(nsCount)
        message.additionals = try records(arCount)
        return message
    }

    /// Decodes a (possibly compressed) name at `offset`, returning the name and the offset just past it.
    static func decodeNameChecked(_ bytes: [UInt8], offset: Int) throws -> (String, Int) {
        var labels: [String] = []
        var cursor = offset
        var jumps = 0
        var endOffset = -1
        var visited: Set<Int> = []

        while true {
            guard cursor < bytes.count else {
                throw DNSCodecError.truncated("name at offset \(offset)")
            }
            let length = bytes[cursor]
            if length == 0 {
                cursor += 1
                if endOffset < 0 { endOffset = cursor }
                break
            }
            if length & 0xC0 == 0xC0 {
                guard cursor + 1 < bytes.count else {
                    throw DNSCodecError.truncated("compression pointer at \(cursor)")
                }
                let target = (Int(length & 0x3F) << 8) | Int(bytes[cursor + 1])
                if endOffset < 0 { endOffset = cursor + 2 }
                guard target < bytes.count else {
                    throw DNSCodecError.malformed("compression pointer out of range")
                }
                jumps += 1
                guard jumps <= 32, !visited.contains(target) else {
                    throw DNSCodecError.malformed("compression pointer loop")
                }
                visited.insert(target)
                cursor = target
                continue
            }
            guard length & 0xC0 == 0 else {
                throw DNSCodecError.malformed("unsupported label type 0x\(String(length, radix: 16))")
            }
            let labelLength = Int(length)
            guard cursor + 1 + labelLength <= bytes.count else {
                throw DNSCodecError.truncated("label of \(labelLength) bytes")
            }
            let label = String(decoding: bytes[(cursor + 1)..<(cursor + 1 + labelLength)], as: UTF8.self)
            labels.append(label)
            cursor += 1 + labelLength
        }
        if endOffset < 0 { endOffset = cursor }
        return (labels.isEmpty ? "." : labels.joined(separator: "."), endOffset)
    }

    /// Decodes a name from a standalone buffer (used for rdata).
    static func decodeName(in data: Data, offset: Int) -> (name: String, next: Int) {
        let bytes = Array(data)
        guard let result = try? decodeNameChecked(bytes, offset: offset) else {
            return (".", bytes.count)
        }
        return result
    }

    private static func readU16(_ bytes: [UInt8], _ offset: inout Int) -> UInt16 {
        let hi = UInt16(bytes[offset])
        let lo = UInt16(bytes[offset + 1])
        offset += 2
        return hi << 8 | lo
    }

    private static func readU32(_ bytes: [UInt8], _ offset: inout Int) -> UInt32 {
        let value = UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
        offset += 4
        return value
    }

    // MARK: Convenience

    public var isSuccess: Bool { rcode == 0 }

    public var aRecords: [String] { answers.filter { $0.type == .a }.compactMap(\.ipv4Address) }
    public var aaaaRecords: [String] { answers.filter { $0.type == .aaaa }.compactMap(\.ipv6Address) }
    public var cnameRecords: [String] { answers.compactMap(\.cnameTarget) }

    /// Minimum TTL across answer records (0 when there are none).
    public var minimumTTL: UInt32 {
        answers.map(\.ttl).min() ?? 0
    }

    /// All address records, preferring A over AAAA.
    public var resolvedAddresses: [String] {
        let v4 = aRecords
        if !v4.isEmpty { return v4 }
        return aaaaRecords
    }

    public static func query(_ name: String, type: DNSRecordType = .a, id: UInt16 = 0) -> DNSMessage {
        DNSMessage(id: id, questions: [DNSQuestion(name: name, type: type)])
    }

    /// Builds a reply to `query`, echoing its question and id.
    public static func reply(to query: DNSMessage, rcode: DNSRCode, answers: [DNSResourceRecord] = [], ttl: UInt32 = 60) -> DNSMessage {
        var message = DNSMessage(id: query.id,
                                 isResponse: true,
                                 opcode: query.opcode,
                                 recursionDesired: query.recursionDesired,
                                 recursionAvailable: true,
                                 rcode: rcode.rawValue,
                                 questions: query.questions,
                                 answers: answers)
        if rcode != .noError { message.answers = [] }
        _ = ttl
        return message
    }
}

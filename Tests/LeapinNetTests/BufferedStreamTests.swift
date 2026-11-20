import XCTest
@testable import LeapinCore
@testable import LeapinNet

/// NET-03: the buffer must keep the bytes it has not consumed and hand back exactly
/// the ones it has, in order, across chunk boundaries.
final class BufferedStreamTests: XCTestCase {

    /// Serves scripted chunks and records nothing else.
    private final class ChunkedStream: ByteStream, @unchecked Sendable {
        private let chunks: [Data]
        private var index = 0

        init(_ chunks: [Data]) { self.chunks = chunks }

        func write(_ data: Data) async throws {}
        func close() {}
        var remoteDescription: String { "chunked" }
        var bytesRead: Int { 0 }
        var bytesWritten: Int { 0 }

        func read(maxLength: Int) async throws -> Data? {
            guard index < chunks.count else { return nil }
            let chunk = chunks[index]
            index += 1
            return chunk
        }
    }

    func testPushBackKeepsOrder() async throws {
        let stream = BufferedStream(ChunkedStream([]))
        stream.pushBack(Data("world".utf8))
        stream.pushBack(Data("hello ".utf8))
        XCTAssertEqual(stream.bufferedByteCount, 11)
        let text = try await stream.readExactly(11)
        XCTAssertEqual(String(decoding: text, as: UTF8.self), "hello world")
        XCTAssertEqual(stream.bufferedByteCount, 0)
    }

    func testReadUntilAcrossChunkBoundary() async throws {
        // The terminator is split across the two chunks on purpose.
        let stream = BufferedStream(ChunkedStream([Data("HTTP/1.1 200 OK\r\n\r".utf8),
                                                   Data("\nHost: x\r\n".utf8)]))
        let head = try await stream.readUntil(Data("\r\n\r\n".utf8))
        XCTAssertEqual(head.map { String(decoding: $0, as: UTF8.self) }, "HTTP/1.1 200 OK\r\n\r\n")
        let rest = try await stream.readLine()
        XCTAssertEqual(rest.map { String(decoding: $0, as: UTF8.self) }, "Host: x")
    }

    func testReadExactlySplitsAcrossChunksAndKeepsTheRemainder() async throws {
        let stream = BufferedStream(ChunkedStream([Data("abc".utf8), Data("defgh".utf8)]))
        let first = try await stream.readExactly(5)
        XCTAssertEqual(String(decoding: first, as: UTF8.self), "abcde")
        XCTAssertEqual(stream.bufferedByteCount, 3, "the tail of the last chunk stays buffered")
        let second = try await stream.readExactly(3)
        XCTAssertEqual(String(decoding: second, as: UTF8.self), "fgh")
    }

    /// A body far larger than the compaction threshold must still come back byte
    /// for byte: this is the path that used to copy the whole remainder per read.
    func testLargeBodySurvivesCompaction() async throws {
        let payload = Data((0..<1_048_576).map { UInt8($0 % 251) })
        let chunks = stride(from: 0, to: payload.count, by: 16_384).map {
            payload.subdata(in: $0..<min($0 + 16_384, payload.count))
        }
        let stream = BufferedStream(ChunkedStream(chunks))
        let read = try await stream.readExactly(payload.count)
        XCTAssertEqual(read.count, payload.count)
        XCTAssertTrue(read == payload, "compaction must not reorder or drop bytes")
    }

    func testReadByteAndDrainOnEOF() async throws {
        let stream = BufferedStream(ChunkedStream([Data("hi".utf8)]))
        let first = try await stream.readByte()
        XCTAssertEqual(first, UInt8(ascii: "h"))
        let second = try await stream.readByte()
        XCTAssertEqual(second, UInt8(ascii: "i"))
        let eof = try await stream.readByte()
        XCTAssertNil(eof, "EOF after the scripted chunks")
        XCTAssertEqual(stream.bufferedByteCount, 0)
    }
}
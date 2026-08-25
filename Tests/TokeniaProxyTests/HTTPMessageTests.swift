import Foundation
import Testing
@testable import TokeniaProxy

@Suite("HTTP head parsing")
struct HTTPMessageTests {
    @Test("Parses the request Claude Code actually sends")
    func parsesRealRequest() throws {
        let head = try HTTPHeadParser.parseRequest(head: Data(Fixtures.realRequestHead.utf8))

        #expect(head.method == "POST")
        #expect(head.target == "/v1/messages?beta=true")
        #expect(head.version == "HTTP/1.1")
        // The query string must survive: `?beta=true` selects a different API path.
        #expect(head.path == "/v1/messages")
        #expect(head.headers["content-length"] == "250414")
        #expect(head.headers["X-Stainless-Timeout"] == "600")
        #expect(head.headers["Accept-Encoding"] == "gzip, deflate, br, zstd")
    }

    @Test("Header lookup is case-insensitive but casing is preserved on the wire")
    func preservesCasing() throws {
        let head = try HTTPHeadParser.parseRequest(head: Data(Fixtures.realRequestHead.utf8))
        #expect(head.headers["AUTHORIZATION"] != nil)
        let serialized = String(decoding: head.serialized(), as: UTF8.self)
        #expect(serialized.contains("anthropic-beta: claude-code-20250219,oauth-2025-04-20"))
        #expect(serialized.contains("X-Stainless-Timeout: 600"))
    }

    @Test("Round-trips a request head byte-for-byte in field content")
    func roundTrips() throws {
        let original = Data(Fixtures.realRequestHead.utf8)
        let head = try HTTPHeadParser.parseRequest(head: original)
        let reparsed = try HTTPHeadParser.parseRequest(head: head.serialized())
        #expect(reparsed == head)
    }

    @Test("Parses a response head including the rate-limit headers")
    func parsesResponse() throws {
        let head = try HTTPHeadParser.parseResponse(head: Data(Fixtures.sseResponseHead().utf8))
        #expect(head.statusCode == 200)
        #expect(head.reasonPhrase == "OK")
        #expect(head.headers["content-type"] == "text/event-stream")
        #expect(head.headers["anthropic-ratelimit-unified-5h-utilization"] == "0.15")
    }

    @Test("Finds the end of a head only once the blank line arrives")
    func detectsEndOfHead() {
        let partial = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n".utf8)
        #expect(HTTPHeadParser.endOfHead(in: partial) == nil)

        let complete = partial + Data("\r\n".utf8)
        #expect(HTTPHeadParser.endOfHead(in: complete) == complete.count)

        // Trailing body bytes must not move the boundary.
        let withBody = complete + Data("BODYBYTES".utf8)
        #expect(HTTPHeadParser.endOfHead(in: withBody) == complete.count)
    }

    @Test("Reasons phrases with spaces survive")
    func multiWordReason() throws {
        let head = try HTTPHeadParser.parseResponse(
            head: Data("HTTP/1.1 429 Too Many Requests\r\nRetry-After: 5\r\n\r\n".utf8)
        )
        #expect(head.statusCode == 429)
        #expect(head.reasonPhrase == "Too Many Requests")
    }

    @Test("Rejects a head with no colon in a field line")
    func rejectsMalformed() {
        #expect(throws: ProxyError.self) {
            try HTTPHeadParser.parseRequest(head: Data("GET / HTTP/1.1\r\nnonsense\r\n\r\n".utf8))
        }
    }

    @Test("Reads a head out of a stream that arrives in fragments")
    func readsFragmentedHead() async throws {
        let raw = Fixtures.realRequestHead
        let bytes = Array(raw.utf8)
        // One byte at a time — the worst case a real socket can produce.
        let slices = bytes.map { Data([$0]) }
        let source = ScriptedSource(slices + [Data("BODY".utf8)])
        let reader = HTTPStreamReader(source: source, timeout: .seconds(5))

        let head = try await reader.readHead(maximumSize: 64 * 1024)
        #expect(head.count == bytes.count)
        let parsed = try HTTPHeadParser.parseRequest(head: head)
        #expect(parsed.target == "/v1/messages?beta=true")

        // Bytes read past the head belong to the body and must still be there.
        let body = try await reader.nextBodyBytes(limit: 1024)
        #expect(body == Data("BODY".utf8))
    }

    @Test("Refuses an unbounded head instead of buffering forever")
    func rejectsOversizedHead() async {
        let flood = Data(repeating: UInt8(ascii: "x"), count: 200_000)
        let reader = HTTPStreamReader(source: ScriptedSource([flood]), timeout: .seconds(5))
        await #expect(throws: ProxyError.headTooLarge) {
            try await reader.readHead(maximumSize: 64 * 1024)
        }
    }

    @Test("A cleanly closed idle connection reports peerClosed, not an error")
    func peerClosed() async {
        let reader = HTTPStreamReader(source: ScriptedSource([]), timeout: .seconds(5))
        await #expect(throws: ProxyError.peerClosed) {
            try await reader.readHead(maximumSize: 64 * 1024)
        }
    }
}

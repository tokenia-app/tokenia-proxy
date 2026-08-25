import Foundation
import Testing
@testable import TokeniaProxy

@Suite("Body framing")
struct BodyFramingTests {
    @Test("Content-Length request")
    func contentLengthRequest() throws {
        let head = try HTTPHeadParser.parseRequest(head: Data(Fixtures.realRequestHead.utf8))
        #expect(BodyFraming.forRequest(head) == .contentLength(250_414))
    }

    @Test("Health check request has no body")
    func healthCheckHasNoBody() throws {
        let head = try HTTPHeadParser.parseRequest(head: Data(Fixtures.healthCheckHead.utf8))
        #expect(BodyFraming.forRequest(head) == .none)
    }

    @Test("Chunked wins over Content-Length")
    func chunkedWins() throws {
        let head = try HTTPHeadParser.parseRequest(
            head: Data("POST /v1/messages HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n".utf8)
        )
        #expect(BodyFraming.forRequest(head) == .chunked)
    }

    @Test("A request without framing headers never reads until close")
    func requestWithoutFraming() throws {
        let head = try HTTPHeadParser.parseRequest(head: Data("GET /v1/models HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        #expect(BodyFraming.forRequest(head) == .none)
    }

    @Test("SSE response is chunked")
    func sseResponse() throws {
        let head = try HTTPHeadParser.parseResponse(head: Data(Fixtures.sseResponseHead().utf8))
        #expect(BodyFraming.forResponse(head, requestMethod: "POST") == .chunked)
    }

    @Test("HEAD responses and 204/304 carry no body even with Content-Length")
    func bodylessResponses() throws {
        let withLength = try HTTPHeadParser.parseResponse(
            head: Data("HTTP/1.1 200 OK\r\nContent-Length: 4242\r\n\r\n".utf8)
        )
        #expect(BodyFraming.forResponse(withLength, requestMethod: "HEAD") == .none)
        #expect(BodyFraming.forResponse(withLength, requestMethod: "GET") == .contentLength(4242))

        let noContent = try HTTPHeadParser.parseResponse(head: Data("HTTP/1.1 204 No Content\r\n\r\n".utf8))
        #expect(BodyFraming.forResponse(noContent, requestMethod: "POST") == .none)

        let notModified = try HTTPHeadParser.parseResponse(head: Data("HTTP/1.1 304 Not Modified\r\n\r\n".utf8))
        #expect(BodyFraming.forResponse(notModified, requestMethod: "GET") == .none)
    }

    @Test("A response with no framing headers runs until close")
    func untilClose() throws {
        let head = try HTTPHeadParser.parseResponse(head: Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".utf8))
        #expect(BodyFraming.forResponse(head, requestMethod: "GET") == .untilClose)
    }
}

@Suite("Chunked scanner")
struct ChunkedBodyScannerTests {
    private func sseStream() -> Data {
        var data = Data()
        data.append(Fixtures.chunk("event: message_start\ndata: {\"type\":\"message_start\"}\n\n"))
        data.append(Fixtures.chunk("event: content_block_delta\ndata: {\"delta\":{\"text\":\"hi\"}}\n\n"))
        data.append(Fixtures.chunk("event: message_stop\ndata: {}\n\n"))
        data.append(Fixtures.terminalChunk)
        return data
    }

    @Test("Finds the end of a chunked message")
    func findsEnd() throws {
        var scanner = ChunkedBodyScanner()
        let stream = sseStream()
        let consumed = try scanner.consume(stream)
        #expect(consumed == stream.count)
        #expect(scanner.isComplete)
    }

    @Test("Reports surplus bytes belonging to the next pipelined message")
    func reportsSurplus() throws {
        var scanner = ChunkedBodyScanner()
        let stream = sseStream()
        let surplus = Data("HTTP/1.1 200 OK\r\n".utf8)
        let consumed = try scanner.consume(stream + surplus)
        #expect(consumed == stream.count)
        #expect(scanner.isComplete)
    }

    @Test("Survives being fed one byte at a time")
    func byteAtATime() throws {
        var scanner = ChunkedBodyScanner()
        var total = 0
        for byte in sseStream() {
            total += try scanner.consume([byte])
        }
        #expect(scanner.isComplete)
        #expect(total == sseStream().count)
    }

    @Test("Handles chunk extensions and trailers")
    func extensionsAndTrailers() throws {
        var scanner = ChunkedBodyScanner()
        let stream = Data("5;name=value\r\nhello\r\n0\r\nX-Trailer: v\r\n\r\n".utf8)
        #expect(try scanner.consume(stream) == stream.count)
        #expect(scanner.isComplete)
    }

    @Test("Rejects a non-hex chunk size")
    func rejectsGarbage() {
        var scanner = ChunkedBodyScanner()
        #expect(throws: ProxyError.invalidFraming) {
            _ = try scanner.consume(Data("zz\r\n".utf8))
        }
    }

    @Test("Does not mistake payload bytes for framing")
    func payloadLooksLikeFraming() throws {
        // A chunk whose payload is itself a chunk header.
        var scanner = ChunkedBodyScanner()
        let payload = "0\r\n\r\n"
        let stream = Fixtures.chunk(payload) + Fixtures.terminalChunk
        #expect(try scanner.consume(stream) == stream.count)
        #expect(scanner.isComplete)
    }
}

import Foundation
import Testing
@testable import TokeniaProxy

/// The riskiest part of the proxy: if any of these buffer, Claude Code stalls.
@Suite("Streaming relay")
struct StreamingRelayTests {
    @Test("A 250 KB request body is relayed byte-for-byte")
    func largeRequestBody() async throws {
        // ARCHITECTURE §2.3: Content-Length: 250414 is a real observed value.
        let body = Data((0..<250_414).map { UInt8($0 % 251) })
        var slices: [Data] = []
        var offset = 0
        while offset < body.count {
            let size = min(8192, body.count - offset)
            slices.append(body.subdata(in: offset..<(offset + size)))
            offset += size
        }

        let reader = HTTPStreamReader(source: ScriptedSource(slices), timeout: .seconds(5))
        let sink = RecordingSink()
        try await BodyRelay.relay(framing: .contentLength(body.count), from: reader, to: sink, chunkSize: 32 * 1024)

        #expect(sink.combined == body)
    }

    @Test("Each slice is written out before the next one is read — nothing is buffered")
    func relayIsUnbuffered() async throws {
        let journal = RelayJournal()
        let slices = (0..<8).map { Data(repeating: UInt8($0), count: 1024) }
        let total = slices.reduce(0) { $0 + $1.count }

        let reader = HTTPStreamReader(source: ScriptedSource(slices, journal: journal), timeout: .seconds(5))
        let sink = RecordingSink(journal: journal)
        try await BodyRelay.relay(framing: .contentLength(total), from: reader, to: sink, chunkSize: 32 * 1024)

        // Strict alternation proves no accumulation: read, write, read, write…
        let expected: [RelayEvent] = slices.flatMap { [RelayEvent.read(bytes: $0.count), .write(bytes: $0.count)] }
        #expect(journal.events == expected)
    }

    @Test("SSE events are forwarded as they arrive, one write per event")
    func sseIsForwardedEventByEvent() async throws {
        let journal = RelayJournal()
        let events = [
            "event: message_start\ndata: {\"type\":\"message_start\"}\n\n",
            "event: content_block_delta\ndata: {\"delta\":{\"text\":\"Hello\"}}\n\n",
            "event: content_block_delta\ndata: {\"delta\":{\"text\":\" world\"}}\n\n",
            "event: message_stop\ndata: {}\n\n",
        ]
        var slices = events.map { Fixtures.chunk($0) }
        slices.append(Fixtures.terminalChunk)

        let reader = HTTPStreamReader(source: ScriptedSource(slices, journal: journal), timeout: .seconds(5))
        let sink = RecordingSink(journal: journal)
        try await BodyRelay.relay(framing: .chunked, from: reader, to: sink, chunkSize: 32 * 1024)

        // Byte-identical, framing included: we never re-chunk or re-encode.
        #expect(sink.combined == slices.reduce(into: Data()) { $0.append($1) })
        // One write per arriving event, interleaved with the reads.
        let expected: [RelayEvent] = slices.flatMap { [RelayEvent.read(bytes: $0.count), .write(bytes: $0.count)] }
        #expect(journal.events == expected)
    }

    @Test("The relay stops at the terminal chunk and hands surplus back")
    func stopsAtTerminalChunkAndPushesBack() async throws {
        var stream = Fixtures.chunk("data: one\n\n")
        stream.append(Fixtures.terminalChunk)
        let nextMessage = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)

        // Everything arrives in a single TCP segment, message boundary included.
        let reader = HTTPStreamReader(source: ScriptedSource([stream + nextMessage]), timeout: .seconds(5))
        let sink = RecordingSink()
        try await BodyRelay.relay(framing: .chunked, from: reader, to: sink, chunkSize: 32 * 1024)

        #expect(sink.combined == stream)
        let leftover = try await reader.nextBodyBytes(limit: 1024)
        #expect(leftover == nextMessage)
    }

    @Test("Compressed bytes pass through without being decoded")
    func compressedPassthrough() async throws {
        // Deliberately not valid gzip — the point is that we never look.
        let opaque = Data([0x1f, 0x8b, 0x08, 0x00, 0xde, 0xad, 0xbe, 0xef, 0x00, 0xff])
        let reader = HTTPStreamReader(source: ScriptedSource([opaque]), timeout: .seconds(5))
        let sink = RecordingSink()
        try await BodyRelay.relay(framing: .contentLength(opaque.count), from: reader, to: sink, chunkSize: 4)
        #expect(sink.combined == opaque)
    }

    @Test("An upstream that dies mid-body is reported, not silently truncated")
    func truncatedBody() async {
        let reader = HTTPStreamReader(source: ScriptedSource([Data(repeating: 7, count: 10)]), timeout: .seconds(5))
        let sink = RecordingSink()
        await #expect(throws: ProxyError.peerClosed) {
            try await BodyRelay.relay(framing: .contentLength(100), from: reader, to: sink, chunkSize: 32)
        }
    }

    @Test("A read that never completes times out instead of hanging forever")
    func readTimeout() async {
        let reader = HTTPStreamReader(source: ScriptedSource([], hangAtEnd: true), timeout: .milliseconds(50))
        await #expect(throws: ProxyError.timedOut) {
            try await reader.readHead(maximumSize: 1024)
        }
    }

    @Test("The default upstream timeout outlives the client's own 600s budget")
    func timeoutBudget() {
        // ARCHITECTURE §2.3: the client sends X-Stainless-Timeout: 600.
        #expect(ProxyConfiguration().upstreamTimeout >= .seconds(600))
    }
}

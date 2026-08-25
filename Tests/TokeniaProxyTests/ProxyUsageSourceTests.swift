import Foundation
import Testing
import TokeniaCore
@testable import TokeniaProxy

@Suite("Usage publication")
struct ProxyUsageSourceTests {
    @Test("Response headers from a real session become a snapshot")
    func publishesFromCannedHeaders() async throws {
        let source = ProxyUsageSource()
        let response = try HTTPHeadParser.parseResponse(head: Data(Fixtures.sseResponseHead().utf8))

        let snapshot = try #require(source.ingest(responseHeaders: response.headers))

        // Values straight out of ARCHITECTURE §2.4.
        #expect(snapshot.fiveHour?.utilization == 0.15)
        #expect(snapshot.fiveHour?.status == "allowed")
        #expect(snapshot.fiveHour?.resetAt == Date(timeIntervalSince1970: 1_785_022_800))
        #expect(snapshot.sevenDay?.utilization == 0.14)
        #expect(snapshot.sevenDay?.resetAt == Date(timeIntervalSince1970: 1_785_027_600))
        #expect(snapshot.representativeClaim == "five_hour")
        #expect(snapshot.representative?.utilization == 0.15)
        #expect(source.latest == snapshot)
    }

    @Test("Every ingest counts, with or without limit headers")
    func countsResponsesRegardlessOfHeaders() throws {
        let source = ProxyUsageSource()
        #expect(source.requestsSeen == 0)
        #expect(source.lastRequestAt == nil)

        // A response with no rate-limit headers publishes nothing…
        let when = Date(timeIntervalSince1970: 1_785_000_000)
        #expect(source.ingest(responseHeaders: ["content-type": "text/event-stream"], capturedAt: when) == nil)
        // …but still counts. This pair is what lets the app separate "no
        // traffic" from "traffic without limits" on /__tokenia/status.
        #expect(source.requestsSeen == 1)
        #expect(source.lastRequestAt == when)
        #expect(source.latest == nil)

        let response = try HTTPHeadParser.parseResponse(head: Data(Fixtures.sseResponseHead().utf8))
        _ = source.ingest(responseHeaders: response.headers)
        #expect(source.requestsSeen == 2)
    }

    @Test("The events stream carries this source's real counters, not the default zeros")
    func eventsCarryRealCounters() async throws {
        // The protocol's default maps snapshots with requestsSeen: 0. An
        // in-process consumer of the real source must see real traffic.
        let source = ProxyUsageSource()
        _ = source.ingest(responseHeaders: ["content-type": "text/event-stream"])

        var iterator = source.events.makeAsyncIterator()
        let first = await iterator.next()
        guard case .status(let snapshot, let requestsSeen, let lastRequestAt) = first else {
            Issue.record("expected an initial .status replay, got \(String(describing: first))")
            return
        }
        #expect(snapshot == nil, "no limit headers were ingested")
        #expect(requestsSeen == 1)
        #expect(lastRequestAt != nil)
    }

    @Test("Subscribers receive snapshots as an AsyncStream")
    func streamsToSubscribers() async throws {
        let source = ProxyUsageSource()
        let response = try HTTPHeadParser.parseResponse(head: Data(Fixtures.sseResponseHead().utf8))

        let received = Task { () -> UsageSnapshot? in
            for await snapshot in source.snapshots { return snapshot }
            return nil
        }

        // Give the subscriber a moment to register before publishing.
        try await Task.sleep(for: .milliseconds(50))
        source.ingest(responseHeaders: response.headers)

        let snapshot = try #require(await received.value)
        #expect(snapshot.fiveHour?.utilization == 0.15)
    }

    @Test("A subscriber that arrives late is replayed the current snapshot")
    func replaysLatest() async throws {
        let source = ProxyUsageSource()
        let response = try HTTPHeadParser.parseResponse(head: Data(Fixtures.sseResponseHead().utf8))
        source.ingest(responseHeaders: response.headers)

        var iterator = source.snapshots.makeAsyncIterator()
        let replayed = await iterator.next()
        #expect(replayed?.fiveHour?.utilization == 0.15)
    }

    @Test("Responses without limit headers publish nothing and do not clear the snapshot")
    func ignoresIrrelevantResponses() throws {
        let source = ProxyUsageSource()
        let response = try HTTPHeadParser.parseResponse(head: Data(Fixtures.sseResponseHead().utf8))
        source.ingest(responseHeaders: response.headers)

        let plain = try HTTPHeadParser.parseResponse(
            head: Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)
        )
        #expect(source.ingest(responseHeaders: plain.headers) == nil)
        // The last good reading survives — staleness is shown, not invented.
        #expect(source.latest?.fiveHour?.utilization == 0.15)
    }

    @Test("Header casing from the wire does not matter")
    func caseInsensitiveHeaders() {
        let source = ProxyUsageSource()
        let headers = HTTPHeaders([
            ("Anthropic-RateLimit-Unified-5h-Utilization", "0.42"),
            ("ANTHROPIC-RATELIMIT-UNIFIED-5H-RESET", "1785022800"),
            ("Anthropic-Ratelimit-Unified-5h-Status", "allowed"),
        ])
        let snapshot = source.ingest(responseHeaders: headers)
        #expect(snapshot?.fiveHour?.utilization == 0.42)
    }

    @Test("finish() ends every subscriber stream")
    func finishEndsStreams() async throws {
        let source = ProxyUsageSource()
        let done = Task { () -> Int in
            var count = 0
            for await _ in source.snapshots { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(50))
        source.finish()
        #expect(await done.value == 0)
    }
}

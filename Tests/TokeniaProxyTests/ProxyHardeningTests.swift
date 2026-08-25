import Foundation
import Network
import Testing
import TokeniaTestSupport

@testable import TokeniaProxy

/// A source that delays before its first byte, then delivers — the shape of a
/// legitimately idle keep-alive connection waking up.
private final class DelayedSource: ByteSource, @unchecked Sendable {
    private let lock = NSLock()
    private var slices: [Data]
    private let delay: Duration
    private var delayed = false

    init(delay: Duration, then slices: [Data]) {
        self.delay = delay
        self.slices = slices
    }

    private func take() -> (first: Bool, next: Data?) {
        lock.lock()
        defer { lock.unlock() }
        let first = !delayed
        delayed = true
        return (first, slices.isEmpty ? nil : slices.removeFirst())
    }

    func readMore() async throws -> Data? {
        let (first, next) = take()
        if first { try await Task.sleep(for: delay) }
        return next
    }
}

/// One byte per `gap`, forever (up to its supply) — the drip-feed slowloris.
private final class DrippingSource: ByteSource, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Data
    private let gap: Duration

    init(bytes: Data, gap: Duration) {
        self.remaining = bytes
        self.gap = gap
    }

    private func takeByte() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let first = remaining.first else { return nil }
        remaining.removeFirst()
        return Data([first])
    }

    func readMore() async throws -> Data? {
        try await Task.sleep(for: gap)
        guard let byte = takeByte() else {
            try await Task.sleep(for: .seconds(3600))
            return nil
        }
        return byte
    }
}

@Suite("Head reading under hostility")
struct HeadReadingHardeningTests {
    @Test("a head delivered one byte at a time still parses")
    func fragmentedHeadParses() async throws {
        let text = "GET /v1/messages HTTP/1.1\r\nHost: api.anthropic.com\r\nAccept: */*\r\n\r\n"
        let slices = Data(text.utf8).map { Data([$0]) }
        let reader = HTTPStreamReader(source: ScriptedSource(slices), timeout: .seconds(5))
        let head = try await reader.readHead(maximumSize: 64 * 1024)
        #expect(head == Data(text.utf8))
    }

    @Test("a head over the cap is refused")
    func oversizedHeadRefused() async throws {
        // Delivered in chunks so the incremental scan is the code under test.
        let big = "GET / HTTP/1.1\r\n" + String(repeating: "X-Filler: aaaaaaaa\r\n", count: 5000)
        let slices = stride(from: 0, to: big.count, by: 8 * 1024).map { start in
            Data(big.dropFirst(start).prefix(8 * 1024).utf8)
        }
        let reader = HTTPStreamReader(source: ScriptedSource(slices), timeout: .seconds(5))
        await #expect(throws: ProxyError.headTooLarge) {
            _ = try await reader.readHead(maximumSize: 64 * 1024)
        }
    }

    @Test("a small head followed by a fat body in the same read is not a fat head")
    func headPlusBodyIsNotOversized() async throws {
        // The cap check runs after the scan, on purpose: one read can carry a
        // complete head plus megabytes of body, and only the head is the
        // head's problem.
        let head = "POST /v1/messages HTTP/1.1\r\nContent-Length: 200000\r\n\r\n"
        let payload = Data(head.utf8) + Data(repeating: 0x61, count: 200_000)
        let reader = HTTPStreamReader(source: ScriptedSource([payload]), timeout: .seconds(5))
        let parsed = try await reader.readHead(maximumSize: 64 * 1024)
        #expect(parsed == Data(head.utf8))
        // And the body is still there behind it.
        let body = try await reader.nextBodyBytes(limit: 300_000)
        #expect(body?.count == 200_000)
    }

    @Test("a started head that dribbles dies at the completion timeout, not at 660s")
    func slowlorisDiesAtHeadTimeout() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        // Half a head, then silence forever. The long base timeout stands in
        // for the production 660s; the completion timeout is what must fire.
        let reader = HTTPStreamReader(
            source: ScriptedSource([Data("GET / HT".utf8)], hangAtEnd: true),
            timeout: .seconds(600)
        )
        await #expect(throws: ProxyError.timedOut) {
            _ = try await reader.readHead(maximumSize: 64 * 1024, completionTimeout: .milliseconds(200))
        }
        #expect(clock.now - start < .seconds(5), "must not have waited out the base timeout")
    }

    @Test("a drip-fed head with innocent gaps still dies at the cumulative budget")
    func dripFeedBurnsOneBudget() async throws {
        // Each gap is well under the completion timeout — the classic
        // slowloris shape. Per-read windows would let this crawl for weeks
        // (64 KiB × one byte per gap); one cumulative budget must not.
        let clock = ContinuousClock()
        let start = clock.now
        let drip = DrippingSource(bytes: Data("GET / HTTP/1.1\r\nHost: x".utf8), gap: .milliseconds(120))
        let reader = HTTPStreamReader(source: drip, timeout: .seconds(600))
        await #expect(throws: ProxyError.timedOut) {
            _ = try await reader.readHead(maximumSize: 64 * 1024, completionTimeout: .milliseconds(400))
        }
        #expect(clock.now - start < .seconds(5))
    }

    @Test("an idle keep-alive connection may take its time before the first byte")
    func idleKeepAliveSurvivesTheShortTimeout() async throws {
        // Idle for 4x the completion timeout, then a full head: legal, because
        // the short budget only starts once the head has begun.
        let text = "GET /api/hello HTTP/1.1\r\n\r\n"
        let reader = HTTPStreamReader(
            source: DelayedSource(delay: .milliseconds(800), then: [Data(text.utf8)]),
            timeout: .seconds(5)
        )
        let head = try await reader.readHead(maximumSize: 64 * 1024, completionTimeout: .milliseconds(200))
        #expect(head == Data(text.utf8))
    }
}

@Suite(.serialized)
struct ProxyServerHardeningTests {
    private func connect(to port: UInt16) async throws -> NetworkStream {
        let endpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: try #require(NWEndpoint.Port(rawValue: port))
        )
        let stream = NetworkStream(
            connection: NWConnection(to: endpoint, using: .tcp),
            queue: DispatchQueue(label: "tokenia.tests.client")
        )
        try await stream.start()
        return stream
    }

    private func healthCheck(_ client: NetworkStream, port: UInt16) async throws -> Int {
        try await client.send(Data("HEAD /api/hello HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8))
        let reader = HTTPStreamReader(source: client, timeout: .seconds(5))
        return try HTTPHeadParser.parseResponse(head: try await reader.readHead(maximumSize: 64 * 1024)).statusCode
    }

    @Test("connections past the cap are refused, and a freed slot is reusable")
    func connectionCapHolds() async throws {
        let server = ProxyServer(configuration: ProxyConfiguration(
            port: 0, upstreamTimeout: .seconds(5), maximumConcurrentConnections: 2
        ))
        let port = try await server.start()

        let first = try await connect(to: port)
        let second = try await connect(to: port)
        #expect(try await healthCheck(first, port: port) == 200)
        #expect(try await healthCheck(second, port: port) == 200)

        // Third connects at TCP level (the listener accepted before we could
        // refuse) but is cancelled before a byte is served: reading from it
        // ends, not answers.
        let third = try await connect(to: port)
        try? await third.send(Data("HEAD /api/hello HTTP/1.1\r\n\r\n".utf8))
        let reader = HTTPStreamReader(source: third, timeout: .seconds(5))
        await #expect(throws: (any Error).self) {
            _ = try await reader.readHead(maximumSize: 64 * 1024)
        }
        third.cancel()

        // Freeing a slot lets a new client in.
        first.cancel()
        try await Task.sleep(for: .milliseconds(300))
        let fourth = try await connect(to: port)
        #expect(try await healthCheck(fourth, port: port) == 200)

        second.cancel()
        fourth.cancel()
        await server.stop()
    }

    @Test("stop() ends subscriber snapshot streams")
    func stopFinishesUsageStream() async throws {
        let server = ProxyServer(configuration: ProxyConfiguration(port: 0))
        _ = try await server.start()
        let source = await server.usageSource

        let consumed = Task {
            for await _ in source.snapshots {}
            return true
        }
        try await Task.sleep(for: .milliseconds(100))
        await server.stop()
        // Without `usageSource.finish()` in stop(), this iteration never ends.
        #expect(await consumed.value)
    }

    @Test("a fixed port can be rebound immediately after stop, five times over")
    func fixedPortRebinds() async throws {
        // The upgrade path in one test: install.sh stops the old proxy and
        // reuses its port. `allowLocalEndpointReuse` is what makes the rebind
        // legal while TIME_WAIT sockets linger; this pins it.
        let scout = ProxyServer(configuration: ProxyConfiguration(port: 0))
        let probe = try await scout.start()
        await scout.stop()
        // A real request creates a connection, so TIME_WAIT is actually in play.
        for _ in 0..<5 {
            let server = ProxyServer(configuration: ProxyConfiguration(
                port: probe, upstreamTimeout: .seconds(5)
            ))
            let port = try await server.start()
            #expect(port == probe)
            let client = try await connect(to: port)
            #expect(try await healthCheck(client, port: port) == 200)
            client.cancel()
            await server.stop()
        }
    }
}

@Suite(.serialized)
struct ProxyForwardingTests {
    private func connect(to port: UInt16) async throws -> NetworkStream {
        let endpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: try #require(NWEndpoint.Port(rawValue: port))
        )
        let stream = NetworkStream(
            connection: NWConnection(to: endpoint, using: .tcp),
            queue: DispatchQueue(label: "tokenia.tests.client")
        )
        try await stream.start()
        return stream
    }

    private func configuration(port fakePort: UInt16) -> TokeniaProxy.ProxyConfiguration {
        ProxyConfiguration(
            port: 0,
            upstreamHost: "127.0.0.1",
            upstreamPort: fakePort,
            upstreamTimeout: .seconds(10),
            upstreamUsesTLS: false
        )
    }

    @Test("a forwarded request reaches the fake upstream and its limits are ingested")
    func forwardingIngestsRateLimits() async throws {
        let upstream = FakeUpstream(behavior: .fixedResponse(
            status: 200,
            headers: FakeUpstream.rateLimitHeaders + [("Content-Type", "application/json")],
            body: Data("{}".utf8)
        ))
        let fakePort = try await upstream.start()
        defer { upstream.stop() }

        let server = ProxyServer(configuration: configuration(port: fakePort))
        let port = try await server.start()

        let client = try await connect(to: port)
        try await client.send(Data("POST /v1/messages HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}".utf8))
        let reader = HTTPStreamReader(source: client, timeout: .seconds(10))
        let response = try HTTPHeadParser.parseResponse(head: try await reader.readHead(maximumSize: 64 * 1024))
        #expect(response.statusCode == 200)

        // End-to-end: the response's unified headers became the snapshot.
        #expect(await server.usageSource.latest?.fiveHour?.utilization == 0.42)
        #expect(await server.usageSource.requestsSeen == 1)

        client.cancel()
        await server.stop()
    }

    @Test("stop() under live SSE traffic closes every client and stays restartable")
    func stopUnderLoadClosesEverything() async throws {
        let upstream = FakeUpstream(behavior: .sse(events: 10_000, eventBytes: 64, interval: .milliseconds(5)))
        let fakePort = try await upstream.start()
        defer { upstream.stop() }

        let server = ProxyServer(configuration: configuration(port: fakePort))
        let port = try await server.start()

        // 8 clients mid-stream.
        var clients: [NetworkStream] = []
        for _ in 0..<8 {
            let client = try await connect(to: port)
            try await client.send(Data("GET /v1/messages HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
            clients.append(client)
        }
        // Let the streams actually start flowing.
        try await Task.sleep(for: .milliseconds(400))

        await server.stop()

        // Every client socket must reach EOF (or error) within a bounded wait —
        // a stream that keeps flowing after stop() is the bug.
        for client in clients {
            let result: Data? = try? await withProxyTimeout(.seconds(5)) {
                while let chunk = try await client.readMore() {
                    if chunk.isEmpty { continue }
                    _ = chunk // drain until close
                }
                return nil
            }
            #expect(result == nil)
            client.cancel()
        }

        // And the same port is immediately rebindable.
        let again = ProxyServer(configuration: ProxyConfiguration(
            port: port, upstreamTimeout: .seconds(5)
        ))
        #expect(try await again.start() == port)
        await again.stop()
    }
}

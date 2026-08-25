import Foundation
@testable import TokeniaProxy

/// What the relay did, in order. Used to prove nothing is buffered.
enum RelayEvent: Equatable, Sendable {
    case read(bytes: Int)
    case write(bytes: Int)
    case readEOF
}

final class RelayJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RelayEvent] = []

    func append(_ event: RelayEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [RelayEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Replays a fixed script of slices, one per `readMore()`.
final class ScriptedSource: ByteSource, @unchecked Sendable {
    private let lock = NSLock()
    private var slices: [Data]
    private let journal: RelayJournal?
    /// Set to stall forever instead of reporting EOF — used to exercise timeouts.
    private let hangAtEnd: Bool

    init(_ slices: [Data], journal: RelayJournal? = nil, hangAtEnd: Bool = false) {
        self.slices = slices
        self.journal = journal
        self.hangAtEnd = hangAtEnd
    }

    convenience init(_ text: String, journal: RelayJournal? = nil) {
        self.init([Data(text.utf8)], journal: journal)
    }

    private func takeNext() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return slices.isEmpty ? nil : slices.removeFirst()
    }

    func readMore() async throws -> Data? {
        guard let next = takeNext() else {
            if hangAtEnd {
                try await Task.sleep(for: .seconds(3600))
                return nil
            }
            journal?.append(.readEOF)
            return nil
        }
        journal?.append(.read(bytes: next.count))
        return next
    }
}

/// Records every write verbatim so byte-for-byte passthrough can be asserted.
final class RecordingSink: ByteSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []
    private let journal: RelayJournal?

    init(journal: RelayJournal? = nil) {
        self.journal = journal
    }

    private func record(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func write(_ data: Data) async throws {
        record(data)
        journal?.append(.write(bytes: data.count))
    }

    var writes: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var combined: Data {
        writes.reduce(into: Data()) { $0.append($1) }
    }
}

// MARK: - Fixtures

enum Fixtures {
    /// The request Claude Code actually sends — ARCHITECTURE.md §2.3.
    static let realRequestHead = """
        POST /v1/messages?beta=true HTTP/1.1\r
        Host: 127.0.0.1:8787\r
        Connection: keep-alive\r
        Authorization: Bearer sk-ant-oat01-EXAMPLE-NOT-A-REAL-TOKEN\r
        anthropic-beta: claude-code-20250219,oauth-2025-04-20\r
        anthropic-version: 2023-06-01\r
        X-Stainless-Timeout: 600\r
        Accept-Encoding: gzip, deflate, br, zstd\r
        Content-Type: application/json\r
        User-Agent: Bun/1.4.0\r
        Content-Length: 250414\r
        \r

        """

    /// The health check Claude Code sends first — ARCHITECTURE.md §2.2.
    static let healthCheckHead = """
        HEAD /api/hello HTTP/1.1\r
        Connection: keep-alive\r
        User-Agent: Bun/1.4.0\r
        Host: 127.0.0.1:8991\r
        \r

        """

    /// The rate-limit headers as captured live — ARCHITECTURE.md §2.4.
    static let rateLimitHeaders: [(String, String)] = [
        ("anthropic-ratelimit-unified-status", "allowed"),
        ("anthropic-ratelimit-unified-5h-status", "allowed"),
        ("anthropic-ratelimit-unified-5h-reset", "1785022800"),
        ("anthropic-ratelimit-unified-5h-utilization", "0.15"),
        ("anthropic-ratelimit-unified-7d-status", "allowed"),
        ("anthropic-ratelimit-unified-7d-reset", "1785027600"),
        ("anthropic-ratelimit-unified-7d-utilization", "0.14"),
        ("anthropic-ratelimit-unified-representative-claim", "five_hour"),
        ("anthropic-ratelimit-unified-fallback-percentage", "0.5"),
        ("anthropic-ratelimit-unified-overage-status", "rejected"),
        ("anthropic-ratelimit-unified-overage-disabled-reason", "org_level_disabled"),
    ]

    static func sseResponseHead() -> String {
        """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream\r
        Transfer-Encoding: chunked\r
        Connection: keep-alive\r
        \(rateLimitHeaders.map { "\($0.0): \($0.1)\r\n" }.joined())\r

        """
    }

    static func chunk(_ payload: String) -> Data {
        let body = Data(payload.utf8)
        var out = Data(String(format: "%x\r\n", body.count).utf8)
        out.append(body)
        out.append(Data("\r\n".utf8))
        return out
    }

    static let terminalChunk = Data("0\r\n\r\n".utf8)
}

import Foundation

/// A byte stream the proxy can pull from.
///
/// An empty `Data` means "nothing available yet, ask again"; `nil` means the
/// peer closed. Abstracting this is what lets the streaming path be tested
/// without opening a socket.
protocol ByteSource: Sendable {
    func readMore() async throws -> Data?
}

/// A byte stream the proxy can push to, unmodified.
protocol ByteSink: Sendable {
    func write(_ data: Data) async throws
}

/// Incremental reader over a `ByteSource`.
///
/// Buffers only until the end of the current *head*. Body bytes are handed to
/// the caller as they arrive and are never accumulated — that is what keeps SSE
/// responses flowing and 250 KB request bodies off the heap.
final class HTTPStreamReader {
    private let source: any ByteSource
    private let timeout: Duration
    private var buffer = Data()
    private var reachedEOF = false

    init(source: any ByteSource, timeout: Duration) {
        self.source = source
        self.timeout = timeout
    }

    var hasBufferedBytes: Bool { !buffer.isEmpty }
    var isAtEOF: Bool { reachedEOF && buffer.isEmpty }

    /// Pulls one more slice from the socket into the buffer.
    /// Returns `false` at end of stream.
    @discardableResult
    private func fill(timeout override: Duration? = nil) async throws -> Bool {
        if reachedEOF { return false }
        while true {
            let received = try await withProxyTimeout(override ?? timeout) { [source] in
                try await source.readMore()
            }
            guard let received else {
                reachedEOF = true
                return false
            }
            if received.isEmpty { continue } // no data yet, keep waiting
            buffer.append(received)
            return true
        }
    }

    /// Reads through the blank line that terminates an HTTP head.
    ///
    /// Throws `.peerClosed` if the connection ended cleanly before any bytes of a
    /// new message — the normal way a keep-alive connection retires.
    ///
    /// `completionTimeout`, when given, bounds the time from a head's *first
    /// byte* to its final one — one budget for the whole head, not one per
    /// read. Waiting for a head to begin may take as long as the reader's own
    /// timeout allows (an idle kept-alive connection is legitimate), but once
    /// bytes have arrived the clock runs and does not reset: a drip-feed of
    /// one byte per interval — the classic slowloris, each gap innocently
    /// short — burns the same budget as one long stall. Buffered leftovers
    /// from a previous message count as a started head, which is the
    /// conservative side of the line.
    ///
    /// The scan is incremental: `scannedUpTo` remembers how far the previous
    /// pass looked, so each byte is visited once however fragmented the
    /// delivery — a 1-byte-at-a-time head used to rescan from zero per byte.
    func readHead(maximumSize: Int, completionTimeout: Duration? = nil) async throws -> Data {
        let clock = ContinuousClock()
        var headStartedAt: ContinuousClock.Instant? = buffer.isEmpty ? nil : clock.now
        var scannedUpTo = 0
        while true {
            // Resume 3 bytes back: a CRLFCRLF split across two reads leaves at
            // most its first three bytes at the old buffer end.
            if let end = HTTPHeadParser.endOfHead(in: buffer, from: max(0, scannedUpTo - 3)) {
                let head = buffer.prefix(end)
                buffer.removeFirst(end)
                return Data(head)
            }
            scannedUpTo = buffer.count
            // After the scan, not before: one read can deliver a complete head
            // plus the body behind it, and a fat body must not be mistaken for
            // a fat head.
            if buffer.count > maximumSize { throw ProxyError.headTooLarge }

            var readBudget: Duration? = nil
            if let completionTimeout, let headStartedAt {
                let remaining = completionTimeout - (clock.now - headStartedAt)
                guard remaining > .zero else { throw ProxyError.timedOut }
                readBudget = remaining
            }
            let more = try await fill(timeout: readBudget)
            if headStartedAt == nil { headStartedAt = clock.now }
            if !more {
                if buffer.isEmpty { throw ProxyError.peerClosed }
                throw ProxyError.malformedHead
            }
        }
    }

    /// Next slice of body bytes, at most `limit`. `nil` at end of stream.
    func nextBodyBytes(limit: Int) async throws -> Data? {
        if buffer.isEmpty {
            let more = try await fill()
            if !more { return nil }
        }
        let take = Swift.min(limit, buffer.count)
        let slice = buffer.prefix(take)
        buffer.removeFirst(take)
        return Data(slice)
    }

    /// Returns unconsumed bytes to the front of the buffer (next pipelined message).
    func pushBack(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer = data + buffer
    }
}

/// Copies a message body from `reader` to `destination` without buffering it.
enum BodyRelay {
    static func relay(
        framing: BodyFraming,
        from reader: HTTPStreamReader,
        to destination: any ByteSink,
        chunkSize: Int
    ) async throws {
        switch framing {
        case .none:
            return

        case .contentLength(let total):
            var remaining = total
            while remaining > 0 {
                guard let slice = try await reader.nextBodyBytes(limit: Swift.min(chunkSize, remaining)) else {
                    throw ProxyError.peerClosed
                }
                remaining -= slice.count
                try await destination.write(slice)
            }

        case .chunked:
            var scanner = ChunkedBodyScanner()
            while !scanner.isComplete {
                guard let slice = try await reader.nextBodyBytes(limit: chunkSize) else {
                    throw ProxyError.peerClosed
                }
                let consumed = try scanner.consume(slice)
                // Chunk framing is relayed verbatim; the scanner only tells us
                // where the message ends so the connection can be reused.
                try await destination.write(Data(slice.prefix(consumed)))
                if consumed < slice.count {
                    reader.pushBack(Data(slice.dropFirst(consumed)))
                }
            }

        case .untilClose:
            while let slice = try await reader.nextBodyBytes(limit: chunkSize) {
                try await destination.write(slice)
            }
        }
    }
}

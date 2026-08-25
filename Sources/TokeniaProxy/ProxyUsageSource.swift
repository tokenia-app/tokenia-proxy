import Foundation
import TokeniaCore

/// The proxy's implementation of `UsageSource`.
///
/// Holds exactly one thing: the last parsed `UsageSnapshot` (a handful of
/// numbers and two dates). No bodies, no headers, no token — see
/// ARCHITECTURE §3.1.
///
/// Every subscriber gets its own `AsyncStream`; a new subscriber is replayed the
/// current snapshot immediately so a menu bar opened mid-session is not blank.
public final class ProxyUsageSource: UsageSource, @unchecked Sendable {
    private let lock = NSLock()
    private var storedLatest: UsageSnapshot?
    private var storedRequestsSeen: Int = 0
    private var storedLastRequestAt: Date?
    private var continuations: [UUID: AsyncStream<UsageSnapshot>.Continuation] = [:]

    public init(initial: UsageSnapshot? = nil) {
        self.storedLatest = initial
    }

    /// The most recent reading, or `nil` if Claude Code has not made a request yet.
    public var latest: UsageSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return storedLatest
    }

    /// How many upstream responses have passed through `ingest`, whether or
    /// not they carried limit headers. Served on `/__tokenia/status` so the
    /// app can tell "no traffic at all" from "traffic without limits" —
    /// the two states the snapshot alone cannot separate. A count and a
    /// date, nothing derived from the traffic itself (ARCHITECTURE §3.1).
    public var requestsSeen: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRequestsSeen
    }

    /// When `ingest` last saw a response, regardless of what it carried.
    public var lastRequestAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastRequestAt
    }

    public var snapshots: AsyncStream<UsageSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            let replay = storedLatest
            lock.unlock()

            if let replay { continuation.yield(replay) }

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    /// The protocol's default `events` fabricates zero counters from
    /// `snapshots`; this source has the real ones, and an in-process consumer
    /// (the hosting mode `ProxyServer` documents) must not be told "no
    /// traffic" while traffic flows. Each yield reads the counters at that
    /// moment, and a subscriber starts with the current state rather than
    /// silence.
    public var events: AsyncStream<UsageSourceEvent> {
        let base = snapshots
        return AsyncStream { continuation in
            let task = Task { [weak self] in
                if let self {
                    continuation.yield(.status(
                        snapshot: self.latest,
                        requestsSeen: self.requestsSeen,
                        lastRequestAt: self.lastRequestAt
                    ))
                }
                for await snapshot in base {
                    guard let self else { break }
                    continuation.yield(.status(
                        snapshot: snapshot,
                        requestsSeen: self.requestsSeen,
                        lastRequestAt: self.lastRequestAt
                    ))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Parses response headers and publishes a snapshot if they carried limits.
    ///
    /// Returns the snapshot that was published, or `nil` when the response was
    /// not rate-limit bearing (health checks, errors, non-API routes).
    @discardableResult
    public func ingest(responseHeaders: HTTPHeaders, capturedAt: Date = Date()) -> UsageSnapshot? {
        ingest(responseHeaders: responseHeaders.dictionary, capturedAt: capturedAt)
    }

    @discardableResult
    public func ingest(responseHeaders: [String: String], capturedAt: Date = Date()) -> UsageSnapshot? {
        lock.lock()
        storedRequestsSeen += 1
        storedLastRequestAt = capturedAt
        lock.unlock()

        guard let snapshot = RateLimitHeaderParser.parse(responseHeaders, capturedAt: capturedAt) else {
            return nil
        }
        publish(snapshot)
        return snapshot
    }

    public func publish(_ snapshot: UsageSnapshot) {
        lock.lock()
        storedLatest = snapshot
        let targets = Array(continuations.values)
        lock.unlock()

        for continuation in targets { continuation.yield(snapshot) }
        ProxyLog.emit(.snapshotPublished)
    }

    /// Ends all subscriber streams. Call when the proxy shuts down.
    public func finish() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in targets { continuation.finish() }
    }
}

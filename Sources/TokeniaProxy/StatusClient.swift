import Foundation
import TokeniaCore

/// Reads snapshots from a proxy running in another process.
///
/// The LaunchAgent owns the proxy so that quitting the menu bar app cannot
/// break Claude Code (ARCHITECTURE §3.3). That puts the UI and the proxy in
/// separate processes, so the UI polls this loopback endpoint instead of
/// holding the source directly.
///
/// Polling here is free: it never leaves the machine and never touches the
/// Anthropic API, so it costs no quota no matter how often it runs.
public struct StatusClient: Sendable {
    public let port: UInt16
    public let host: String

    public init(port: UInt16, host: String = "127.0.0.1") {
        self.port = port
        self.host = host
    }

    public var url: URL {
        URL(string: "http://\(host):\(port)\(ProxyRoute.statusPath)")!
    }

    /// Reads `/__tokenia/status` and reports what the proxy knows. Throws when
    /// the proxy cannot be read at all — unreachable, non-200, or unparseable —
    /// so the caller can tell an outage from a proxy that has simply seen
    /// nothing yet. It used to return a bare `UsageSnapshot?`, which collapsed
    /// those into the same `nil` and let a broken transport impersonate quiet.
    public func fetch() async throws -> ProxyStatusReport {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw StatusClientError.unexpectedResponse
        }
        guard let report = Self.decode(data) else {
            throw StatusClientError.unexpectedResponse
        }
        return report
    }

    static func decode(_ data: Data) -> ProxyStatusReport? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let payload = object as? [String: Any],
            let available = payload["available"] as? Bool
        else { return nil }

        let requestsSeen = payload["requestsSeen"] as? Int ?? 0
        let lastRequestAt = (payload["lastRequestAt"] as? TimeInterval)
            .map(Date.init(timeIntervalSince1970:))

        var snapshot: UsageSnapshot?
        if available, let capturedAt = payload["capturedAt"] as? TimeInterval {
            snapshot = UsageSnapshot(
                fiveHour: window(payload["fiveHour"]),
                sevenDay: window(payload["sevenDay"]),
                representativeClaim: payload["representativeClaim"] as? String,
                overageStatus: payload["overageStatus"] as? String,
                capturedAt: Date(timeIntervalSince1970: capturedAt)
            )
        }
        return ProxyStatusReport(
            snapshot: snapshot,
            requestsSeen: requestsSeen,
            lastRequestAt: lastRequestAt
        )
    }

    private static func window(_ raw: Any?) -> LimitWindow? {
        guard
            let fields = raw as? [String: Any],
            let utilization = fields["utilization"] as? Double,
            let resetAt = fields["resetAt"] as? TimeInterval
        else { return nil }

        return LimitWindow(
            status: fields["status"] as? String ?? "unknown",
            utilization: utilization,
            resetAt: Date(timeIntervalSince1970: resetAt)
        )
    }
}

public enum StatusClientError: Error, Sendable {
    case unexpectedResponse
}

/// Everything one read of `/__tokenia/status` says: the parsed snapshot (nil
/// when no limit headers have been seen), plus how much traffic the proxy has
/// observed at all. A report, not a bare snapshot, so "reachable but empty"
/// stops being indistinguishable from "unreachable".
public struct ProxyStatusReport: Sendable, Equatable {
    public let snapshot: UsageSnapshot?
    public let requestsSeen: Int
    public let lastRequestAt: Date?

    public init(snapshot: UsageSnapshot?, requestsSeen: Int, lastRequestAt: Date?) {
        self.snapshot = snapshot
        self.requestsSeen = requestsSeen
        self.lastRequestAt = lastRequestAt
    }
}

/// A `UsageSource` backed by polling a proxy in another process.
///
/// Emits only when the reading actually changes, so an idle Claude Code
/// produces no UI churn — and staleness stays visible rather than being
/// papered over by a refreshed timestamp.
///
/// Failures are news too. Two swallowed `try?`s here once collapsed
/// "connection refused" into the same silence as "no traffic yet", and the
/// popover showed a green "live" dot above "Waiting for data" for hours while
/// macOS's ATS was rejecting every poll before a socket existed. `events` is
/// the primary stream and carries `.unreachable`; `snapshots` remains for
/// callers that only want readings.
public struct PollingUsageSource: UsageSource {
    private let client: StatusClient
    private let interval: Duration

    /// Failures below this stay silent: a `kickstart -k` — the documented
    /// upgrade and repair dance — makes a poll or two fail as a matter of
    /// course, and flashing the popover's "silent" state for every routine
    /// restart would teach people to ignore it. Three misses is six seconds,
    /// which no kickstart takes and every real outage exceeds.
    private static let announceAfter = 3

    /// After this many consecutive failures the count is re-announced, so the
    /// consumer's "how long has this been down" stays roughly current without
    /// a yield per tick.
    private static let reannounceEvery = 15

    public init(client: StatusClient, interval: Duration = .seconds(2)) {
        self.client = client
        self.interval = interval
    }

    public var events: AsyncStream<UsageSourceEvent> {
        AsyncStream { continuation in
            let task = Task {
                var previous: ProxyStatusReport?
                var failures = 0
                while !Task.isCancelled {
                    if let report = try? await client.fetch() {
                        // Re-announce after a *reported* outage so the UI can
                        // clear it; a sub-threshold blip was never reported and
                        // needs no correction.
                        let recovered = failures >= Self.announceAfter
                        failures = 0
                        if recovered || report != previous {
                            previous = report
                            continuation.yield(.status(
                                snapshot: report.snapshot,
                                requestsSeen: report.requestsSeen,
                                lastRequestAt: report.lastRequestAt
                            ))
                        }
                    } else {
                        failures += 1
                        if failures == Self.announceAfter || failures.isMultiple(of: Self.reannounceEvery) {
                            continuation.yield(.unreachable(consecutiveFailures: failures))
                        }
                    }
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public var snapshots: AsyncStream<UsageSnapshot> {
        let base = events
        return AsyncStream { continuation in
            let task = Task {
                for await event in base {
                    if case .status(let snapshot?, _, _) = event {
                        continuation.yield(snapshot)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

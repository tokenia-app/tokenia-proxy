import Foundation

/// One rate-limit window reported by Anthropic (5-hour or 7-day).
public struct LimitWindow: Sendable, Equatable {
    /// Raw status string, e.g. "allowed" or "rejected".
    public let status: String
    /// Fraction of the window already consumed, 0.0 … 1.0.
    public let utilization: Double
    /// When this window rolls over.
    public let resetAt: Date

    public init(status: String, utilization: Double, resetAt: Date) {
        self.status = status
        self.utilization = utilization
        self.resetAt = resetAt
    }

    /// Fraction still available, clamped to 0…1.
    public var remainingFraction: Double {
        min(1, max(0, 1 - utilization))
    }

    public var isAllowed: Bool { status == "allowed" }

    public func timeRemaining(from now: Date = Date()) -> TimeInterval {
        max(0, resetAt.timeIntervalSince(now))
    }
}

/// Which window Anthropic considers the binding one right now.
public enum RepresentativeClaim: String, Sendable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
}

/// A point-in-time reading of both limit windows.
///
/// Captured from the headers of a real request the user made — never from a
/// request we issued ourselves. See ARCHITECTURE.md §1.
public struct UsageSnapshot: Sendable, Equatable {
    public let fiveHour: LimitWindow?
    public let sevenDay: LimitWindow?
    public let representativeClaim: String?
    /// Raw `overage-status` header, e.g. "allowed" or "rejected" — whether
    /// pay-as-you-go credits are covering requests past the plan's own
    /// limit. When this is "allowed" and a window itself reports
    /// `status != "allowed"`, the plan quota is exhausted but requests keep
    /// succeeding because credits are paying for them — the window's own
    /// `utilization` can stay short of 1.0 forever in that state, since
    /// further usage is metered separately and no longer increments it.
    public let overageStatus: String?
    /// When these headers were observed. Drives the staleness indicator.
    public let capturedAt: Date

    public init(
        fiveHour: LimitWindow?,
        sevenDay: LimitWindow?,
        representativeClaim: String? = nil,
        overageStatus: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.representativeClaim = representativeClaim
        self.overageStatus = overageStatus
        self.capturedAt = capturedAt
    }

    /// The window the menu bar should display.
    ///
    /// Prefers Anthropic's own `representative-claim`; if that is missing or
    /// unrecognised, falls back to whichever window has less headroom.
    public var representative: LimitWindow? {
        switch representativeClaim.flatMap(RepresentativeClaim.init(rawValue:)) {
        case .fiveHour: return fiveHour ?? sevenDay
        case .sevenDay: return sevenDay ?? fiveHour
        case nil: break
        }
        switch (fiveHour, sevenDay) {
        case let (five?, seven?):
            return five.remainingFraction <= seven.remainingFraction ? five : seven
        case let (five?, nil): return five
        case let (nil, seven?): return seven
        case (nil, nil): return nil
        }
    }

    public func age(from now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(capturedAt))
    }
}

/// One poll's worth of news from a usage source.
///
/// Exists because `snapshots` alone could not say *why* it was silent: a proxy
/// that is unreachable and a proxy that has simply seen no traffic both
/// produced the same nothing, and the popover sat on "Waiting for data" with a
/// green dot while the real fault (macOS 26.6.2's ATS refusing cleartext
/// loopback from the bundle) stayed invisible for hours. The stream of events
/// keeps the failure distinguishable from the quiet.
public enum UsageSourceEvent: Sendable, Equatable {
    /// The source answered. `snapshot` is nil when it has seen no
    /// rate-limit-bearing traffic yet; the counters say whether *any*
    /// forwarded response has been observed, which is what separates
    /// "no traffic" from "traffic without limit headers".
    case status(snapshot: UsageSnapshot?, requestsSeen: Int, lastRequestAt: Date?)
    /// The source could not be read at all. Emitted with a running count so
    /// the consumer can distinguish a blip from an outage.
    case unreachable(consecutiveFailures: Int)
}

/// Anything that can supply usage readings — the real proxy, or a mock.
public protocol UsageSource: Sendable {
    /// Emits a new snapshot every time fresh headers are observed.
    var snapshots: AsyncStream<UsageSnapshot> { get }

    /// The richer feed: snapshots plus reachability. Conformers that can tell
    /// the difference (the polling client) implement this as the primary
    /// stream; everyone else gets the default mapping from `snapshots`, which
    /// by construction never reports unreachability.
    var events: AsyncStream<UsageSourceEvent> { get }
}

extension UsageSource {
    public var events: AsyncStream<UsageSourceEvent> {
        let base = snapshots
        return AsyncStream { continuation in
            let task = Task {
                for await snapshot in base {
                    continuation.yield(.status(
                        snapshot: snapshot,
                        requestsSeen: 0,
                        lastRequestAt: snapshot.capturedAt
                    ))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

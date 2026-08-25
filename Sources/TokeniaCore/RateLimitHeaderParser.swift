import Foundation

/// Turns Anthropic's `anthropic-ratelimit-unified-*` response headers into a snapshot.
///
/// Header names and semantics were verified against a live `claude-cli/2.1.220`
/// session — see ARCHITECTURE.md §2.4 for the captured sample.
public enum RateLimitHeaderParser {
    private static let prefix = "anthropic-ratelimit-unified-"

    public static func parse(
        _ headers: [String: String],
        capturedAt: Date = Date()
    ) -> UsageSnapshot? {
        // HTTP header names are case-insensitive; normalise once up front.
        let normalized = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { _, last in last }
        )

        let five = window(prefix: "\(prefix)5h-", in: normalized)
        let seven = window(prefix: "\(prefix)7d-", in: normalized)

        // Nothing usable — this response simply wasn't rate-limit bearing.
        guard five != nil || seven != nil else { return nil }

        return UsageSnapshot(
            fiveHour: five,
            sevenDay: seven,
            representativeClaim: normalized["\(prefix)representative-claim"],
            overageStatus: normalized["\(prefix)overage-status"],
            capturedAt: capturedAt
        )
    }

    private static func window(prefix: String, in headers: [String: String]) -> LimitWindow? {
        // `utilization` and `reset` are both required; a window without them
        // can't be rendered, so treat it as absent rather than half-populated.
        guard
            let utilizationRaw = headers["\(prefix)utilization"],
            let utilization = Double(utilizationRaw),
            let resetRaw = headers["\(prefix)reset"],
            let resetEpoch = Double(resetRaw)
        else { return nil }

        return LimitWindow(
            status: headers["\(prefix)status"] ?? "unknown",
            utilization: utilization,
            resetAt: Date(timeIntervalSince1970: resetEpoch)
        )
    }
}

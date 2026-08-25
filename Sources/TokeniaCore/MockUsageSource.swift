import Foundation

/// Drives the UI without a running proxy.
///
/// Slowly consumes both windows so progress bars, colour thresholds and the
/// countdown can all be exercised by eye during development.
public struct MockUsageSource: UsageSource {
    private let interval: Duration
    private let startUtilization: Double
    private let step: Double

    public init(
        interval: Duration = .seconds(2),
        startUtilization: Double = 0.15,
        step: Double = 0.04
    ) {
        self.interval = interval
        self.startUtilization = startUtilization
        self.step = step
    }

    public var snapshots: AsyncStream<UsageSnapshot> {
        AsyncStream { continuation in
            let task = Task {
                var fiveUtil = startUtilization
                var sevenUtil = startUtilization - 0.01

                let fiveReset = Date().addingTimeInterval(2 * 3600 + 14 * 60)
                let sevenReset = Date().addingTimeInterval(3 * 24 * 3600)

                while !Task.isCancelled {
                    continuation.yield(
                        UsageSnapshot(
                            fiveHour: LimitWindow(
                                status: fiveUtil >= 1 ? "rejected" : "allowed",
                                utilization: min(1, fiveUtil),
                                resetAt: fiveReset
                            ),
                            sevenDay: LimitWindow(
                                status: sevenUtil >= 1 ? "rejected" : "allowed",
                                utilization: min(1, sevenUtil),
                                resetAt: sevenReset
                            ),
                            representativeClaim: RepresentativeClaim.fiveHour.rawValue,
                            capturedAt: Date()
                        )
                    )

                    // Wrap around so the demo keeps cycling through every colour.
                    fiveUtil = fiveUtil >= 1 ? startUtilization : fiveUtil + step
                    sevenUtil = sevenUtil >= 1 ? startUtilization : sevenUtil + step / 3

                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

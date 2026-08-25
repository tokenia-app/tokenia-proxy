import Foundation
import Testing
import TokeniaCore
@testable import TokeniaProxy

/// The wire contract between the proxy's `/__tokenia/status` and the app's
/// reader, pinned the same way `ProxyContractTests` pins the health check:
/// encode with the real server code, decode with the real client code, and
/// fail here rather than in a popover that silently says "Waiting for data".
@Suite("Status wire contract")
struct StatusClientTests {
    @Test("No snapshot still reports the traffic counters")
    func emptyStatusCarriesCounters() throws {
        let when = Date(timeIntervalSince1970: 1_785_000_123)
        let (_, body) = ProxyResponses.status(nil, requestsSeen: 7, lastRequestAt: when)

        let report = try #require(StatusClient.decode(body))
        #expect(report.snapshot == nil)
        #expect(report.requestsSeen == 7)
        #expect(report.lastRequestAt == when)
    }

    @Test("A full snapshot round-trips, overage status included")
    func fullSnapshotRoundTrips() throws {
        let snapshot = UsageSnapshot(
            // 0.25/0.5, not the 0.19/0.07 seen in the wild: JSONSerialization does
            // not round-trip every Double bit-for-bit, and this test pins the
            // contract, not IEEE 754 folklore.
            fiveHour: LimitWindow(status: "allowed", utilization: 0.25, resetAt: Date(timeIntervalSince1970: 1_787_268_000)),
            sevenDay: LimitWindow(status: "allowed", utilization: 0.5, resetAt: Date(timeIntervalSince1970: 1_787_446_800)),
            representativeClaim: "five_hour",
            overageStatus: "allowed",
            capturedAt: Date(timeIntervalSince1970: 1_787_250_577)
        )
        let (_, body) = ProxyResponses.status(snapshot, requestsSeen: 42, lastRequestAt: snapshot.capturedAt)

        let report = try #require(StatusClient.decode(body))
        // `overageStatus` used to be parsed from headers and then dropped in
        // both directions — never encoded, never decoded — so any overage
        // state was invisible to the UI. Equality here covers it.
        #expect(report.snapshot == snapshot)
        #expect(report.requestsSeen == 42)
    }

    @Test("A pre-counter proxy still decodes")
    func oldPayloadWithoutCountersDecodes() throws {
        // An app updated before the proxy restarts reads the old shape for a
        // while. Missing counters mean zero/nil, not a decode failure.
        let body = Data(#"{"available":false}"#.utf8)
        let report = try #require(StatusClient.decode(body))
        #expect(report.snapshot == nil)
        #expect(report.requestsSeen == 0)
        #expect(report.lastRequestAt == nil)
    }

    @Test("Garbage is a decode failure, not an empty report")
    func garbageIsNil() {
        // `fetch()` turns nil into a thrown error so the poller counts it as
        // unreachable — a proxy answering nonsense must not impersonate a
        // healthy-but-quiet one.
        #expect(StatusClient.decode(Data("not json".utf8)) == nil)
        #expect(StatusClient.decode(Data("{}".utf8)) == nil)
    }
}

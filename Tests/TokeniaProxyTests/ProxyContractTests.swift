import Foundation
import Testing

import TokeniaTestSupport
@testable import TokeniaProxy

/// The seam between the two halves of the install.
///
/// `ProxyInstaller` refuses to touch `settings.json` until the proxy answers a
/// health check, and it asks on a path it spells out itself — `TokeniaConfig`
/// cannot import `TokeniaProxy`, because `scripts/install.sh` compiles that
/// directory alone with `swiftc`. Two literals in two targets is a drift waiting
/// to happen, and the drift is silent: setup would time out and roll back on a
/// proxy that is running perfectly well. This suite is the thing that fails
/// instead.
@Suite("Proxy contract")
struct ProxyContractTests {
    @Test("the installer probes the path the proxy actually answers")
    func probePathMatchesRouteTable() {
        #expect(ProxyHealthProbe.healthCheckPath == ProxyRoute.healthCheckPath)
    }

    @Test("that path is routed to the health check, not forwarded upstream")
    func probePathIsIntercepted() {
        let head = HTTPRequestHead(method: "HEAD", target: ProxyHealthProbe.healthCheckPath)
        #expect(ProxyRoute.route(head) == .healthCheck)
    }

    @Test("the probe recognises a real proxy over a real socket")
    func probeSucceedsAgainstRunningServer() async throws {
        let server = ProxyServer(configuration: ProxyConfiguration(port: 0))
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let probe = ProxyHealthProbe(port: port)
        #expect(await probe.isHealthy())
    }

    @Test("and gives up on a port with nothing behind it")
    func probeFailsAgainstClosedPort() async throws {
        // Bound and released: nothing is listening, but the number is plausible.
        let port = try PortSelector.findAvailablePort(startingAt: 8900)
        let probe = ProxyHealthProbe(port: port, attempts: 2, interval: .milliseconds(10))

        let started = ContinuousClock.now
        #expect(await probe.waitUntilHealthy() == false)
        // Connection refused comes back at once; the point is that the two-second
        // per-request timeout is not being paid on every attempt.
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}

@Suite("Configuration contract")
struct ConfigurationContractTests {
    @Test("the upstream TLS knob defaults to on")
    func upstreamTLSDefaultsOn() {
        // `upstreamUsesTLS: false` exists solely so tests and the stress
        // harness can stand a loopback fake in for api.anthropic.com. The
        // default carrying a live OAuth token over TLS is not a preference —
        // this pin is what makes the knob safe to have at all.
        #expect(ProxyConfiguration().upstreamUsesTLS == true)
    }
}

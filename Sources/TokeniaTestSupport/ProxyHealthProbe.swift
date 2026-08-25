// Copy of the app's `TokeniaConfig/ProxyHealthProbe.swift` — the probe half
// of the install contract these tests pin. Kept verbatim so the contract
// being tested is the one that actually ships.
import Foundation

/// Asks the proxy whether it is actually answering, before anything is told to
/// use it.
///
/// launchd accepting a job means only that it parsed the plist. The binary can
/// still fail to bind its port a moment later, and a `settings.json` that names
/// a dead listener is the failure ARCHITECTURE §3.3 calls the #1 product risk —
/// Claude Code stops working and nothing on screen says why. So `install`
/// bootstraps the agent, waits here, and only then edits the file.
///
/// The defaults mirror `scripts/install.sh` (20 tries, half a second apart, two
/// seconds per request) so the app and the shell installer give up after the
/// same ten seconds rather than behaving differently on a slow machine.
public struct ProxyHealthProbe: Sendable {
    /// Deliberately a second copy of `TokeniaProxy.ProxyRoute.healthCheckPath`
    /// rather than a shared constant. `TokeniaConfig` imports nothing but
    /// Foundation on purpose: `scripts/install.sh` compiles this one directory
    /// with a bare `swiftc`, before any package has been built, so a dependency
    /// on another target would break installing from a clone. The two literals
    /// are held together by `ProxyContractTests` instead.
    public static let healthCheckPath = "/api/hello"

    public let port: UInt16
    public let host: String
    public let attempts: Int
    public let interval: Duration

    public init(
        port: UInt16,
        host: String = "127.0.0.1",
        attempts: Int = 20,
        interval: Duration = .milliseconds(500)
    ) {
        self.port = port
        self.host = host
        self.attempts = max(attempts, 1)
        self.interval = interval
    }

    public var url: URL {
        URL(string: "http://\(host):\(port)\(Self.healthCheckPath)")!
    }

    /// The ceiling on `waitUntilHealthy()`, rounded to whole seconds, for error
    /// messages that have to tell the user how long we waited.
    public var budgetSeconds: Int {
        let components = interval.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return max(Int((seconds * Double(attempts)).rounded()), 1)
    }

    /// True as soon as the proxy answers, false if it never does.
    ///
    /// Deliberately does not throw. Every failure here means one thing to the
    /// caller — the proxy is not up — and while launchd is still starting the
    /// process, "connection refused" and "timed out" are the same answer.
    public func waitUntilHealthy() async -> Bool {
        for attempt in 0..<attempts {
            if await isHealthy() { return true }
            // No sleep after the last attempt; it would only delay the failure.
            if attempt < attempts - 1 { try? await Task.sleep(for: interval) }
        }
        return false
    }

    /// One `HEAD /api/hello`. Any 2xx counts.
    ///
    /// `HEAD` because that is the only method the proxy answers itself — every
    /// other request on that path is forwarded to Anthropic, so a `GET` here
    /// would prove the network works rather than that the proxy is running
    /// (`ProxyRoute.route`). Caching is off for the same reason a liveness check
    /// always has it off: a cached 200 outlives the process that sent it.
    public func isHealthy() async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard
            let (_, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse
        else { return false }
        return (200..<300).contains(http.statusCode)
    }
}

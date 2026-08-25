import Foundation

public struct ProxyConfiguration: Sendable {
    /// Loopback only. The proxy carries a live OAuth bearer token; it must never
    /// be reachable from the network.
    public var port: UInt16

    public var upstreamHost: String
    public var upstreamPort: UInt16

    /// Maximum quiet period on a single read before the peer is declared dead.
    ///
    /// Must stay above the client's own `X-Stainless-Timeout: 600`
    /// (ARCHITECTURE §2.3) — giving up first would turn our proxy into the
    /// reason a long request failed.
    public var upstreamTimeout: Duration

    /// Once the first byte of a head has arrived, the rest must follow within
    /// this budget. Distinct from `upstreamTimeout` on purpose: an *idle*
    /// kept-alive connection may legitimately sit quiet for the full long
    /// timeout waiting for the user's next prompt, but a *started* head that
    /// dribbles is either a broken client or a slowloris — before this knob,
    /// each such client held a session (and its upstream TLS connection) for
    /// the whole 660 seconds.
    public var clientHeadCompletionTimeout: Duration

    /// Ceiling on a single HTTP head. Checked after each read, so the buffer
    /// can overshoot by at most one `receiveChunkSize` before the connection
    /// is refused — bounded, and cheaper than checking mid-append.
    public var maximumHeadSize: Int

    /// Read granularity. Smaller means lower SSE latency; 32 KiB is well under
    /// the size of a single streamed event, so events are never held back.
    public var receiveChunkSize: Int

    /// Hard cap on simultaneous client connections. Each session can hold an
    /// upstream TLS socket and a few tasks, so an unbounded accept loop is an
    /// fd-exhaustion bug waiting for a port scanner. 128 is far above Claude
    /// Code's real parallelism and far below any resource limit.
    public var maximumConcurrentConnections: Int

    /// TLS to the upstream. True in every real configuration; false exists
    /// only so tests and the stress harness can stand a loopback fake in for
    /// `api.anthropic.com`. `ProxyContractTests` pins the default.
    public var upstreamUsesTLS: Bool

    public init(
        port: UInt16 = 8787,
        upstreamHost: String = "api.anthropic.com",
        upstreamPort: UInt16 = 443,
        upstreamTimeout: Duration = .seconds(660),
        clientHeadCompletionTimeout: Duration = .seconds(30),
        maximumHeadSize: Int = 64 * 1024,
        receiveChunkSize: Int = 32 * 1024,
        maximumConcurrentConnections: Int = 128,
        upstreamUsesTLS: Bool = true
    ) {
        self.port = port
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
        self.upstreamTimeout = upstreamTimeout
        self.clientHeadCompletionTimeout = clientHeadCompletionTimeout
        self.maximumHeadSize = maximumHeadSize
        self.receiveChunkSize = receiveChunkSize
        self.maximumConcurrentConnections = maximumConcurrentConnections
        self.upstreamUsesTLS = upstreamUsesTLS
    }
}

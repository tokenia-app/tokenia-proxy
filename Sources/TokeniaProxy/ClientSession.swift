import Foundation
import Network

/// Serves one Claude Code connection for its whole lifetime.
///
/// HTTP/1.1 keep-alive: several requests may arrive in sequence on the same
/// socket, and one upstream TLS connection is reused for all of them so the
/// handshake is not repaid per request.
final class ClientSession {
    private let client: NetworkStream
    private let configuration: ProxyConfiguration
    private let usageSource: ProxyUsageSource
    private let queue: DispatchQueue

    private var upstream: NetworkStream?
    private var upstreamReader: HTTPStreamReader?

    init(
        client: NetworkStream,
        configuration: ProxyConfiguration,
        usageSource: ProxyUsageSource,
        queue: DispatchQueue
    ) {
        self.client = client
        self.configuration = configuration
        self.usageSource = usageSource
        self.queue = queue
    }

    func run() async {
        ProxyLog.emit(.clientAccepted)
        defer {
            client.cancel()
            upstream?.cancel()
            ProxyLog.emit(.clientFinished)
        }

        do {
            try await client.start()
        } catch {
            return
        }

        let reader = HTTPStreamReader(source: client, timeout: configuration.upstreamTimeout)

        while !Task.isCancelled {
            let head: HTTPRequestHead
            do {
                let raw = try await reader.readHead(
                    maximumSize: configuration.maximumHeadSize,
                    completionTimeout: configuration.clientHeadCompletionTimeout
                )
                head = try HTTPHeadParser.parseRequest(head: raw)
            } catch ProxyError.peerClosed {
                return
            } catch {
                let failure = ProxyFailure.from(error)
                if failure != .cancelled && failure != .connectionClosed {
                    ProxyLog.emit(.clientError(failure))
                    let error = ProxyResponses.badRequest(failure)
                    try? await write(error.head, body: error.body)
                }
                return
            }

            let keepAlive = Self.clientWantsKeepAlive(head)

            switch ProxyRoute.route(head) {
            case .healthCheck:
                ProxyLog.emit(.healthCheckServed)
                do {
                    try await write(ProxyResponses.healthCheck(), body: Data())
                } catch {
                    return
                }
                if !keepAlive { return }

            case .status:
                // Served from memory: the menu bar app reads this over
                // loopback, so refreshing the UI costs no API quota.
                let response = ProxyResponses.status(
                    usageSource.latest,
                    requestsSeen: usageSource.requestsSeen,
                    lastRequestAt: usageSource.lastRequestAt
                )
                do {
                    try await write(response.head, body: response.body)
                } catch {
                    return
                }
                if !keepAlive { return }

            case .forward:
                let outcome = await forward(head, from: reader)
                switch outcome {
                case .completed(let upstreamKeepAlive):
                    if !keepAlive || !upstreamKeepAlive { return }
                case .closeConnection:
                    return
                }
            }
        }
    }

    // MARK: - Forwarding

    private enum ForwardOutcome {
        case completed(upstreamKeepAlive: Bool)
        case closeConnection
    }

    private func forward(_ head: HTTPRequestHead, from reader: HTTPStreamReader) async -> ForwardOutcome {
        let requestFraming = BodyFraming.forRequest(head)
        let upstreamHead = HTTPRequestHead(
            method: head.method,
            target: head.target,
            version: "HTTP/1.1",
            headers: HeaderPolicy.upstreamHeaders(
                from: head.headers,
                upstreamHost: configuration.upstreamHost,
                framing: requestFraming
            )
        )

        // Send the head, retrying once on a pooled connection the server has
        // since dropped. Safe to retry here: no body bytes have been consumed yet.
        do {
            try await sendHeadUpstream(upstreamHead.serialized())
        } catch {
            return await failOpen(ProxyFailure.from(error))
        }

        guard let upstream, let upstreamReader else {
            return await failOpen(.other)
        }

        do {
            try await BodyRelay.relay(
                framing: requestFraming,
                from: reader,
                to: upstream,
                chunkSize: configuration.receiveChunkSize
            )
        } catch {
            let failure = ProxyFailure.from(error)
            // The client body was partially consumed; the request cannot be
            // replayed, so report and drop this connection.
            dropUpstream()
            if failure == .connectionClosed || failure == .cancelled { return .closeConnection }
            return await failOpen(failure)
        }

        // Response, streamed straight back.
        while true {
            let responseHead: HTTPResponseHead
            do {
                let raw = try await upstreamReader.readHead(maximumSize: configuration.maximumHeadSize)
                responseHead = try HTTPHeadParser.parseResponse(head: raw)
            } catch {
                dropUpstream()
                return await failOpen(ProxyFailure.from(error))
            }

            ProxyLog.emit(.responseObserved(status: responseHead.statusCode))

            // Only header names and values reach the parser; the body is never
            // read. 1xx heads are skipped: the real response is still coming,
            // and counting both would make one forwarded request read as two
            // on /__tokenia/status — the counter exists to be exact.
            if !(100..<200).contains(responseHead.statusCode) {
                usageSource.ingest(responseHeaders: responseHead.headers)
            }

            let responseFraming = BodyFraming.forResponse(responseHead, requestMethod: head.method)
            let upstreamKeepAlive = Self.upstreamWantsKeepAlive(responseHead) && responseFraming != .untilClose

            let downstream = HTTPResponseHead(
                version: "HTTP/1.1",
                statusCode: responseHead.statusCode,
                reasonPhrase: responseHead.reasonPhrase,
                headers: HeaderPolicy.downstreamHeaders(
                    from: responseHead.headers,
                    framing: responseFraming,
                    closeAfterResponse: !upstreamKeepAlive
                )
            )

            do {
                try await client.send(downstream.serialized())
                try await BodyRelay.relay(
                    framing: responseFraming,
                    from: upstreamReader,
                    to: client,
                    chunkSize: configuration.receiveChunkSize
                )
            } catch {
                // Response already in flight — nothing legible left to say.
                dropUpstream()
                return .closeConnection
            }

            // 1xx is informational: the real response is still coming.
            if (100..<200).contains(responseHead.statusCode) { continue }

            if !upstreamKeepAlive { dropUpstream() }
            return .completed(upstreamKeepAlive: upstreamKeepAlive)
        }
    }

    private func failOpen(_ failure: ProxyFailure) async -> ForwardOutcome {
        ProxyLog.emit(.upstreamFailed(failure))
        let error = ProxyResponses.gatewayError(failure)
        try? await write(error.head, body: error.body)
        return .closeConnection
    }

    // MARK: - Upstream plumbing

    private func sendHeadUpstream(_ data: Data) async throws {
        if upstream != nil {
            do {
                try await upstream?.send(data)
                return
            } catch {
                // Stale pooled connection. Reconnect and try once more.
                dropUpstream()
            }
        }
        try await connectUpstream()
        try await upstream?.send(data)
    }

    private func connectUpstream() async throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 30
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60

        let parameters: NWParameters
        if configuration.upstreamUsesTLS {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, configuration.upstreamHost)
            // Pin HTTP/1.1: this proxy speaks HTTP/1.1 on both sides, and letting
            // the server pick h2 would make our framing meaningless.
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            parameters = NWParameters(tls: tls, tcp: tcp)
        } else {
            // Test-only path: a loopback FakeUpstream standing in for
            // api.anthropic.com. The default is pinned true by ProxyContractTests.
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(configuration.upstreamHost),
            port: NWEndpoint.Port(rawValue: configuration.upstreamPort) ?? .https
        )
        let stream = NetworkStream(
            connection: NWConnection(to: endpoint, using: parameters),
            queue: queue,
            maximumReceive: configuration.receiveChunkSize
        )
        try await stream.start()
        ProxyLog.emit(.upstreamConnected)
        upstream = stream
        upstreamReader = HTTPStreamReader(source: stream, timeout: configuration.upstreamTimeout)
    }

    private func dropUpstream() {
        upstream?.cancel()
        upstream = nil
        upstreamReader = nil
    }

    private func write(_ head: HTTPResponseHead, body: Data) async throws {
        try await client.send(head.serialized())
        if !body.isEmpty { try await client.send(body) }
    }

    // MARK: - Connection reuse rules

    static func clientWantsKeepAlive(_ head: HTTPRequestHead) -> Bool {
        let connection = head.headers["Connection"]?.lowercased() ?? ""
        if connection.contains("close") { return false }
        if head.version.uppercased() == "HTTP/1.0" { return connection.contains("keep-alive") }
        return true
    }

    static func upstreamWantsKeepAlive(_ head: HTTPResponseHead) -> Bool {
        let connection = head.headers["Connection"]?.lowercased() ?? ""
        if connection.contains("close") { return false }
        if head.version.uppercased() == "HTTP/1.0" { return connection.contains("keep-alive") }
        return true
    }
}

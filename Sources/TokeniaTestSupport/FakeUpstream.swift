import Foundation
import Network

/// A loopback HTTP/1.1 server standing in for `api.anthropic.com`, for tests
/// and the stress harness (`ProxyConfiguration.upstreamUsesTLS = false` is the
/// other half of the arrangement).
///
/// Lives outside `Sources/TokeniaProxy` on purpose: SecurityTests scans that
/// target for anything that could leak traffic, and a server double is made of
/// exactly the APIs it forbids. Nothing here may ever log request contents
/// either — the bodies tests push through are synthetic, but the habit is the
/// point.
public final class FakeUpstream: @unchecked Sendable {
    public enum Behavior: Sendable {
        /// Answer every request with this response, keep-alive.
        case fixedResponse(status: Int, headers: [(String, String)], body: Data)
        /// A `text/event-stream` response: `events` chunks of `eventBytes`
        /// each, spaced by `interval`, carrying rate-limit headers so
        /// `ProxyUsageSource` ingestion is exercised end to end.
        case sse(events: Int, eventBytes: Int, interval: Duration)
        /// Read the request, never answer. The proxy's timeout is the subject.
        case stall
        /// Send a head promising `Content-Length` then close after `after`
        /// body bytes — the truncated-response case.
        case closeMidBody(after: Int)
        /// Read the request body per its Content-Length and reply with a small
        /// summary naming how many bytes arrived. Keeps huge-body tests
        /// honest without the fake buffering anything.
        case echoBody
    }

    /// The header block Anthropic answers with, minus anything sensitive —
    /// utilisations and reset epochs only, values distinct from the popover
    /// tests' fixtures so a cross-wired assertion cannot pass by accident.
    public static let rateLimitHeaders: [(String, String)] = [
        ("anthropic-ratelimit-unified-5h-utilization", "0.42"),
        ("anthropic-ratelimit-unified-5h-status", "allowed"),
        ("anthropic-ratelimit-unified-5h-reset", "1787300000"),
        ("anthropic-ratelimit-unified-7d-utilization", "0.13"),
        ("anthropic-ratelimit-unified-7d-status", "allowed"),
        ("anthropic-ratelimit-unified-7d-reset", "1787500000"),
        ("anthropic-ratelimit-unified-representative-claim", "five_hour"),
    ]

    private let behavior: Behavior
    private let queue = DispatchQueue(label: "com.tokenia.fake-upstream", attributes: .concurrent)
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var accepted = 0

    public init(behavior: Behavior) {
        self.behavior = behavior
    }

    /// How many connections have ever been accepted — the assertion hook for
    /// "did the proxy reconnect or reuse".
    public var acceptedConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return accepted
    }

    /// Starts listening on 127.0.0.1, port 0 (system-assigned). Returns the port.
    @discardableResult
    public func start() async throws -> UInt16 {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.lock()
            self.accepted += 1
            self.connections[ObjectIdentifier(connection)] = connection
            self.lock.unlock()
            connection.start(queue: self.queue)
            Task.detached { [weak self] in
                await self?.serve(connection)
                self?.forget(connection)
                connection.cancel()
            }
        }

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let box = ResumeOnce(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: box.resume(.success(listener.port?.rawValue ?? 0))
                case .failed(let error): box.resume(.failure(error))
                case .cancelled: box.resume(.failure(CancellationError()))
                default: break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        return port
    }

    private func forget(_ connection: NWConnection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = nil
        lock.unlock()
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let live = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        for connection in live { connection.cancel() }
    }

    // MARK: - Per-connection serving

    private func serve(_ connection: NWConnection) async {
        var buffer = Data()
        while true {
            // Read one request head (plus whatever body follows in the same
            // segments).
            guard let headEnd = await readUntilHeadEnd(connection, buffer: &buffer) else { return }
            let head = String(decoding: buffer.prefix(headEnd), as: UTF8.self)
            buffer.removeFirst(headEnd)
            let contentLength = Self.contentLength(inHead: head)

            // Drain the request body so keep-alive framing stays aligned.
            var bodyReceived = 0
            while bodyReceived + buffer.count < contentLength {
                bodyReceived += buffer.count
                buffer.removeAll(keepingCapacity: true)
                guard let more = await receive(connection) else { return }
                buffer = more
            }
            if contentLength > 0 {
                let fromBuffer = min(contentLength - bodyReceived, buffer.count)
                buffer.removeFirst(fromBuffer)
                bodyReceived += fromBuffer
            }

            switch behavior {
            case .fixedResponse(let status, let headers, let body):
                guard await send(connection, Self.response(status: status, headers: headers, body: body)) else { return }

            case .sse(let events, let eventBytes, let interval):
                var headers = Self.rateLimitHeaders
                headers.append(("Content-Type", "text/event-stream"))
                headers.append(("Transfer-Encoding", "chunked"))
                let head = "HTTP/1.1 200 OK\r\n" + Self.serialize(headers) + "\r\n"
                guard await send(connection, Data(head.utf8)) else { return }
                let payload = "data: " + String(repeating: "x", count: max(1, eventBytes)) + "\n\n"
                let chunk = String(format: "%x", payload.utf8.count) + "\r\n" + payload + "\r\n"
                for _ in 0..<events {
                    guard await send(connection, Data(chunk.utf8)) else { return }
                    if interval > .zero { try? await Task.sleep(for: interval) }
                }
                guard await send(connection, Data("0\r\n\r\n".utf8)) else { return }

            case .stall:
                // Hold the socket open, say nothing, wait to be cancelled.
                while await receive(connection) != nil {}
                return

            case .closeMidBody(let after):
                let promised = max(after + 1, after)
                var headers = Self.rateLimitHeaders
                headers.append(("Content-Length", String(promised + 1)))
                let head = "HTTP/1.1 200 OK\r\n" + Self.serialize(headers) + "\r\n"
                _ = await send(connection, Data(head.utf8))
                _ = await send(connection, Data(repeating: 0x78, count: after))
                return  // close with the body short

            case .echoBody:
                let summary = Data("{\"received\":\(bodyReceived)}".utf8)
                var headers = Self.rateLimitHeaders
                headers.append(("Content-Type", "application/json"))
                guard await send(connection, Self.response(status: 200, headers: headers, body: summary)) else { return }
            }
        }
    }

    // MARK: - Small async plumbing

    private func readUntilHeadEnd(_ connection: NWConnection, buffer: inout Data) async -> Int? {
        while true {
            if let end = Self.headEnd(in: buffer) { return end }
            guard let more = await receive(connection) else { return nil }
            buffer.append(more)
        }
    }

    private func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete || error != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func send(_ connection: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    // MARK: - Tiny HTTP helpers (parser-free on purpose)

    static func headEnd(in buffer: Data) -> Int? {
        guard buffer.count >= 4 else { return nil }
        let bytes = [UInt8](buffer)
        for index in 0...(bytes.count - 4) {
            if bytes[index] == 0x0D, bytes[index + 1] == 0x0A,
               bytes[index + 2] == 0x0D, bytes[index + 3] == 0x0A {
                return index + 4
            }
        }
        return nil
    }

    static func contentLength(inHead head: String) -> Int {
        for line in head.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
            else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    static func serialize(_ headers: [(String, String)]) -> String {
        headers.map { "\($0.0): \($0.1)\r\n" }.joined()
    }

    static func response(status: Int, headers: [(String, String)], body: Data) -> Data {
        var all = headers
        if !headers.contains(where: { $0.0.lowercased() == "content-length" }) {
            all.append(("Content-Length", String(body.count)))
        }
        let head = "HTTP/1.1 \(status) X\r\n" + serialize(all) + "\r\n"
        return Data(head.utf8) + body
    }
}

/// Single-resume guard for NW state handlers, same discipline as the proxy's
/// own `ContinuationBox` (copied as a pattern, not imported — that type is
/// internal to TokeniaProxy, deliberately).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?

    init(_ continuation: CheckedContinuation<UInt16, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<UInt16, Error>) {
        lock.lock()
        let taken = continuation
        continuation = nil
        lock.unlock()
        taken?.resume(with: result)
    }
}

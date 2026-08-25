import Foundation
import Network

/// Keeps track of live client streams so `stop()` can tear them down.
private final class SessionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [ObjectIdentifier: NetworkStream] = [:]
    private var closed = false

    /// Check-and-insert under one lock. Two things live in that atomicity:
    /// the connection cap (a read-then-add on the concurrent accept queue let
    /// simultaneous bursts sail past the limit), and the closed flag (an
    /// accept racing `stop()` used to register a session *after* `cancelAll`,
    /// leaving a stream nothing would ever tear down).
    func admit(_ stream: NetworkStream, limit: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, streams.count < limit else { return false }
        streams[ObjectIdentifier(stream)] = stream
        return true
    }

    func remove(_ stream: NetworkStream) {
        lock.lock()
        streams[ObjectIdentifier(stream)] = nil
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        closed = true
        let live = Array(streams.values)
        streams.removeAll()
        lock.unlock()
        for stream in live { stream.cancel() }
    }

    /// Re-arms a registry that `stop()` closed, so the same server (or a new
    /// one on the same instance) can `start()` again.
    func reopen() {
        lock.lock()
        closed = false
        lock.unlock()
    }
}

/// The transparent local proxy.
///
/// Listens on `127.0.0.1`, answers Claude Code's `HEAD /api/hello` probe itself,
/// and relays everything else to `api.anthropic.com` byte-for-byte while reading
/// the `anthropic-ratelimit-unified-*` headers off the way back.
///
/// Hostable in-process: the menu bar app owns an instance and reads snapshots
/// from `usageSource`. There is no separate executable and no IPC.
public actor ProxyServer {
    public let configuration: ProxyConfiguration
    public let usageSource: ProxyUsageSource

    private let queue = DispatchQueue(label: "com.tokenia.proxy.network", qos: .userInitiated, attributes: .concurrent)
    private let registry = SessionRegistry()
    private var listener: NWListener?
    private var boundPort: UInt16?

    public init(configuration: ProxyConfiguration = ProxyConfiguration(), usageSource: ProxyUsageSource = ProxyUsageSource()) {
        self.configuration = configuration
        self.usageSource = usageSource
    }

    /// The port actually bound. Differs from `configuration.port` only when the
    /// configured port was `0` (let the system choose).
    public var port: UInt16? { boundPort }

    public var isRunning: Bool { listener != nil }

    /// Binds the listener and starts accepting. Returns the bound port.
    @discardableResult
    public func start() async throws -> UInt16 {
        if let boundPort { return boundPort }
        registry.reopen()

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true // SSE frames must not wait on Nagle
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: configuration.port) ?? .any
        )

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            let failure = ProxyFailure.from(error)
            ProxyLog.emit(.listenerFailed(failure))
            throw ProxyError.network(failure)
        }

        let configuration = self.configuration
        let usageSource = self.usageSource
        let registry = self.registry
        let queue = self.queue

        listener.newConnectionHandler = { connection in
            let stream = NetworkStream(
                connection: connection,
                queue: queue,
                maximumReceive: configuration.receiveChunkSize
            )
            // At capacity (or mid-stop): cancel before a byte is read. There
            // is nothing to answer with — an HTTP 503 would mean accepting and
            // parsing, which is the work the cap exists to bound. One atomic
            // check-and-insert, because this handler runs concurrently with
            // itself and with stop().
            guard registry.admit(stream, limit: configuration.maximumConcurrentConnections) else {
                ProxyLog.emit(.clientRejectedAtCapacity)
                connection.cancel()
                return
            }
            Task.detached(priority: .userInitiated) {
                let session = ClientSession(
                    client: stream,
                    configuration: configuration,
                    usageSource: usageSource,
                    queue: queue
                )
                await session.run()
                registry.remove(stream)
            }
        }

        let ready = ListenerReadyBox()
        do {
            let assigned: UInt16 = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
                    ready.attach(continuation)
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            ready.resume(with: .success(listener.port?.rawValue ?? configuration.port))
                        case .failed(let error):
                            ready.resume(with: .failure(ProxyError.network(.from(error))))
                        case .cancelled:
                            ready.resume(with: .failure(ProxyError.cancelled))
                        default:
                            break
                        }
                    }
                    listener.start(queue: queue)
                }
            } onCancel: {
                listener.cancel()
            }

            self.listener = listener
            self.boundPort = assigned
            ProxyLog.emit(.listenerStarted(port: assigned))
            return assigned
        } catch {
            listener.cancel()
            let failure = ProxyFailure.from(error)
            ProxyLog.emit(.listenerFailed(failure))
            throw ProxyError.network(failure)
        }
    }

    /// Stops accepting and tears down every live connection.
    ///
    /// Waits for the listener to actually reach `.cancelled` before returning:
    /// `NWListener.cancel()` is asynchronous, and returning while the socket
    /// was still bound made the documented upgrade dance — stop the old proxy,
    /// rebind its port — fail with `addressInUse` when the two steps ran in
    /// one process. `ProxyServerHardeningTests.fixedPortRebinds` found it and
    /// pins the fix.
    public func stop() async {
        boundPort = nil
        // Listener first, sessions second. The accept handler runs on a
        // concurrent queue, so cancelling sessions while accepts could still
        // land would leave the late arrival running unattended; the registry's
        // closed flag backstops the sliver of handler still in flight.
        if let listener {
            self.listener = nil
            listener.newConnectionHandler = nil
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let done = CancelledBox(continuation)
                listener.stateUpdateHandler = { state in
                    if case .cancelled = state { done.resume() }
                }
                listener.cancel()
            }
        }
        registry.cancelAll()
        // Subscribers' streams end with the server; without this a stopped
        // proxy left every `snapshots` iteration suspended forever.
        usageSource.finish()
        ProxyLog.emit(.listenerStopped)
    }
}

/// Single-resume guard for `stop()`'s wait on `.cancelled`.
private final class CancelledBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let taken = continuation
        continuation = nil
        lock.unlock()
        taken?.resume()
    }
}

/// Same single-resume discipline as `NetworkStream`, for the listener's state handler.
private final class ListenerReadyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    private var pending: Result<UInt16, Error>?
    private var finished = false

    func attach(_ continuation: CheckedContinuation<UInt16, Error>) {
        lock.lock()
        if let pending {
            finished = true
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with result: Result<UInt16, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if let continuation {
            finished = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        pending = result
        lock.unlock()
    }
}

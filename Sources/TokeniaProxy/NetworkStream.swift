import Foundation
import Network

/// A single-shot continuation holder that tolerates the callback racing the setter.
///
/// `NWConnection.stateUpdateHandler` can fire several times; resuming a
/// continuation twice traps, so every resume goes through here.
private final class ContinuationBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pending: Result<Value, Error>?
    private var finished = false

    func attach(_ continuation: CheckedContinuation<Value, Error>) {
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

    func resume(with result: Result<Value, Error>) {
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

/// Async facade over `NWConnection`.
///
/// Reads use `minimumIncompleteLength: 1`, which is what makes SSE work: every
/// byte the peer flushes is handed to us immediately instead of accumulating
/// until a buffer fills. Nothing in this type inspects or stores payload bytes.
final class NetworkStream: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let maximumReceive: Int

    init(connection: NWConnection, queue: DispatchQueue, maximumReceive: Int = 32 * 1024) {
        self.connection = connection
        self.queue = queue
        self.maximumReceive = maximumReceive
    }

    /// Starts the connection and waits until it is ready to carry data.
    func start() async throws {
        let box = ContinuationBox<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.attach(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        box.resume(with: .success(()))
                    case .failed(let error):
                        box.resume(with: .failure(ProxyError.network(.from(error))))
                    case .cancelled:
                        box.resume(with: .failure(ProxyError.cancelled))
                    case .waiting(let error):
                        // `waiting` means "no path right now". Waiting indefinitely
                        // is exactly the hang ARCHITECTURE §3.3 forbids, so surface it.
                        box.resume(with: .failure(ProxyError.network(.from(error))))
                    case .setup, .preparing:
                        break
                    @unknown default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Receives whatever is available, as soon as it is available.
    ///
    /// Returns `nil` once the peer has closed its side.
    func receive() async throws -> Data? {
        let box = ContinuationBox<Data?>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                box.attach(continuation)
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximumReceive) { data, _, isComplete, error in
                    if let error {
                        box.resume(with: .failure(ProxyError.network(.from(error))))
                        return
                    }
                    if let data, !data.isEmpty {
                        box.resume(with: .success(data))
                        return
                    }
                    box.resume(with: isComplete ? .success(nil) : .success(Data()))
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Writes bytes through unchanged. `isComplete` half-closes the stream.
    func send(_ data: Data, isComplete: Bool = false) async throws {
        let box = ContinuationBox<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.attach(continuation)
                connection.send(
                    content: data.isEmpty ? nil : data,
                    contentContext: .defaultMessage,
                    isComplete: isComplete,
                    completion: .contentProcessed { error in
                        if let error {
                            box.resume(with: .failure(ProxyError.network(.from(error))))
                        } else {
                            box.resume(with: .success(()))
                        }
                    }
                )
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}

extension NetworkStream: ByteSource, ByteSink {
    func readMore() async throws -> Data? { try await receive() }
    func write(_ data: Data) async throws { try await send(data) }
}

/// Runs `operation`, throwing `ProxyError.timedOut` if it outlives `duration`.
///
/// Applied per read, not per request: an SSE response may legitimately stay open
/// for minutes, but a stall longer than the client's own `X-Stainless-Timeout`
/// is a dead upstream and must be reported, never waited on forever.
func withProxyTimeout<Value: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw ProxyError.timedOut
        }
        guard let result = try await group.next() else { throw ProxyError.timedOut }
        group.cancelAll()
        return result
    }
}

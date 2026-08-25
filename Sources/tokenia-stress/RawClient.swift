import Foundation
import Network

/// A bare TCP client for driving load. Deliberately not TokeniaProxy's
/// `NetworkStream` (internal there, and a load driver should not share code
/// with the thing it is trying to break).
final class RawClient: @unchecked Sendable {
    private let connection: NWConnection
    private static let queue = DispatchQueue(label: "tokenia.stress.clients", attributes: .concurrent)

    init(port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(
            to: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!),
            using: NWParameters(tls: nil, tcp: tcp)
        )
    }

    func start(connectTimeout: Duration = .seconds(15)) async throws {
        let connection = self.connection
        let watchdog = Task {
            try? await Task.sleep(for: connectTimeout)
            if !Task.isCancelled { connection.cancel() }
        }
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = OnceBox<Void>(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: box.resume(.success(()))
                case .failed(let error): box.resume(.failure(error))
                // .waiting is NWConnection's "refused, I'll retry when the
                // network changes" state. For a loopback load driver that
                // retry never comes and a first draft of this harness hung
                // 500-connection scenarios on it — a backlog overflow RSTs a
                // few SYNs under any real burst. Refused is an answer.
                case .waiting(let error):
                    connection.cancel()
                    box.resume(.failure(error))
                case .cancelled: box.resume(.failure(CancellationError()))
                default: break
                }
            }
            connection.start(queue: Self.queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    /// One read; nil when the peer closed, errored, or this task was
    /// cancelled. Cancellation cancels the connection — an NWConnection whose
    /// receive callback will never fire again must not strand the awaiting
    /// task, which is exactly how the first draft of this harness deadlocked
    /// its own task group.
    func receive() async -> Data? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                let box = ReceiveBox(continuation)
                pendingReceive.set(box)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        box.resume(data)
                    } else if isComplete || error != nil {
                        box.resume(nil)
                    } else {
                        box.resume(Data())
                    }
                }
            }
        } onCancel: {
            connection.cancel()
            pendingReceive.take()?.resume(nil)
        }
    }

    /// Reads until the peer closes; returns total bytes seen. `deadline`
    /// bounds the whole drain — a stream that neither finishes nor closes is
    /// reported as what it saw, never waited on forever.
    func drain(deadline: Duration = .seconds(120)) async -> Int {
        await bounded(by: deadline) { client in
            var total = 0
            while let chunk = await client.receive() {
                if chunk.isEmpty { await Task.yield(); continue }
                total += chunk.count
            }
            return total
        }
    }

    /// Reads until `marker` appears (or close, or deadline); returns bytes seen.
    func drain(until marker: Data, deadline: Duration = .seconds(120)) async -> Int {
        await bounded(by: deadline) { client in
            var total = 0
            var tail = Data()
            while let chunk = await client.receive() {
                if chunk.isEmpty { await Task.yield(); continue }
                total += chunk.count
                tail.append(chunk)
                if tail.count > marker.count * 2 { tail = tail.suffix(marker.count * 2) }
                if tail.range(of: marker) != nil { break }
            }
            return total
        }
    }

    private func bounded(by deadline: Duration, _ body: @escaping @Sendable (RawClient) async -> Int) async -> Int {
        let work = Task { await body(self) }
        let watchdog = Task { [connection] in
            try? await Task.sleep(for: deadline)
            if !Task.isCancelled { connection.cancel() }
        }
        let result = await work.value
        watchdog.cancel()
        return result
    }

    func cancel() {
        connection.cancel()
        pendingReceive.take()?.resume(nil)
    }

    private let pendingReceive = ReceiveSlot()
}

/// Holds at most one in-flight receive continuation so `cancel()` can flush it.
final class ReceiveSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var box: ReceiveBox?

    func set(_ box: ReceiveBox) {
        lock.lock()
        self.box = box
        lock.unlock()
    }

    func take() -> ReceiveBox? {
        lock.lock()
        defer { lock.unlock() }
        let taken = box
        box = nil
        return taken
    }
}

/// Single-resume guard for one receive callback.
final class ReceiveBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?

    init(_ continuation: CheckedContinuation<Data?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Data?) {
        lock.lock()
        let taken = continuation
        continuation = nil
        lock.unlock()
        taken?.resume(returning: value)
    }
}

final class OnceBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        let taken = continuation
        continuation = nil
        lock.unlock()
        taken?.resume(with: result)
    }
}

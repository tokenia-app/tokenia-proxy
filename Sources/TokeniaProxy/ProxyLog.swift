import Foundation
import os

/// Everything this target is allowed to say out loud.
///
/// **Security invariant (ARCHITECTURE §3.1).** A live OAuth token and the full
/// text of the user's Claude conversations pass through this proxy. So logging
/// is not a free-form facility here: `ProxyLogEvent` is a closed enum whose
/// payloads are ports, status codes and `ProxyFailure` cases. There is no case
/// that accepts a `String`, `Data`, `HTTPHeaders` or any other carrier of
/// request content, which makes leaking a body or an `Authorization` header
/// through the logging path a compile error rather than a code-review question.
///
/// Do not add a case with a free-form `String` payload. Do not add a debug flag
/// that bypasses this. `Tests/TokeniaProxyTests/SecurityTests.swift` enforces
/// both, structurally and by scanning this target's source.
public enum ProxyLogEvent: Sendable, Equatable, CustomStringConvertible {
    case listenerStarted(port: UInt16)
    case listenerStopped
    case listenerFailed(ProxyFailure)
    case clientAccepted
    case clientFinished
    case healthCheckServed
    case upstreamConnected
    case upstreamFailed(ProxyFailure)
    case responseObserved(status: Int)
    case snapshotPublished
    case clientError(ProxyFailure)
    case clientRejectedAtCapacity

    public var description: String {
        switch self {
        case .listenerStarted(let port): return "listening on 127.0.0.1:\(port)"
        case .listenerStopped: return "listener stopped"
        case .listenerFailed(let failure): return "listener failed: \(failure.explanation)"
        case .clientAccepted: return "client connected"
        case .clientFinished: return "client disconnected"
        case .healthCheckServed: return "served health check"
        case .upstreamConnected: return "upstream connected"
        case .upstreamFailed(let failure): return "upstream failed: \(failure.explanation)"
        case .responseObserved(let status): return "response status \(status)"
        case .snapshotPublished: return "published usage snapshot"
        case .clientError(let failure): return "client error: \(failure.explanation)"
        case .clientRejectedAtCapacity: return "client rejected: connection cap reached"
        }
    }
}

/// The only logging entry point in this target.
public enum ProxyLog {
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var sink: (@Sendable (ProxyLogEvent) -> Void)?

        func set(_ newValue: (@Sendable (ProxyLogEvent) -> Void)?) {
            lock.lock()
            sink = newValue
            lock.unlock()
        }

        func current() -> (@Sendable (ProxyLogEvent) -> Void)? {
            lock.lock()
            defer { lock.unlock() }
            return sink
        }
    }

    private static let storage = Storage()
    private static let logger = Logger(subsystem: "com.tokenia.proxy", category: "proxy")

    /// Replaces the destination for structured events. Used by tests; also lets
    /// the app surface proxy health in the UI without inventing a second channel.
    public static func setSink(_ sink: (@Sendable (ProxyLogEvent) -> Void)?) {
        storage.set(sink)
    }

    static func emit(_ event: ProxyLogEvent) {
        if let sink = storage.current() {
            sink(event)
            return
        }
        // `description` is derived entirely from the closed enum above, so it is
        // safe to mark public in the unified log.
        logger.info("\(event.description, privacy: .public)")
    }
}

import Foundation
import Network

/// Why a forward failed, in a form that is safe to log.
///
/// Deliberately a closed enum with no associated strings: it is structurally
/// impossible to smuggle a request body or an `Authorization` header into a
/// log line through this type. See `ProxyLog`.
public enum ProxyFailure: String, Sendable, Equatable, CustomStringConvertible {
    case connectionRefused
    case hostUnreachable
    case dnsFailure
    case tlsFailure
    case timedOut
    case connectionClosed
    case malformedMessage
    case headTooLarge
    case invalidFraming
    case cancelled
    case addressInUse
    case other

    public var description: String { rawValue }

    /// Human-readable, still free of any request content.
    public var explanation: String {
        switch self {
        case .connectionRefused: return "connection refused"
        case .hostUnreachable: return "host unreachable"
        case .dnsFailure: return "DNS lookup failed"
        case .tlsFailure: return "TLS handshake failed"
        case .timedOut: return "timed out"
        case .connectionClosed: return "connection closed early"
        case .malformedMessage: return "malformed HTTP message"
        case .headTooLarge: return "HTTP head too large"
        case .invalidFraming: return "invalid message framing"
        case .cancelled: return "cancelled"
        case .addressInUse: return "address already in use"
        case .other: return "unknown network error"
        }
    }

    static func from(_ error: Error) -> ProxyFailure {
        if let proxyError = error as? ProxyError { return proxyError.failure }
        if error is CancellationError { return .cancelled }
        guard let nwError = error as? NWError else { return .other }
        switch nwError {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .connectionRefused
            case .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN: return .hostUnreachable
            case .ETIMEDOUT: return .timedOut
            case .ECANCELED: return .cancelled
            case .EADDRINUSE: return .addressInUse
            case .ECONNRESET, .EPIPE, .ENOTCONN: return .connectionClosed
            default: return .other
            }
        case .dns: return .dnsFailure
        case .tls: return .tlsFailure
        default: return .other
        }
    }
}

/// Internal error type. Carries no request or response content, only a cause.
public enum ProxyError: Error, Sendable, Equatable {
    case malformedHead
    case headTooLarge
    case invalidFraming
    case peerClosed
    case timedOut
    case network(ProxyFailure)
    case cancelled

    var failure: ProxyFailure {
        switch self {
        case .malformedHead: return .malformedMessage
        case .headTooLarge: return .headTooLarge
        case .invalidFraming: return .invalidFraming
        case .peerClosed: return .connectionClosed
        case .timedOut: return .timedOut
        case .network(let failure): return failure
        case .cancelled: return .cancelled
        }
    }
}

import Foundation

/// How the end of a message body is recognised on the wire.
public enum BodyFraming: Sendable, Equatable {
    case none
    case contentLength(Int)
    case chunked
    /// Body runs until the peer closes the connection (HTTP/1.0 style).
    case untilClose

    /// Framing of a request body, per RFC 9112 §6.
    public static func forRequest(_ head: HTTPRequestHead) -> BodyFraming {
        if let transfer = head.headers["Transfer-Encoding"],
           transfer.lowercased().contains("chunked") {
            return .chunked
        }
        if let raw = head.headers["Content-Length"], let length = Int(raw.trimmingCharacters(in: .whitespaces)) {
            return length > 0 ? .contentLength(length) : .none
        }
        // No framing headers on a request means no body, never read-until-close.
        return .none
    }

    /// Framing of a response body. Depends on the request method, which is why
    /// this cannot be derived from the response alone.
    public static func forResponse(_ head: HTTPResponseHead, requestMethod: String) -> BodyFraming {
        let method = requestMethod.uppercased()
        if method == "HEAD" { return .none }
        if (100..<200).contains(head.statusCode) || head.statusCode == 204 || head.statusCode == 304 {
            return .none
        }
        if method == "CONNECT", (200..<300).contains(head.statusCode) { return .none }

        if let transfer = head.headers["Transfer-Encoding"],
           transfer.lowercased().contains("chunked") {
            return .chunked
        }
        if let raw = head.headers["Content-Length"], let length = Int(raw.trimmingCharacters(in: .whitespaces)) {
            return length > 0 ? .contentLength(length) : .none
        }
        return .untilClose
    }
}

/// Walks a `Transfer-Encoding: chunked` stream **without buffering it**.
///
/// The proxy relays chunk bytes verbatim; this scanner exists only to answer
/// "where does this message end?" so the connection can be reused. It never
/// retains payload bytes — only counters and a state.
public struct ChunkedBodyScanner: Sendable {
    private enum State: Equatable {
        case size(accumulated: Int, sawDigits: Bool, inExtension: Bool, sawCR: Bool)
        case data(remaining: Int)
        case dataTrailingCRLF(seen: Int)
        case trailer(lineLength: Int, sawCR: Bool)
        case complete
    }

    private var state: State = .size(accumulated: 0, sawDigits: false, inExtension: false, sawCR: false)

    public init() {}

    public var isComplete: Bool { state == .complete }

    /// Feeds bytes and reports how many of them belong to the current message.
    ///
    /// Any surplus belongs to the next pipelined message and must be pushed back.
    public mutating func consume(_ bytes: some Collection<UInt8>) throws -> Int {
        var consumed = 0
        for byte in bytes {
            if state == .complete { return consumed }
            try step(byte)
            consumed += 1
        }
        return consumed
    }

    private mutating func step(_ byte: UInt8) throws {
        switch state {
        case .size(let accumulated, let sawDigits, let inExtension, let sawCR):
            if sawCR {
                guard byte == 0x0A else { throw ProxyError.invalidFraming }
                guard sawDigits else { throw ProxyError.invalidFraming }
                state = accumulated == 0
                    ? .trailer(lineLength: 0, sawCR: false)
                    : .data(remaining: accumulated)
                return
            }
            switch byte {
            case 0x0D:
                state = .size(accumulated: accumulated, sawDigits: sawDigits, inExtension: inExtension, sawCR: true)
            case 0x0A:
                // Tolerate a bare LF terminator.
                guard sawDigits else { throw ProxyError.invalidFraming }
                state = accumulated == 0
                    ? .trailer(lineLength: 0, sawCR: false)
                    : .data(remaining: accumulated)
            case UInt8(ascii: ";"):
                state = .size(accumulated: accumulated, sawDigits: sawDigits, inExtension: true, sawCR: false)
            default:
                if inExtension { return }
                guard let digit = Self.hexValue(byte) else { throw ProxyError.invalidFraming }
                let (next, overflow) = accumulated.multipliedReportingOverflow(by: 16)
                guard !overflow else { throw ProxyError.invalidFraming }
                state = .size(accumulated: next + digit, sawDigits: true, inExtension: false, sawCR: false)
            }

        case .data(let remaining):
            let left = remaining - 1
            state = left > 0 ? .data(remaining: left) : .dataTrailingCRLF(seen: 0)

        case .dataTrailingCRLF(let seen):
            if seen == 0 {
                if byte == 0x0A {
                    state = .size(accumulated: 0, sawDigits: false, inExtension: false, sawCR: false)
                } else if byte == 0x0D {
                    state = .dataTrailingCRLF(seen: 1)
                } else {
                    throw ProxyError.invalidFraming
                }
            } else {
                guard byte == 0x0A else { throw ProxyError.invalidFraming }
                state = .size(accumulated: 0, sawDigits: false, inExtension: false, sawCR: false)
            }

        case .trailer(let lineLength, let sawCR):
            if sawCR {
                guard byte == 0x0A else { throw ProxyError.invalidFraming }
                state = lineLength == 0 ? .complete : .trailer(lineLength: 0, sawCR: false)
                return
            }
            switch byte {
            case 0x0D:
                state = .trailer(lineLength: lineLength, sawCR: true)
            case 0x0A:
                state = lineLength == 0 ? .complete : .trailer(lineLength: 0, sawCR: false)
            default:
                state = .trailer(lineLength: lineLength + 1, sawCR: false)
            }

        case .complete:
            break
        }
    }

    private static func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return Int(byte - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return Int(byte - UInt8(ascii: "A")) + 10
        default: return nil
        }
    }
}

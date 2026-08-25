import Foundation

/// Decides which headers survive a forward.
///
/// The rule is deliberately narrow: strip hop-by-hop headers, rewrite `Host`,
/// re-derive framing — and pass *everything else* through untouched, including
/// `Authorization`, `anthropic-beta`, `anthropic-version` and, critically,
/// `Accept-Encoding` / `Content-Encoding` (ARCHITECTURE §3.2: the client
/// decompresses, not us).
public enum HeaderPolicy {
    /// Headers that describe a single hop and must not be relayed.
    ///
    /// Exactly the set named in ARCHITECTURE §3.2 plus the `Proxy-*` family.
    /// Nothing else is stripped — every extra name here is a behaviour change
    /// the user did not ask for.
    public static let hopByHopNames: Set<String> = [
        "connection",
        "transfer-encoding",
        "keep-alive",
        "upgrade",
    ]

    public static func isHopByHop(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return hopByHopNames.contains(lowered) || lowered.hasPrefix("proxy-")
    }

    /// Strips hop-by-hop headers, preserving order and original casing.
    public static func stripHopByHop(_ headers: HTTPHeaders) -> HTTPHeaders {
        headers.filtered { !isHopByHop($0.name) }
    }

    /// Headers to send upstream: hop-by-hop removed, `Host` retargeted, framing
    /// re-stated to match how we actually relay the body.
    ///
    /// `Host` must change — the client addressed `127.0.0.1:8787` and
    /// api.anthropic.com routes on `Host`. Content-Length is left exactly as the
    /// client sent it so the body stays byte-identical.
    public static func upstreamHeaders(
        from headers: HTTPHeaders,
        upstreamHost: String,
        framing: BodyFraming
    ) -> HTTPHeaders {
        var result = stripHopByHop(headers)
        result.set(name: "Host", value: upstreamHost)
        result.removeAll(named: "Content-Length")

        switch framing {
        case .contentLength(let length):
            result.append(name: "Content-Length", value: String(length))
        case .chunked:
            result.append(name: "Transfer-Encoding", value: "chunked")
        case .none:
            // Preserve an explicit zero-length body signal for methods that had one.
            if headers["Content-Length"] != nil {
                result.append(name: "Content-Length", value: "0")
            }
        case .untilClose:
            break
        }
        return result
    }

    /// Headers to send back to Claude Code, framed the same way we relay them.
    public static func downstreamHeaders(
        from headers: HTTPHeaders,
        framing: BodyFraming,
        closeAfterResponse: Bool
    ) -> HTTPHeaders {
        var result = stripHopByHop(headers)
        result.removeAll(named: "Content-Length")

        switch framing {
        case .contentLength(let length):
            result.append(name: "Content-Length", value: String(length))
        case .chunked:
            result.append(name: "Transfer-Encoding", value: "chunked")
        case .none:
            if headers["Content-Length"] != nil {
                result.append(name: "Content-Length", value: "0")
            }
        case .untilClose:
            break
        }

        if closeAfterResponse || framing == .untilClose {
            result.set(name: "Connection", value: "close")
        }
        return result
    }
}

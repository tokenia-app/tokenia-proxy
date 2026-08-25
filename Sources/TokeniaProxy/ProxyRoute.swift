import Foundation
import TokeniaCore

/// What the proxy does with an inbound request.
public enum ProxyRoute: Sendable, Equatable {
    /// Answered locally — Claude Code's liveness probe (ARCHITECTURE §2.2).
    case healthCheck
    /// Answered locally — the menu bar app reading the latest snapshot.
    case status
    /// Everything else goes upstream untouched.
    case forward

    public static let healthCheckPath = "/api/hello"

    /// Private to Tokenia. The double underscore and product name keep this
    /// clear of any real Anthropic route, so it can never shadow live traffic.
    public static let statusPath = "/__tokenia/status"

    public static func route(method: String, target: String) -> ProxyRoute {
        let head = HTTPRequestHead(method: method, target: target)
        return route(head)
    }

    public static func route(_ head: HTTPRequestHead) -> ProxyRoute {
        let method = head.method.uppercased()

        // Only HEAD is intercepted. Claude Code probes with HEAD; anything else
        // on the same path is real traffic and must reach Anthropic.
        if method == "HEAD", head.path == healthCheckPath {
            return .healthCheck
        }
        if method == "GET", head.path == statusPath {
            return .status
        }
        return .forward
    }
}

/// Responses the proxy generates itself. Their bodies are our own text — never
/// anything derived from the user's request.
public enum ProxyResponses {
    public static func healthCheck() -> HTTPResponseHead {
        HTTPResponseHead(
            statusCode: 200,
            reasonPhrase: "OK",
            headers: HTTPHeaders([
                ("Content-Length", "0"),
                ("Cache-Control", "no-store"),
            ])
        )
    }

    /// The latest limit snapshot, for the menu bar app.
    ///
    /// Carries only the parsed numbers — utilisation, status and reset times.
    /// Nothing derived from the user's traffic, and never the `Authorization`
    /// header or any body content (ARCHITECTURE §3.1).
    public static func status(
        _ snapshot: UsageSnapshot?,
        requestsSeen: Int = 0,
        lastRequestAt: Date? = nil
    ) -> (head: HTTPResponseHead, body: Data) {
        var payload: [String: Any] = ["available": snapshot != nil]

        // Present whether or not a snapshot is. This pair is what lets the app
        // separate "the proxy has seen no traffic" from "traffic flows but the
        // responses carry no limit headers" — the distinction that was
        // invisible while diagnosing the popover stuck on "Waiting for data".
        payload["requestsSeen"] = requestsSeen
        if let lastRequestAt {
            payload["lastRequestAt"] = lastRequestAt.timeIntervalSince1970
        }

        if let snapshot {
            payload["capturedAt"] = snapshot.capturedAt.timeIntervalSince1970
            if let claim = snapshot.representativeClaim {
                payload["representativeClaim"] = claim
            }
            if let overage = snapshot.overageStatus {
                payload["overageStatus"] = overage
            }
            if let five = snapshot.fiveHour {
                payload["fiveHour"] = encode(five)
            }
            if let seven = snapshot.sevenDay {
                payload["sevenDay"] = encode(seven)
            }
        }

        let body = (try? JSONSerialization.data(withJSONObject: payload))
            ?? Data(#"{"available":false}"#.utf8)

        let head = HTTPResponseHead(
            statusCode: 200,
            reasonPhrase: "OK",
            headers: HTTPHeaders([
                ("Content-Type", "application/json"),
                ("Content-Length", String(body.count)),
                ("Cache-Control", "no-store"),
            ])
        )
        return (head, body)
    }

    private static func encode(_ window: LimitWindow) -> [String: Any] {
        [
            "status": window.status,
            "utilization": window.utilization,
            "resetAt": window.resetAt.timeIntervalSince1970,
        ]
    }

    /// Fail-open error for an unreachable or misbehaving upstream.
    ///
    /// Shaped like an Anthropic API error so Claude Code renders a real message
    /// instead of a JSON parse failure (ARCHITECTURE §3.3, item 2).
    public static func gatewayError(_ failure: ProxyFailure) -> (head: HTTPResponseHead, body: Data) {
        let message = "Tokenia proxy could not reach api.anthropic.com (\(failure.explanation)). "
            + "Claude Code traffic is not being forwarded. Check that you are online, "
            + "or run `make uninstall` to remove ANTHROPIC_BASE_URL and go direct."
        let payload: [String: Any] = [
            "type": "error",
            "error": ["type": "api_error", "message": message],
        ]
        let body = (try? JSONSerialization.data(withJSONObject: payload))
            ?? Data(#"{"type":"error","error":{"type":"api_error","message":"Tokenia proxy: upstream unreachable"}}"#.utf8)

        let status = failure == .timedOut ? 504 : 502
        let head = HTTPResponseHead(
            statusCode: status,
            reasonPhrase: status == 504 ? "Gateway Timeout" : "Bad Gateway",
            headers: HTTPHeaders([
                ("Content-Type", "application/json"),
                ("Content-Length", String(body.count)),
                ("Connection", "close"),
            ])
        )
        return (head, body)
    }

    /// Malformed request from the client side.
    public static func badRequest(_ failure: ProxyFailure) -> (head: HTTPResponseHead, body: Data) {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"Tokenia proxy: malformed HTTP request"}}"#.utf8)
        let head = HTTPResponseHead(
            statusCode: 400,
            reasonPhrase: "Bad Request",
            headers: HTTPHeaders([
                ("Content-Type", "application/json"),
                ("Content-Length", String(body.count)),
                ("Connection", "close"),
            ])
        )
        _ = failure
        return (head, body)
    }
}

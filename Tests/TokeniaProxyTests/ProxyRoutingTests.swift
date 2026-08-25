import Foundation
import Testing
@testable import TokeniaProxy

@Suite("Routing and local responses")
struct ProxyRoutingTests {
    @Test("HEAD /api/hello is answered locally — ARCHITECTURE §2.2")
    func healthCheckIsIntercepted() throws {
        let head = try HTTPHeadParser.parseRequest(head: Data(Fixtures.healthCheckHead.utf8))
        #expect(ProxyRoute.route(head) == .healthCheck)
        #expect(ProxyRoute.route(method: "head", target: "/api/hello") == .healthCheck)
        #expect(ProxyRoute.route(method: "HEAD", target: "/api/hello?ping=1") == .healthCheck)
    }

    @Test("Everything else is forwarded, including GET on the same path")
    func otherRequestsForward() {
        #expect(ProxyRoute.route(method: "GET", target: "/api/hello") == .forward)
        #expect(ProxyRoute.route(method: "POST", target: "/v1/messages?beta=true") == .forward)
        #expect(ProxyRoute.route(method: "HEAD", target: "/v1/messages") == .forward)
        #expect(ProxyRoute.route(method: "HEAD", target: "/api/hello/extra") == .forward)
    }

    @Test("The health check answers 200 with an empty body")
    func healthCheckResponse() throws {
        let head = ProxyResponses.healthCheck()
        #expect(head.statusCode == 200)
        #expect(head.headers["Content-Length"] == "0")

        let wire = String(decoding: head.serialized(), as: UTF8.self)
        #expect(wire.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(wire.hasSuffix("\r\n\r\n"))
    }

    @Test("An unreachable upstream produces a legible Anthropic-shaped error, never a hang")
    func gatewayError() throws {
        let (head, body) = ProxyResponses.gatewayError(.connectionRefused)
        #expect(head.statusCode == 502)
        #expect(head.headers["Content-Type"] == "application/json")
        #expect(head.headers["Content-Length"] == String(body.count))
        #expect(head.headers["Connection"] == "close")

        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        let message = error?["message"] as? String ?? ""
        #expect(json?["type"] as? String == "error")
        #expect(message.contains("api.anthropic.com"))
        #expect(message.contains("connection refused"))
    }

    @Test("A stalled upstream is reported as 504, not 502")
    func timeoutIsGatewayTimeout() {
        #expect(ProxyResponses.gatewayError(.timedOut).head.statusCode == 504)
    }

    @Test("Keep-alive is honoured the way HTTP/1.1 and HTTP/1.0 each define it")
    func keepAliveRules() throws {
        let http11 = try HTTPHeadParser.parseRequest(head: Data(Fixtures.healthCheckHead.utf8))
        #expect(ClientSession.clientWantsKeepAlive(http11))

        let closing = try HTTPHeadParser.parseRequest(
            head: Data("POST /v1/messages HTTP/1.1\r\nConnection: close\r\n\r\n".utf8)
        )
        #expect(!ClientSession.clientWantsKeepAlive(closing))

        let legacy = try HTTPHeadParser.parseRequest(head: Data("GET / HTTP/1.0\r\nHost: x\r\n\r\n".utf8))
        #expect(!ClientSession.clientWantsKeepAlive(legacy))

        let legacyKeepAlive = try HTTPHeadParser.parseRequest(
            head: Data("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n".utf8)
        )
        #expect(ClientSession.clientWantsKeepAlive(legacyKeepAlive))

        let upstreamClosing = try HTTPHeadParser.parseResponse(
            head: Data("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
        )
        #expect(!ClientSession.upstreamWantsKeepAlive(upstreamClosing))
    }
}

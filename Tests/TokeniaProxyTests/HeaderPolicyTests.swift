import Foundation
import Testing
@testable import TokeniaProxy

@Suite("Header policy")
struct HeaderPolicyTests {
    private func realRequest() throws -> HTTPRequestHead {
        try HTTPHeadParser.parseRequest(head: Data(Fixtures.realRequestHead.utf8))
    }

    @Test("Strips exactly the hop-by-hop names and nothing else")
    func hopByHopSet() {
        #expect(HeaderPolicy.isHopByHop("Connection"))
        #expect(HeaderPolicy.isHopByHop("connection"))
        #expect(HeaderPolicy.isHopByHop("Transfer-Encoding"))
        #expect(HeaderPolicy.isHopByHop("Keep-Alive"))
        #expect(HeaderPolicy.isHopByHop("Upgrade"))
        #expect(HeaderPolicy.isHopByHop("Proxy-Connection"))
        #expect(HeaderPolicy.isHopByHop("Proxy-Authorization"))
        #expect(HeaderPolicy.isHopByHop("proxy-anything-at-all"))

        // Everything end-to-end stays.
        for name in [
            "Authorization", "Accept-Encoding", "Content-Encoding", "Content-Length",
            "anthropic-beta", "anthropic-version", "X-Stainless-Timeout", "User-Agent",
            "Content-Type", "Accept", "Cookie", "TE", "Trailer",
        ] {
            #expect(!HeaderPolicy.isHopByHop(name), "\(name) must be forwarded")
        }
    }

    @Test("Authorization is forwarded untouched")
    func authorizationSurvives() throws {
        let head = try realRequest()
        let forwarded = HeaderPolicy.upstreamHeaders(
            from: head.headers,
            upstreamHost: "api.anthropic.com",
            framing: .contentLength(250_414)
        )
        #expect(forwarded["Authorization"] == head.headers["Authorization"])
    }

    @Test("Accept-Encoding is never rewritten — the client decompresses, not us")
    func acceptEncodingUntouched() throws {
        let head = try realRequest()
        let forwarded = HeaderPolicy.upstreamHeaders(
            from: head.headers,
            upstreamHost: "api.anthropic.com",
            framing: .contentLength(250_414)
        )
        #expect(forwarded["Accept-Encoding"] == "gzip, deflate, br, zstd")
        #expect(forwarded.values(for: "Accept-Encoding").count == 1)
    }

    @Test("Host is retargeted to the upstream, Connection is dropped")
    func hostRewritten() throws {
        let head = try realRequest()
        let forwarded = HeaderPolicy.upstreamHeaders(
            from: head.headers,
            upstreamHost: "api.anthropic.com",
            framing: .contentLength(250_414)
        )
        #expect(forwarded["Host"] == "api.anthropic.com")
        #expect(forwarded.values(for: "Host").count == 1)
        #expect(forwarded["Connection"] == nil)
        #expect(forwarded["Content-Length"] == "250414")
    }

    @Test("Chunked requests are re-framed as chunked, never as Content-Length")
    func chunkedRequestFraming() {
        let headers = HTTPHeaders([
            ("Host", "127.0.0.1:8787"),
            ("Transfer-Encoding", "chunked"),
            ("Authorization", "Bearer token"),
        ])
        let forwarded = HeaderPolicy.upstreamHeaders(
            from: headers,
            upstreamHost: "api.anthropic.com",
            framing: .chunked
        )
        #expect(forwarded["Transfer-Encoding"] == "chunked")
        #expect(forwarded["Content-Length"] == nil)
        #expect(forwarded["Authorization"] == "Bearer token")
    }

    @Test("Response headers keep Content-Encoding and every anthropic-ratelimit-* field")
    func responseHeadersPreserved() throws {
        let response = try HTTPHeadParser.parseResponse(head: Data(Fixtures.sseResponseHead().utf8))
        let downstream = HeaderPolicy.downstreamHeaders(
            from: response.headers,
            framing: .chunked,
            closeAfterResponse: false
        )
        #expect(downstream["Content-Type"] == "text/event-stream")
        #expect(downstream["Transfer-Encoding"] == "chunked")
        // Claude Code sees the same limit headers we do; we observe, we don't consume.
        for (name, value) in Fixtures.rateLimitHeaders {
            #expect(downstream[name] == value)
        }
    }

    @Test("Compressed responses are relayed as-is, still compressed")
    func contentEncodingPreserved() {
        let headers = HTTPHeaders([
            ("Content-Encoding", "gzip"),
            ("Content-Length", "1234"),
            ("Connection", "keep-alive"),
        ])
        let downstream = HeaderPolicy.downstreamHeaders(
            from: headers,
            framing: .contentLength(1234),
            closeAfterResponse: false
        )
        #expect(downstream["Content-Encoding"] == "gzip")
        #expect(downstream["Content-Length"] == "1234")
        #expect(downstream["Connection"] == nil)
    }

    @Test("Connection: close is announced when the connection will not be reused")
    func closeAnnounced() {
        let downstream = HeaderPolicy.downstreamHeaders(
            from: HTTPHeaders([("Content-Type", "application/json")]),
            framing: .untilClose,
            closeAfterResponse: true
        )
        #expect(downstream["Connection"] == "close")
    }
}

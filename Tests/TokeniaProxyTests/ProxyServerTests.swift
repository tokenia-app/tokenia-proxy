import Foundation
import Network
import Testing
@testable import TokeniaProxy

/// Exercises the real listener over loopback. No upstream is contacted: the
/// health check is answered locally, which is exactly the path Claude Code hits
/// first (ARCHITECTURE §2.2).
@Suite(.serialized)
struct ProxyServerTests {
    private func connect(to port: UInt16) async throws -> NetworkStream {
        let endpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: try #require(NWEndpoint.Port(rawValue: port))
        )
        let stream = NetworkStream(
            connection: NWConnection(to: endpoint, using: .tcp),
            queue: DispatchQueue(label: "tokenia.tests.client")
        )
        try await stream.start()
        return stream
    }

    @Test("Answers HEAD /api/hello with 200 over a real socket")
    func servesHealthCheck() async throws {
        let server = ProxyServer(configuration: ProxyConfiguration(port: 0, upstreamTimeout: .seconds(5)))
        let port = try await server.start()
        #expect(port != 0)

        let client = try await connect(to: port)
        try await client.send(Data("HEAD /api/hello HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: keep-alive\r\n\r\n".utf8))

        let reader = HTTPStreamReader(source: client, timeout: .seconds(5))
        let response = try HTTPHeadParser.parseResponse(head: try await reader.readHead(maximumSize: 64 * 1024))
        #expect(response.statusCode == 200)
        #expect(response.headers["Content-Length"] == "0")

        // Keep-alive: a second probe on the same socket must also be answered.
        try await client.send(Data("HEAD /api/hello HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8))
        let second = try HTTPHeadParser.parseResponse(head: try await reader.readHead(maximumSize: 64 * 1024))
        #expect(second.statusCode == 200)

        client.cancel()
        await server.stop()
    }

    @Test("Reports the port it bound so the installer can write settings.json")
    func reportsBoundPort() async throws {
        let server = ProxyServer(configuration: ProxyConfiguration(port: 0))
        let port = try await server.start()
        #expect(await server.port == port)
        #expect(await server.isRunning)

        // Starting twice is a no-op rather than a second bind.
        #expect(try await server.start() == port)

        await server.stop()
        #expect(await server.isRunning == false)
    }

    @Test("A garbled request gets a 400 instead of a hung socket")
    func rejectsGarbage() async throws {
        let server = ProxyServer(configuration: ProxyConfiguration(port: 0, upstreamTimeout: .seconds(5)))
        let port = try await server.start()

        let client = try await connect(to: port)
        try await client.send(Data("this is not HTTP\r\nneither is this\r\n\r\n".utf8))

        let reader = HTTPStreamReader(source: client, timeout: .seconds(5))
        let response = try HTTPHeadParser.parseResponse(head: try await reader.readHead(maximumSize: 64 * 1024))
        #expect(response.statusCode == 400)

        client.cancel()
        await server.stop()
    }
}

import Foundation
import Testing
@testable import TokeniaProxy

/// ARCHITECTURE §3.1, rule #1: a live OAuth token and the full text of the
/// user's Claude conversations pass through this proxy. Neither may ever reach
/// disk or a log — not temporarily, not behind a debug flag.
///
/// These tests enforce that two ways: behaviourally (drive the code, inspect
/// everything it emitted) and structurally (scan this target's own source, so a
/// future `print()` fails the build rather than leaking a token).
@Suite("Security — nothing sensitive is ever logged or written")
struct SecurityTests {
    /// Strings that must never appear in anything the proxy emits.
    static let needles = [
        "sk-ant-oat01",
        "Bearer",
        "SECRET-CONVERSATION-TEXT",
        "250414-worth-of-user-prose",
    ]

    private static var proxySourceDirectory: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/TokeniaProxyTests/SecurityTests.swift
            .deletingLastPathComponent()         // …/Tests/TokeniaProxyTests
            .deletingLastPathComponent()         // …/Tests
            .deletingLastPathComponent()         // repo root
            .appendingPathComponent("Sources/TokeniaProxy")
    }

    private static func proxySources() throws -> [(name: String, contents: String)] {
        let files = try FileManager.default.contentsOfDirectory(
            at: proxySourceDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        #expect(files.count >= 8, "source scan found suspiciously few files — check the path")
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// Source with `//` line comments removed, so documentation that *mentions*
    /// a header name is not confused with code that touches one.
    private static func code(_ contents: String) -> String {
        contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    // MARK: - Behavioural

    @Test("Driving a request with a live-looking token emits no trace of it")
    func realisticTrafficLogsNothingSensitive() async throws {
        let captured = LogCapture()
        ProxyLog.setSink { captured.append($0) }
        defer { ProxyLog.setSink(nil) }

        // A request shaped exactly like Claude Code's, secrets included.
        let head = try HTTPHeadParser.parseRequest(head: Data(Fixtures.realRequestHead.utf8))
        let body = Data("""
            {"messages":[{"role":"user","content":"SECRET-CONVERSATION-TEXT and \
            250414-worth-of-user-prose"}]}
            """.utf8)

        // Forward preparation.
        let upstreamHeaders = HeaderPolicy.upstreamHeaders(
            from: head.headers,
            upstreamHost: "api.anthropic.com",
            framing: .contentLength(body.count)
        )
        #expect(upstreamHeaders["Authorization"] != nil, "the token must still be forwarded")

        // Body relay.
        let reader = HTTPStreamReader(source: ScriptedSource([body]), timeout: .seconds(5))
        let sink = RecordingSink()
        try await BodyRelay.relay(framing: .contentLength(body.count), from: reader, to: sink, chunkSize: 32)
        #expect(sink.combined == body)

        // Response observation and snapshot publication.
        let response = try HTTPHeadParser.parseResponse(head: Data(Fixtures.sseResponseHead().utf8))
        let source = ProxyUsageSource()
        ProxyLog.emit(.responseObserved(status: response.statusCode))
        source.ingest(responseHeaders: response.headers)

        // Failure paths, which are the usual place a "just this once" dump appears.
        ProxyLog.emit(.upstreamFailed(.connectionRefused))
        ProxyLog.emit(.clientError(.malformedMessage))

        let transcript = captured.transcript
        #expect(!transcript.isEmpty, "the proxy should still say something useful")
        for needle in Self.needles {
            #expect(!transcript.contains(needle), "log transcript leaked \(needle)")
        }
    }

    @Test("Every log event renders without any request content")
    func everyEventIsSafeToRender() {
        let events: [ProxyLogEvent] = [
            .listenerStarted(port: 8787),
            .listenerStopped,
            .listenerFailed(.addressInUse),
            .clientAccepted,
            .clientFinished,
            .healthCheckServed,
            .upstreamConnected,
            .upstreamFailed(.tlsFailure),
            .responseObserved(status: 200),
            .snapshotPublished,
            .clientError(.malformedMessage),
        ]
        for event in events {
            let rendered = event.description
            #expect(!rendered.isEmpty)
            for needle in Self.needles {
                #expect(!rendered.contains(needle))
            }
        }
    }

    @Test("The published snapshot carries numbers only — no headers, no body")
    func snapshotHoldsOnlyNumbers() throws {
        let source = ProxyUsageSource()
        var headers = try HTTPHeadParser.parseResponse(head: Data(Fixtures.sseResponseHead().utf8)).headers
        headers.append(name: "Set-Cookie", value: "session=SECRET-CONVERSATION-TEXT")

        let snapshot = try #require(source.ingest(responseHeaders: headers))
        let mirrored = String(describing: snapshot)
        for needle in Self.needles {
            #expect(!mirrored.contains(needle))
        }
        #expect(mirrored.contains("0.15"))
    }

    // MARK: - Structural

    @Test("No source file in this target can print, log ad hoc, or touch the filesystem")
    func noForbiddenAPIs() throws {
        // Any of these is a channel through which a body or token could escape.
        let forbidden = [
            "print(",
            "debugPrint(",
            "NSLog(",
            "dump(",
            "os_log(",
            "FileHandle",
            "FileManager",
            "URL(fileURLWithPath",
            ".write(to:",
            "String(contentsOf",
            "UserDefaults",
            "NSKeyedArchiver",
        ]

        for (name, contents) in try Self.proxySources() {
            let body = Self.code(contents)
            for pattern in forbidden {
                #expect(!body.contains(pattern), "\(name) uses \(pattern) — the proxy must not write anywhere")
            }
        }
    }

    @Test("Logging exists in exactly one file, and goes through one closed enum")
    func loggingIsCentralised() throws {
        for (name, contents) in try Self.proxySources() {
            let body = Self.code(contents)
            if name == "ProxyLog.swift" { continue }
            #expect(!body.contains("import os"), "\(name) imports os — logging belongs in ProxyLog.swift")
            #expect(!body.contains("Logger("), "\(name) builds a Logger — logging belongs in ProxyLog.swift")
        }

        let sources = try Self.proxySources()
        let log = try #require(sources.first { $0.name == "ProxyLog.swift" }?.contents)
        let code = Self.code(log)
        // One logger, one call site.
        #expect(code.components(separatedBy: "Logger(").count - 1 == 1)
        #expect(code.components(separatedBy: "logger.").count - 1 == 1)
    }

    @Test("No log event can carry a String, Data or header collection")
    func logEventPayloadsAreClosed() throws {
        let sources = try Self.proxySources()
        let log = try #require(sources.first { $0.name == "ProxyLog.swift" }?.contents)

        // Isolate the ProxyLogEvent case declarations.
        let lines = Self.code(log)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var inEvent = false
        var caseCount = 0
        for line in lines {
            if line.contains("enum ProxyLogEvent") { inEvent = true; continue }
            if inEvent && line.hasPrefix("public var description") { break }
            guard inEvent, line.hasPrefix("case ") else { continue }
            caseCount += 1
            for banned in ["String", "Data", "HTTPHeaders", "[UInt8]", "Any", "HTTPRequestHead", "HTTPResponseHead"] {
                #expect(
                    !line.contains(banned),
                    "ProxyLogEvent.\(line) can carry \(banned) — payloads must stay non-sensitive"
                )
            }
        }
        // Tripwire: adding an event forces a look at this test.
        // 12 = the original 11 plus `clientRejectedAtCapacity` (payloadless,
        // added with the connection cap). Bump this ONLY after re-reading the
        // new case's payload against the structural rules above.
        #expect(caseCount == 12, "ProxyLogEvent gained or lost a case — re-check what it can carry")
    }

    @Test("The proxy never singles out the Authorization header — it just forwards everything")
    func noAuthorizationHandlingInCode() throws {
        for (name, contents) in try Self.proxySources() {
            let body = Self.code(contents)
            #expect(!body.lowercased().contains("authorization"), "\(name) references Authorization in code")
            #expect(!body.contains("Bearer"), "\(name) references Bearer in code")
        }
    }

    @Test("Hop-by-hop stripping leaves Authorization in place")
    func authorizationIsNeverStripped() throws {
        let head = try HTTPHeadParser.parseRequest(head: Data(Fixtures.realRequestHead.utf8))
        let stripped = HeaderPolicy.stripHopByHop(head.headers)
        #expect(stripped["Authorization"] == head.headers["Authorization"])
        #expect(stripped["Connection"] == nil)
    }
}

/// Collects everything the proxy emitted during a test.
final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ProxyLogEvent] = []

    func append(_ event: ProxyLogEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var transcript: String {
        lock.lock()
        defer { lock.unlock() }
        return events.map { "\($0)|\($0.description)" }.joined(separator: "\n")
    }
}

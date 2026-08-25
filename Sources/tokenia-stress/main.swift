import Foundation
import Network
import TokeniaProxy
import TokeniaTestSupport

// tokenia-stress — local stress suite for the proxy. `make stress`.
//
// Boots an in-process ProxyServer (port 0) against a FakeUpstream
// (`upstreamUsesTLS: false`) and drives raw TCP load at it. One line of
// PASS/FAIL per scenario, non-zero exit on any FAIL. Never run in CI: macOS
// runners bill at 10x and these are deliberately minutes-shaped.
//
// Printing lives here, outside Sources/TokeniaProxy, where SecurityTests
// forbids it. Nothing in this target may fabricate or print anything
// token-shaped; the payloads are all "xxxx…".

struct Scenario: Sendable {
    let name: String
    let run: @Sendable () async throws -> String  // returns detail for the PASS line
}

struct StressFailure: Error, CustomStringConvertible {
    let description: String
}

func gigabytes(_ bytes: UInt64) -> String {
    String(format: "%.0f MB", Double(bytes) / 1_048_576)
}

func makeServer(
    upstreamPort: UInt16,
    headTimeout: Duration = .seconds(30),
    maxConnections: Int = 128,
    port: UInt16 = 0
) -> ProxyServer {
    ProxyServer(configuration: ProxyConfiguration(
        port: port,
        upstreamHost: "127.0.0.1",
        upstreamPort: upstreamPort,
        upstreamTimeout: .seconds(660),
        clientHeadCompletionTimeout: headTimeout,
        maximumConcurrentConnections: maxConnections,
        upstreamUsesTLS: false
    ))
}

// MARK: - Scenarios

/// N concurrent SSE streams, all must complete, memory bounded.
func sseScenario(clients: Int, events: Int, eventBytes: Int) async throws -> String {
    let upstream = FakeUpstream(behavior: .sse(
        events: events, eventBytes: eventBytes, interval: .milliseconds(2)
    ))
    let upstreamPort = try await upstream.start()
    defer { upstream.stop() }
    let server = makeServer(upstreamPort: upstreamPort, maxConnections: clients + 16)
    let port = try await server.start()
    defer { Task { await server.stop() } }

    let watch = MemoryWatch(); watch.start()
    let started = ContinuousClock.now
    let terminator = Data("0\r\n\r\n".utf8)

    // Collect, never throw mid-group: a throw would cancel the siblings and
    // turn one short stream into an unreadable pile of cancellations. Count
    // everything, judge at the end.
    let done = await withTaskGroup(of: Int.self) { group in
        for _ in 0..<clients {
            group.addTask {
                let client = RawClient(port: port)
                guard (try? await client.start()) != nil else { return -1 }
                guard (try? await client.send(Data("GET /v1/messages HTTP/1.1\r\nHost: x\r\n\r\n".utf8))) != nil else { return -1 }
                let bytes = await client.drain(until: terminator, deadline: .seconds(120))
                client.cancel()
                return bytes
            }
        }
        var finished = 0
        for await bytes in group where bytes > events * eventBytes {
            finished += 1
        }
        return finished
    }
    let peak = watch.stop()
    let elapsed = ContinuousClock.now - started
    guard done == clients else { throw StressFailure(description: "only \(done)/\(clients) streams completed in full") }
    guard peak < 400 * 1_048_576 else { throw StressFailure(description: "RSS grew \(gigabytes(peak))") }
    return "\(clients) streams × \(events) events in \(elapsed), grew \(gigabytes(peak))"
}

/// N clients dribble half a head and stall. They must be cut off at the head
/// timeout — and a well-behaved client must get through afterwards.
func slowlorisScenario(clients: Int, headTimeout: Duration) async throws -> String {
    let upstream = FakeUpstream(behavior: .fixedResponse(status: 200, headers: [], body: Data()))
    let upstreamPort = try await upstream.start()
    defer { upstream.stop() }
    let server = makeServer(upstreamPort: upstreamPort, headTimeout: headTimeout, maxConnections: clients + 16)
    let port = try await server.start()
    defer { Task { await server.stop() } }

    let watch = MemoryWatch(); watch.start()
    let started = ContinuousClock.now

    enum LorisFate { case cutOff, neverConnected }
    let fates = await withTaskGroup(of: LorisFate.self) { group in
        for _ in 0..<clients {
            group.addTask {
                // Spread the arrivals over a second: the subject is the head
                // timeout, and a synchronized 500-SYN burst mostly measures
                // the kernel's accept backlog instead (it RSTs a crowd,
                // especially with TIME_WAIT left by earlier scenarios).
                try? await Task.sleep(for: .milliseconds(Int.random(in: 0...1000)))
                let client = RawClient(port: port)
                guard (try? await client.start()) != nil else { return .neverConnected }
                guard (try? await client.send(Data("GET / HT".utf8))) != nil else { return .neverConnected }
                // The server must close us; we never send the rest.
                _ = await client.drain(deadline: headTimeout * 3 + .seconds(10))
                client.cancel()
                return .cutOff
            }
        }
        var cutOff = 0
        var neverConnected = 0
        for await fate in group {
            switch fate {
            case .cutOff: cutOff += 1
            case .neverConnected: neverConnected += 1
            }
        }
        return (cutOff, neverConnected)
    }
    let closed = fates.0
    let elapsed = ContinuousClock.now - started
    let peak = watch.stop()

    // A burst of 500 SYNs may overflow the accept backlog and RST a few —
    // that is the kernel's answer, not the proxy's failure. The ones that got
    // in are the ones the timeout must have cut.
    guard fates.1 <= clients / 20 else {
        throw StressFailure(description: "\(fates.1)/\(clients) never connected — accept path is sick")
    }
    guard closed + fates.1 == clients else { throw StressFailure(description: "\(clients - closed - fates.1) loris never got closed") }
    let budget = headTimeout * 3 + .seconds(10)
    guard elapsed < budget else {
        throw StressFailure(description: "cut-off took \(elapsed), budget \(budget) — the 660s window is back")
    }

    // The proxy must still serve a polite client promptly.
    let polite = RawClient(port: port)
    try await polite.start()
    try await polite.send(Data("HEAD /api/hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".utf8))
    guard await polite.drain() > 0 else { throw StressFailure(description: "health check starved after the attack") }
    polite.cancel()
    return "\(clients) loris cut off in \(elapsed), grew \(gigabytes(peak))"
}

/// Few clients, huge bodies, echo upstream: byte counts must match and memory
/// must stay flat — the relay's whole promise is that bodies are never buffered.
func bigBodyScenario(clients: Int, bodyBytes: Int) async throws -> String {
    let upstream = FakeUpstream(behavior: .echoBody)
    let upstreamPort = try await upstream.start()
    defer { upstream.stop() }
    let server = makeServer(upstreamPort: upstreamPort)
    let port = try await server.start()
    defer { Task { await server.stop() } }

    let watch = MemoryWatch(); watch.start()
    let started = ContinuousClock.now
    let expected = Data("{\"received\":\(bodyBytes)}".utf8)

    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<clients {
            group.addTask {
                let client = RawClient(port: port)
                try await client.start()
                let head = "POST /v1/messages HTTP/1.1\r\nHost: x\r\nContent-Length: \(bodyBytes)\r\nConnection: close\r\n\r\n"
                try await client.send(Data(head.utf8))
                // 1 MiB slices so the client itself stays flat too.
                let slice = Data(repeating: 0x78, count: 1_048_576)
                var sent = 0
                while sent < bodyBytes {
                    let take = min(slice.count, bodyBytes - sent)
                    try await client.send(slice.prefix(take))
                    sent += take
                }
                var response = Data()
                while let chunk = await client.receive() { response.append(chunk) }
                client.cancel()
                guard response.range(of: expected) != nil else {
                    throw StressFailure(description: "echo mismatch: got \(String(decoding: response.suffix(80), as: UTF8.self))")
                }
            }
        }
        try await group.waitForAll()
    }
    let peak = watch.stop()
    let elapsed = ContinuousClock.now - started
    // clients × body would be ~512 MB if anything buffered; flat relaying keeps
    // the whole process far under that.
    guard peak < 350 * 1_048_576 else { throw StressFailure(description: "RSS grew \(gigabytes(peak)) — a body is being buffered") }
    return "\(clients) × \(bodyBytes / 1_048_576) MiB echoed in \(elapsed), grew \(gigabytes(peak))"
}

/// Rapid connect → one request → disconnect, in waves.
func churnScenario(connections: Int, parallel: Int) async throws -> String {
    let upstream = FakeUpstream(behavior: .fixedResponse(status: 200, headers: [], body: Data()))
    let upstreamPort = try await upstream.start()
    defer { upstream.stop() }
    let server = makeServer(upstreamPort: upstreamPort)
    let port = try await server.start()
    defer { Task { await server.stop() } }

    let watch = MemoryWatch(); watch.start()
    let started = ContinuousClock.now
    var completed = 0
    var remaining = connections
    while remaining > 0 {
        let wave = min(parallel, remaining)
        remaining -= wave
        let done = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<wave {
                group.addTask {
                    let client = RawClient(port: port)
                    guard (try? await client.start()) != nil else { return false }
                    try? await client.send(Data("HEAD /api/hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".utf8))
                    let bytes = await client.drain()
                    client.cancel()
                    return bytes > 0
                }
            }
            var count = 0
            for await ok in group where ok { count += 1 }
            return count
        }
        completed += done
    }
    let peak = watch.stop()
    let elapsed = ContinuousClock.now - started
    // Allow a small casualty rate from the accept-vs-cancel race under churn,
    // but not a systematic failure.
    guard completed >= connections * 99 / 100 else {
        throw StressFailure(description: "only \(completed)/\(connections) served")
    }
    return "\(completed)/\(connections) served in \(elapsed), grew \(gigabytes(peak))"
}

/// Stop the server under live SSE load; every stream must end promptly and the
/// port must be immediately rebindable.
func stopUnderLoadScenario(clients: Int) async throws -> String {
    let upstream = FakeUpstream(behavior: .sse(events: 100_000, eventBytes: 64, interval: .milliseconds(5)))
    let upstreamPort = try await upstream.start()
    defer { upstream.stop() }
    let server = makeServer(upstreamPort: upstreamPort, maxConnections: clients + 16)
    let port = try await server.start()

    var clientsLive: [RawClient] = []
    for _ in 0..<clients {
        let client = RawClient(port: port)
        try await client.start()
        try await client.send(Data("GET /v1/messages HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        clientsLive.append(client)
    }
    try await Task.sleep(for: .milliseconds(500))

    let started = ContinuousClock.now
    await server.stop()

    for client in clientsLive {
        let drained = Task { await client.drain() }
        let watchdog = Task { try await Task.sleep(for: .seconds(5)); drained.cancel() }
        _ = await drained.value
        watchdog.cancel()
        client.cancel()
    }
    let closed = ContinuousClock.now - started

    let again = makeServer(upstreamPort: upstreamPort, port: port)
    _ = try await again.start()
    await again.stop()
    return "\(clients) live streams torn down in \(closed), port rebound"
}

/// stop → start on the same fixed port, with a real request per cycle.
func rebindScenario(cycles: Int) async throws -> String {
    let upstream = FakeUpstream(behavior: .fixedResponse(status: 200, headers: [], body: Data()))
    let upstreamPort = try await upstream.start()
    defer { upstream.stop() }

    let scout = makeServer(upstreamPort: upstreamPort)
    let port = try await scout.start()
    await scout.stop()

    let started = ContinuousClock.now
    for cycle in 0..<cycles {
        let server = makeServer(upstreamPort: upstreamPort, port: port)
        do {
            _ = try await server.start()
        } catch {
            throw StressFailure(description: "cycle \(cycle): rebind failed: \(error)")
        }
        let client = RawClient(port: port)
        try await client.start()
        try await client.send(Data("HEAD /api/hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".utf8))
        guard await client.drain() > 0 else { throw StressFailure(description: "cycle \(cycle): no answer") }
        client.cancel()
        await server.stop()
    }
    return "\(cycles) stop/start cycles on port \(port) in \(ContinuousClock.now - started)"
}

// MARK: - Dispatch

func value(_ flag: String, default fallback: Int) -> Int {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
          let parsed = Int(arguments[index + 1]) else { return fallback }
    return parsed
}

let scenarios: [Scenario] = [
    Scenario(name: "sse") {
        try await sseScenario(
            clients: value("--clients", default: 200),
            events: value("--events", default: 500),
            eventBytes: value("--bytes", default: 512)
        )
    },
    Scenario(name: "slowloris") {
        try await slowlorisScenario(
            clients: value("--clients", default: 500),
            headTimeout: .seconds(2)
        )
    },
    Scenario(name: "bigbody") {
        try await bigBodyScenario(
            clients: value("--clients", default: 8),
            bodyBytes: value("--size", default: 64 * 1_048_576)
        )
    },
    Scenario(name: "churn") {
        try await churnScenario(
            connections: value("--connections", default: 5000),
            parallel: value("--parallel", default: 64)
        )
    },
    Scenario(name: "stop-under-load") {
        try await stopUnderLoadScenario(clients: value("--clients", default: 64))
    },
    Scenario(name: "rebind") {
        try await rebindScenario(cycles: value("--cycles", default: 50))
    },
]

let requested = CommandLine.arguments.dropFirst().first ?? "all"
let selected = requested == "all" ? scenarios : scenarios.filter { $0.name == requested }
guard !selected.isEmpty else {
    print("unknown scenario \"\(requested)\" — one of: all, \(scenarios.map(\.name).joined(separator: ", "))")
    exit(2)
}

/// Loopback TIME_WAIT sockets left by one scenario can exhaust the ephemeral
/// port range for the next (sse + slowloris together park ~2000 of them, and
/// macOS holds each for 2×MSL = 30s). Claude Code never does this to the
/// proxy; back-to-back scenarios in one process do it to themselves.
func timeWaitCount() -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
    process.arguments = ["-an", "-p", "tcp"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return 0 }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
        .split(separator: "\n")
        .filter { $0.contains("TIME_WAIT") && $0.contains("127.0.0.1") }
        .count
}

func drainTimeWait(below threshold: Int = 500, budget: Duration = .seconds(90)) async {
    let started = ContinuousClock.now
    var waited = false
    while ContinuousClock.now - started < budget {
        let count = timeWaitCount()
        if count < threshold {
            if waited { print("      (waited \(ContinuousClock.now - started) for TIME_WAIT to drain)") }
            return
        }
        waited = true
        try? await Task.sleep(for: .seconds(3))
    }
}

var failed = false
for scenario in selected {
    do {
        // Ten minutes, then the scenario itself is the failure. A stress
        // suite that can hang is worse than one that fails — the first
        // draft of this file proved it twice.
        let detail = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await scenario.run() }
            group.addTask {
                try await Task.sleep(for: .seconds(600))
                throw StressFailure(description: "scenario exceeded 10 minutes")
            }
            guard let first = try await group.next() else {
                throw StressFailure(description: "no result")
            }
            group.cancelAll()
            return first
        }
        print("PASS \(scenario.name): \(detail)")
    } catch {
        print("FAIL \(scenario.name): \(error)")
        failed = true
    }
    // Let lingering TIME_WAIT sockets drain before the next scenario needs
    // the ephemeral ports they are parked on.
    await drainTimeWait()
}
exit(failed ? 1 : 0)

// Trimmed copy of the app's `TokeniaConfig/PortSelector.swift`, kept here so
// the contract tests can pick a free loopback port without pulling in the
// closed-source install machinery. Behaviour is identical.
import Darwin
import Foundation

/// Picks the loopback port the proxy listens on, and Claude Code points at.
///
/// Default 8787 (ARCHITECTURE §1); if something already holds it we scan upward
/// rather than fight over it, and the chosen port is then written into both
/// `settings.json` and the LaunchAgent so the two can never disagree.
public enum PortSelector {
    /// Where the scan starts. In the app this is environment-derived
    /// (`InstallEnvironment`, closed-source); here it is the production
    /// constant, and tests pass an explicit start anyway.
    public static var defaultPort: UInt16 { 8787 }
    public static let defaultScanLimit = 100

    public enum PortError: Error, CustomStringConvertible, Equatable, Sendable {
        case noFreePort(from: UInt16, attempts: Int)

        public var description: String {
            switch self {
            case let .noFreePort(from, attempts):
                return "No free TCP port on 127.0.0.1 in \(attempts) ports from \(from)."
            }
        }
    }

    /// True if we can bind *and* listen on `127.0.0.1:port` right now.
    ///
    /// Deliberately does not set `SO_REUSEADDR`: a port stuck in `TIME_WAIT` is
    /// treated as taken, which is the conservative answer for a listener that
    /// launchd may restart at any moment.
    public static func isPortAvailable(_ port: UInt16) -> Bool {
        guard port > 0 else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian  // 127.0.0.1

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return false }
        return listen(descriptor, 1) == 0
    }

    /// First free port at or above `start`.
    ///
    /// Inherently racy — another process can grab the port between this check and
    /// the proxy binding it. The proxy is the authority; this only picks a sane
    /// starting point, and the LaunchAgent's `KeepAlive` covers a lost race.
    public static func findAvailablePort(
        startingAt start: UInt16 = defaultPort,
        limit: Int = defaultScanLimit
    ) throws -> UInt16 {
        var candidate = UInt32(start)
        var attempts = 0
        while attempts < limit, candidate <= UInt32(UInt16.max) {
            let port = UInt16(candidate)
            if isPortAvailable(port) { return port }
            candidate += 1
            attempts += 1
        }
        throw PortError.noFreePort(from: start, attempts: limit)
    }

    /// The base URL Claude Code is pointed at for a given port.
    public static func baseURL(forPort port: UInt16) -> String {
        "http://127.0.0.1:\(port)"
    }

    /// Extracts the port from a base URL we (or a previous install) wrote.
    public static func port(fromBaseURL text: String) -> UInt16? {
        guard let components = URLComponents(string: text), let port = components.port,
              port > 0, port <= Int(UInt16.max)
        else { return nil }
        return UInt16(port)
    }
}

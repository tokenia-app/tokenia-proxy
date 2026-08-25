import Foundation

// MARK: - Headers

/// One header field, preserving the exact spelling the peer used.
///
/// Order and casing are preserved because this proxy is meant to be invisible:
/// the fewer bytes we normalise, the fewer ways we can change behaviour.
public struct HTTPHeaderField: Sendable, Equatable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    var lowercasedName: String { name.lowercased() }
}

/// An ordered, case-insensitive header collection.
public struct HTTPHeaders: Sendable, Equatable {
    public private(set) var fields: [HTTPHeaderField]

    public init(_ fields: [HTTPHeaderField] = []) {
        self.fields = fields
    }

    public init(_ pairs: [(String, String)]) {
        self.fields = pairs.map { HTTPHeaderField(name: $0.0, value: $0.1) }
    }

    /// First value for `name`, case-insensitively.
    public subscript(name: String) -> String? {
        let wanted = name.lowercased()
        return fields.first { $0.lowercasedName == wanted }?.value
    }

    public func values(for name: String) -> [String] {
        let wanted = name.lowercased()
        return fields.filter { $0.lowercasedName == wanted }.map(\.value)
    }

    public func contains(_ name: String) -> Bool { self[name] != nil }

    public mutating func append(name: String, value: String) {
        fields.append(HTTPHeaderField(name: name, value: value))
    }

    public mutating func removeAll(named name: String) {
        let wanted = name.lowercased()
        fields.removeAll { $0.lowercasedName == wanted }
    }

    public mutating func set(name: String, value: String) {
        removeAll(named: name)
        append(name: name, value: value)
    }

    public func filtered(_ isIncluded: (HTTPHeaderField) -> Bool) -> HTTPHeaders {
        HTTPHeaders(fields.filter(isIncluded))
    }

    /// Flattened form for `RateLimitHeaderParser`, which wants `[String: String]`.
    ///
    /// Only header *names and values* cross this boundary — never a body.
    public var dictionary: [String: String] {
        Dictionary(fields.map { ($0.lowercasedName, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    var serialized: String {
        fields.map { "\($0.name): \($0.value)\r\n" }.joined()
    }
}

// MARK: - Heads

public struct HTTPRequestHead: Sendable, Equatable {
    public let method: String
    /// Request target exactly as sent, query string included.
    public let target: String
    public let version: String
    public var headers: HTTPHeaders

    public init(method: String, target: String, version: String = "HTTP/1.1", headers: HTTPHeaders = .init()) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
    }

    /// Path with the query string removed — used only for health-check routing.
    public var path: String {
        if let cut = target.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            return String(target[target.startIndex..<cut])
        }
        return target
    }

    public func serialized() -> Data {
        Data("\(method) \(target) \(version)\r\n\(headers.serialized)\r\n".utf8)
    }
}

public struct HTTPResponseHead: Sendable, Equatable {
    public let version: String
    public let statusCode: Int
    public let reasonPhrase: String
    public var headers: HTTPHeaders

    public init(version: String = "HTTP/1.1", statusCode: Int, reasonPhrase: String, headers: HTTPHeaders = .init()) {
        self.version = version
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
    }

    public func serialized() -> Data {
        let status = reasonPhrase.isEmpty
            ? "\(version) \(statusCode)\r\n"
            : "\(version) \(statusCode) \(reasonPhrase)\r\n"
        return Data("\(status)\(headers.serialized)\r\n".utf8)
    }
}

// MARK: - Parsing

/// Parses HTTP/1.1 message heads. Bodies never pass through here.
public enum HTTPHeadParser {
    /// Byte offset just past the `CRLFCRLF` (or `LFLF`) that ends the head, or `nil`.
    ///
    /// `from` lets an incremental caller resume where the last scan stopped
    /// (`HTTPStreamReader.readHead` passes its cursor); the offset is relative
    /// to the start of `buffer` regardless of the buffer's own indices. Scans
    /// in place — the `[UInt8](buffer)` copy this used to make was paid per
    /// fill, which multiplied out to O(n²) bytes touched on a deliberately
    /// fragmented head.
    public static func endOfHead(in buffer: Data, from start: Int = 0) -> Int? {
        let count = buffer.count
        guard count >= 2 else { return nil }
        return buffer.withUnsafeBytes { raw -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = max(0, start)
            while index + 1 < count {
                if bytes[index] == 0x0A, bytes[index + 1] == 0x0A {
                    return index + 2 // bare LFLF, tolerated
                }
                if index + 3 < count,
                   bytes[index] == 0x0D, bytes[index + 1] == 0x0A,
                   bytes[index + 2] == 0x0D, bytes[index + 3] == 0x0A {
                    return index + 4
                }
                index += 1
            }
            return nil
        }
    }

    public static func parseRequest(head: Data) throws -> HTTPRequestHead {
        let (startLine, headers) = try split(head: head)
        let parts = startLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3 else { throw ProxyError.malformedHead }
        return HTTPRequestHead(
            method: parts[0],
            target: parts[1],
            version: parts[2],
            headers: headers
        )
    }

    public static func parseResponse(head: Data) throws -> HTTPResponseHead {
        let (startLine, headers) = try split(head: head)
        // "HTTP/1.1 200 OK" — the reason phrase is optional and may contain spaces.
        let parts = startLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let status = Int(parts[1]) else { throw ProxyError.malformedHead }
        return HTTPResponseHead(
            version: parts[0],
            statusCode: status,
            reasonPhrase: parts.count > 2 ? parts[2] : "",
            headers: headers
        )
    }

    private static func split(head: Data) throws -> (startLine: String, headers: HTTPHeaders) {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else {
            throw ProxyError.malformedHead
        }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        // Drop the empty terminator line(s).
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        guard let startLine = lines.first, !startLine.isEmpty else { throw ProxyError.malformedHead }

        var headers = HTTPHeaders()
        for raw in lines.dropFirst() {
            if raw.first == " " || raw.first == "\t" {
                // Obsolete line folding. Append to the previous value rather than dropping it.
                guard let previous = headers.fields.last else { throw ProxyError.malformedHead }
                var fields = headers.fields
                fields.removeLast()
                fields.append(
                    HTTPHeaderField(
                        name: previous.name,
                        value: previous.value + " " + raw.trimmingCharacters(in: .whitespaces)
                    )
                )
                headers = HTTPHeaders(fields)
                continue
            }
            guard let colon = raw.firstIndex(of: ":") else { throw ProxyError.malformedHead }
            let name = String(raw[raw.startIndex..<colon])
            let value = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw ProxyError.malformedHead }
            headers.append(name: name, value: value)
        }
        return (String(startLine), headers)
    }
}

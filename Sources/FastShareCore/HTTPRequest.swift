import Foundation

/// Request line and header fields of an HTTP/1.x request.
public struct HTTPRequestHead: Sendable, Equatable {
    public var method: String
    public var target: String
    public var version: String
    /// Values keyed by lowercased field name; repeated fields are joined with ", ".
    public var headers: [String: String]

    public init(method: String, target: String, version: String, headers: [String: String]) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// Percent-decoded path without query or fragment. Accepts absolute-form targets too.
    public var path: String {
        var raw = Substring(target)
        if let scheme = raw.range(of: "://"), raw[..<scheme.lowerBound].allSatisfy(\.isLetter) {
            let authorityAndPath = raw[scheme.upperBound...]
            raw = authorityAndPath.firstIndex(of: "/").map { authorityAndPath[$0...] } ?? "/"
        }
        if let end = raw.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            raw = raw[..<end]
        }
        return raw.removingPercentEncoding ?? String(raw)
    }

    /// HTTP/1.1 connections persist unless the client says `close`; HTTP/1.0 ones only on request.
    public var wantsKeepAlive: Bool {
        let options = (header("connection") ?? "")
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if version == "HTTP/1.0" { return options.contains("keep-alive") }
        return !options.contains("close")
    }

    /// Whether a body follows the head. The server never reads bodies, so it closes such connections.
    public var hasBody: Bool {
        if header("transfer-encoding") != nil { return true }
        guard let length = header("content-length") else { return false }
        return length.trimmingCharacters(in: .whitespaces) != "0"
    }
}

public enum HTTPRequestParser {
    public static let maxHeadSize = 16 * 1024

    public enum Result: Sendable, Equatable {
        case incomplete
        /// `consumed` counts the bytes of this head, including the blank line that ends it.
        case complete(HTTPRequestHead, consumed: Int)
        case malformed
        case headTooLarge
    }

    public static func parse(_ bytes: [UInt8]) -> Result {
        // RFC 9112 §2.2: ignore empty lines received before the request line.
        var start = 0
        while start + 1 < bytes.count, bytes[start] == 0x0D, bytes[start + 1] == 0x0A {
            start += 2
        }
        guard let end = endOfHead(in: bytes, from: start) else {
            return bytes.count - start > maxHeadSize ? .headTooLarge : .incomplete
        }
        guard end - start <= maxHeadSize else { return .headTooLarge }
        guard let head = parseHead(String(decoding: bytes[start..<end], as: UTF8.self)) else {
            return .malformed
        }
        return .complete(head, consumed: end + 4)
    }

    /// Index of the CRLFCRLF that terminates the head.
    private static func endOfHead(in bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index + 3 < bytes.count {
            if bytes[index] == 0x0D, bytes[index + 1] == 0x0A, bytes[index + 2] == 0x0D, bytes[index + 3] == 0x0A {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func parseHead(_ text: String) -> HTTPRequestHead? {
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3 else { return nil }
        let method = String(requestLine[0])
        let target = String(requestLine[1])
        let version = String(requestLine[2])
        guard !method.isEmpty, method.allSatisfy({ $0.isASCII && $0.isUppercase }),
              !target.isEmpty,
              version == "HTTP/1.1" || version == "HTTP/1.0"
        else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon]
            // Whitespace in a field name also rejects obsolete line folding.
            guard !name.isEmpty, !name.contains(where: \.isWhitespace) else { return nil }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let key = name.lowercased()
            headers[key] = headers[key].map { "\($0), \(value)" } ?? value
        }
        return HTTPRequestHead(method: method, target: target, version: version, headers: headers)
    }
}

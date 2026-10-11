import Testing
@testable import FastShareCore

struct HTTPRequestParserTests {
    @Test func waitsForBlankLineThatEndsHead() {
        #expect(HTTPRequestParser.parse(Array("GET / HTTP/1.1\r\nHost: phone\r\n".utf8)) == .incomplete)
    }

    @Test func consumesOnlyFirstOfPipelinedRequests() throws {
        let first = "GET /abc?x=1 HTTP/1.1\r\nHost: phone\r\nRange: bytes=0-1\r\n\r\n"
        let second = "GET /next HTTP/1.1\r\n\r\n"
        guard case .complete(let head, let consumed) = HTTPRequestParser.parse(Array((first + second).utf8)) else {
            Issue.record("expected a complete head")
            return
        }
        #expect(consumed == first.utf8.count)
        #expect(head.method == "GET")
        #expect(head.path == "/abc")
        #expect(head.header("RANGE") == "bytes=0-1")
    }

    @Test func skipsEmptyLinesBeforeRequestLine() {
        let raw = "\r\n\r\nGET / HTTP/1.1\r\n\r\n"
        guard case .complete(_, let consumed) = HTTPRequestParser.parse(Array(raw.utf8)) else {
            Issue.record("expected a complete head")
            return
        }
        #expect(consumed == raw.utf8.count)
    }

    @Test(arguments: [
        ("/caf%C3%A9/x", "/café/x"),
        ("/k7m2xq9fha/download?source=qr#top", "/k7m2xq9fha/download"),
        ("http://192.168.1.20:8642/k7m2xq9fha", "/k7m2xq9fha"),
        ("http://192.168.1.20:8642", "/"),
    ])
    func extractsDecodedPath(target: String, path: String) {
        #expect(HTTPRequestHead(method: "GET", target: target, version: "HTTP/1.1", headers: [:]).path == path)
    }

    @Test(arguments: [
        ("HTTP/1.1", "", true),
        ("HTTP/1.1", "close", false),
        ("HTTP/1.1", "Keep-Alive, Close", false),
        ("HTTP/1.0", "", false),
        ("HTTP/1.0", "keep-alive", true),
    ])
    func keepAliveFollowsVersionDefaults(version: String, connection: String, expected: Bool) {
        let headers = connection.isEmpty ? [:] : ["connection": connection]
        #expect(HTTPRequestHead(method: "GET", target: "/", version: version, headers: headers).wantsKeepAlive == expected)
    }

    @Test(arguments: [
        "GARBAGE\r\n\r\n",
        "GET /\r\n\r\n",
        "get / HTTP/1.1\r\n\r\n",
        "GET / HTTP/2\r\n\r\n",
        "GET / HTTP/1.1\r\nNo colon here\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\n folded: value\r\n\r\n",
    ])
    func rejectsMalformedHead(raw: String) {
        #expect(HTTPRequestParser.parse(Array(raw.utf8)) == .malformed)
    }

    @Test func rejectsOversizedHeadBeforeItEnds() {
        let raw = "GET / HTTP/1.1\r\nX-Padding: " + String(repeating: "a", count: HTTPRequestParser.maxHeadSize)
        #expect(HTTPRequestParser.parse(Array(raw.utf8)) == .headTooLarge)
    }
}

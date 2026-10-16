import Darwin
import Foundation
import os
import Testing
@testable import FastShareCore

/// Drives the server over real sockets with URLSession, the way a phone's browser would.
struct HTTPServerTests {
    @Test func downloadsExactBytesAndCountsEachCompleteDownload() async throws {
        let fixture = try await ServerFixture.start()
        defer { fixture.stop() }
        var contents = Data(count: 2_500_000) // several 1 MB chunks
        contents.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let token = try fixture.share(named: "photos.zip", contents: contents)

        let (data, response) = try await fixture.request("/\(token)/download")

        #expect(response.statusCode == 200)
        #expect(data == contents)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "application/zip")
        #expect(response.value(forHTTPHeaderField: "Content-Disposition")?.hasPrefix("attachment;") == true)
        try await fixture.waitUntil("a completed download") { $0.contains(.downloadCompleted(token: token)) }

        _ = try await fixture.request("/\(token)/download")
        try await fixture.waitUntil("a second completed download") {
            $0.filter { $0 == .downloadCompleted(token: token) }.count == 2
        }
    }

    /// Chrome on Android splits a download over three connections at once: a plain GET it abandons
    /// on reaching the second third of the file, plus range requests for the other two thirds.
    @Test func phoneSplittingDownloadAcrossConnectionsIsOneDeviceAndOneDownload() async throws {
        let fixture = try await ServerFixture.start()
        defer { fixture.stop() }
        let size = 48 << 20
        let slice = size / 3
        let token = try fixture.share(named: "Vibes.apk", size: size)
        let connections = try (0..<3).map { _ in try RawHTTPClient(host: "127.0.0.1", port: fixture.port) }

        #expect(try connections[0].get("/\(token)/download") == 200)
        #expect(try connections[1].get("/\(token)/download", range: "bytes=\(slice)-") == 206)
        #expect(try connections[2].get("/\(token)/download", range: "bytes=\(2 * slice)-") == 206)
        #expect(fixture.deviceCounts(for: token) == [1]) // All three transfers are under way.

        try connections[0].readBody(slice)
        connections[0].close()
        try connections[1].readBody(slice)
        connections[1].close()
        try connections[2].readBody(size - 2 * slice)
        try await fixture.waitUntil("the transfers to end") { $0.last == .devicesChanged(token: token, count: 0) }
        #expect(fixture.events.filter { $0 == .downloadCompleted(token: token) }.count == 1)
    }

    @Test func devicesCountSeparatelyAndAbandonedDownloadsDontCount() async throws {
        let fixture = try await ServerFixture.start()
        defer { fixture.stop() }
        let token = try fixture.share(named: "clip.mov", size: 64 << 20)
        // IPv4 and IPv6 loopback reach the server from two different addresses, like two devices.
        let phone = try RawHTTPClient(host: "127.0.0.1", port: fixture.port)
        let laptop = try RawHTTPClient(host: "::1", port: fixture.port)

        #expect(try phone.get("/\(token)/download") == 200)
        #expect(try laptop.get("/\(token)/download") == 200)
        #expect(fixture.deviceCounts(for: token) == [1, 2])

        phone.close()
        laptop.close()
        try await fixture.waitUntil("the transfers to end") { $0.last == .devicesChanged(token: token, count: 0) }
        #expect(!fixture.events.contains(.downloadCompleted(token: token)))
    }

    @Test func servesSingleByteRanges() async throws {
        let fixture = try await ServerFixture.start()
        defer { fixture.stop() }
        let contents = Data((0..<1000).map { UInt8(truncatingIfNeeded: $0) })
        let token = try fixture.share(named: "clip.mp4", contents: contents)

        let (partial, partialResponse) = try await fixture.request("/\(token)/view", headers: ["Range": "bytes=100-199"])
        #expect(partialResponse.statusCode == 206)
        #expect(partial == contents.subdata(in: 100..<200))
        #expect(partialResponse.value(forHTTPHeaderField: "Content-Range") == "bytes 100-199/1000")

        let (_, unsatisfiable) = try await fixture.request("/\(token)/view", headers: ["Range": "bytes=1000-"])
        #expect(unsatisfiable.statusCode == 416)
        #expect(unsatisfiable.value(forHTTPHeaderField: "Content-Range") == "bytes */1000")

        let etag = try #require(partialResponse.value(forHTTPHeaderField: "ETag"))
        let (resumed, resumedResponse) = try await fixture.request(
            "/\(token)/view", headers: ["Range": "bytes=900-", "If-Range": etag])
        #expect(resumedResponse.statusCode == 206)
        #expect(resumed == contents.subdata(in: 900..<1000))

        let (whole, staleResponse) = try await fixture.request(
            "/\(token)/view", headers: ["Range": "bytes=100-199", "If-Range": "\"stale\""])
        #expect(staleResponse.statusCode == 200)
        #expect(whole == contents)
        // The partial responses leave gaps, so only the full response completes a download.
        try await fixture.waitUntil("the transfers to end") { $0.last == .devicesChanged(token: token, count: 0) }
        #expect(fixture.events.filter { $0 == .downloadCompleted(token: token) }.count == 1)
    }

    @Test func blocksInactiveUnknownAndMissingLinks() async throws {
        let fixture = try await ServerFixture.start()
        defer { fixture.stop() }
        let token = try fixture.share(named: "notes.pdf", contents: Data("pdf".utf8))

        fixture.setActive(false, token: token)
        let (inactivePage, inactive) = try await fixture.request("/\(token)")
        #expect(inactive.statusCode == 403)
        #expect(String(decoding: inactivePage, as: UTF8.self).contains("This link is turned off"))
        #expect(try await fixture.request("/\(token)/download").1.statusCode == 403)

        fixture.setActive(true, token: token)
        #expect(try await fixture.request("/\(token)").1.statusCode == 200)

        #expect(try await fixture.request("/\(ShareToken.generate())").1.statusCode == 404)
        #expect(try await fixture.request("/not-a-token").1.statusCode == 404)

        let missing = try fixture.share(named: "gone.txt", contents: Data("bye".utf8))
        try FileManager.default.removeItem(at: fixture.directory.appending(path: "gone.txt"))
        #expect(try await fixture.request("/\(missing)/download").1.statusCode == 410)
    }

    @Test func escapesFileNameInPageAndEncodesItInHeader() async throws {
        let fixture = try await ServerFixture.start()
        defer { fixture.stop() }
        let token = try fixture.share(named: "Café \"menu\" <draft>.txt", contents: Data("hello".utf8))

        let (html, landing) = try await fixture.request("/\(token)")
        let page = String(decoding: html, as: UTF8.self)
        #expect(landing.statusCode == 200)
        #expect(page.contains("<h1>Café &quot;menu&quot; &lt;draft&gt;.txt</h1>"))
        #expect(!page.contains("<draft>"))

        let (_, download) = try await fixture.request("/\(token)/download")
        #expect(download.value(forHTTPHeaderField: "Content-Disposition")
            == "attachment; filename=\"Caf_ _menu_ <draft>.txt\"; filename*=UTF-8''Caf%C3%A9%20%22menu%22%20%3Cdraft%3E.txt")
    }

    @Test func headRequestSendsHeadersOnly() async throws {
        let fixture = try await ServerFixture.start()
        defer { fixture.stop() }
        let token = try fixture.share(named: "song.mp3", contents: Data(count: 1000))

        let (body, response) = try await fixture.request("/\(token)/download", method: "HEAD")

        #expect(response.statusCode == 200)
        #expect(body.isEmpty)
        #expect(response.value(forHTTPHeaderField: "Content-Length") == "1000")
        #expect(fixture.events.isEmpty)
    }

    @Test func fallsBackToNextPortWhenPreferredOneIsTaken() async throws {
        let blocker = try PortBlocker()
        let fixture = try await ServerFixture.start(ports: [blocker.port, 0])
        defer { fixture.stop() }

        #expect(fixture.port != blocker.port)
        #expect(try await fixture.request("/").1.statusCode == 200)
    }
}

// MARK: - Fixtures

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
}

private final class ServerFixture {
    let port: UInt16
    let directory: URL
    private let server: HTTPServer
    private let registry: ShareRegistry
    private let files = OSAllocatedUnfairLock<[ServedFile]>(initialState: [])
    private let recordedEvents: OSAllocatedUnfairLock<[HTTPServer.Event]>
    private let session = URLSession(configuration: .ephemeral)

    var events: [HTTPServer.Event] { recordedEvents.withLock { $0 } }

    private init(port: UInt16, server: HTTPServer, registry: ShareRegistry, events: OSAllocatedUnfairLock<[HTTPServer.Event]>) throws {
        self.port = port
        self.server = server
        self.registry = registry
        recordedEvents = events
        directory = FileManager.default.temporaryDirectory.appending(path: "FastShareTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func start(ports: [UInt16] = [0]) async throws -> ServerFixture {
        let registry = ShareRegistry()
        let events = OSAllocatedUnfairLock<[HTTPServer.Event]>(initialState: [])
        let (states, continuation) = AsyncStream.makeStream(of: HTTPServer.State.self)
        let server = HTTPServer(
            registry: registry,
            senderName: "Test Mac",
            onStateChange: { continuation.yield($0) },
            onEvent: { event in events.withLock { $0.append(event) } }
        )
        server.start(ports: ports)
        for await state in states {
            switch state {
            case .starting: continue
            case .running(let port): return try ServerFixture(port: port, server: server, registry: registry, events: events)
            case .failed(let message): throw FixtureError(description: message)
            }
        }
        throw FixtureError(description: "server never started")
    }

    func stop() {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func share(named name: String, contents: Data) throws -> String {
        let url = directory.appending(path: name)
        try contents.write(to: url)
        return register(url)
    }

    /// Shares `size` zero bytes without writing them: a file big enough that transfers stay under
    /// way while a test holds connections open without reading.
    func share(named name: String, size: Int) throws -> String {
        let url = directory.appending(path: name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw FixtureError(description: "couldn't create \(name)")
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        return register(url)
    }

    private func register(_ url: URL) -> String {
        let token = ShareToken.generate()
        update { $0.append(ServedFile(token: token, fileURL: url, isActive: true)) }
        return token
    }

    /// Every device count the server reported for `token`, in order.
    func deviceCounts(for token: String) -> [Int] {
        events.compactMap { event in
            guard case .devicesChanged(let eventToken, let count) = event, eventToken == token else { return nil }
            return count
        }
    }

    func setActive(_ isActive: Bool, token: String) {
        update { files in
            for index in files.indices where files[index].token == token {
                files[index].isActive = isActive
            }
        }
    }

    private func update(_ change: @Sendable (inout [ServedFile]) -> Void) {
        let snapshot = files.withLock { files in
            change(&files)
            return files
        }
        registry.replaceAll(with: snapshot)
    }

    func request(_ path: String, method: String = "GET", headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: request)
        return (data, try #require(response as? HTTPURLResponse))
    }

    /// Some events follow the last byte being handed to the network, a moment after the client read it.
    func waitUntil(_ description: String, timeout: Duration = .seconds(3),
                   _ condition: ([HTTPServer.Event]) -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(events) {
            guard ContinuousClock.now < deadline else { throw FixtureError(description: "no \(description) within \(timeout)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Holds a listening TCP port with a plain BSD socket, like another app would.
private final class PortBlocker {
    let port: UInt16
    private let descriptor: Int32

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        self.descriptor = descriptor
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, length) == 0
                    && listen(descriptor, 8) == 0
                    && getsockname(descriptor, socketAddress, &length) == 0
            }
        }
        guard bound else {
            Darwin.close(descriptor)
            throw FixtureError(description: "couldn't hold a port: errno \(errno)")
        }
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit {
        Darwin.close(descriptor)
    }
}

/// A bare HTTP client on a blocking socket, so a test decides exactly how much of a response to read
/// and when to hang up, like a browser abandoning one slice of a split download.
private final class RawHTTPClient {
    private var descriptor: Int32
    private var buffered: [UInt8] = []

    init(host: String, port: UInt16) throws {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_socktype = SOCK_STREAM
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &addresses) == 0, let address = addresses else {
            throw FixtureError(description: "couldn't resolve \(host)")
        }
        defer { freeaddrinfo(addresses) }
        descriptor = socket(address.pointee.ai_family, SOCK_STREAM, 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0) // A stalled server fails the test instead of hanging it.
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard connect(descriptor, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 else {
            let error = errno
            close()
            throw FixtureError(description: "couldn't connect to \(host): errno \(error)")
        }
    }

    deinit {
        close()
    }

    /// Sends a GET and reads the response head, returning the status code.
    func get(_ path: String, range: String? = nil) throws -> Int {
        var request = "GET \(path) HTTP/1.1\r\nHost: test\r\n"
        if let range { request += "Range: \(range)\r\n" }
        let bytes = Array((request + "\r\n").utf8)
        guard Darwin.send(descriptor, bytes, bytes.count, 0) == bytes.count else {
            throw FixtureError(description: "send failed: errno \(errno)")
        }
        let blankLine = Array("\r\n\r\n".utf8)
        while true {
            if let end = buffered.firstRange(of: blankLine) {
                let statusLine = String(decoding: buffered[..<end.lowerBound], as: UTF8.self).prefix { $0 != "\r" }
                buffered.removeSubrange(..<end.upperBound)
                guard let status = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
                    throw FixtureError(description: "bad status line: \(statusLine)")
                }
                return status
            }
            try receive()
        }
    }

    func readBody(_ count: Int) throws {
        var remaining = count
        while remaining > 0 {
            if buffered.isEmpty { try receive() }
            let taken = min(remaining, buffered.count)
            buffered.removeFirst(taken)
            remaining -= taken
        }
    }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    private func receive() throws {
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        let count = recv(descriptor, &chunk, chunk.count, 0)
        guard count > 0 else {
            throw FixtureError(description: count == 0 ? "server closed the connection" : "recv failed: errno \(errno)")
        }
        buffered.append(contentsOf: chunk[..<count])
    }
}

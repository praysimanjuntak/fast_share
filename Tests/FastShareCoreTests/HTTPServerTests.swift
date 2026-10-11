import Darwin
import Foundation
import os
import Testing
@testable import FastShareCore

/// Drives the server over real sockets with URLSession, the way a phone's browser would.
struct HTTPServerTests {
    @Test func downloadsExactBytesAndCountsCompletedDownload() async throws {
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
        try await fixture.waitUntil("a completed download") { $0.contains(.transferFinished(token: token, completedFile: true)) }
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
        // Only the full 200 response counts as a download; partial responses don't.
        try await fixture.waitUntil("all transfers finished") { events in
            events.filter { $0 == .transferFinished(token: token, completedFile: false) }.count == 2
                && events.contains(.transferFinished(token: token, completedFile: true))
        }
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
        let token = ShareToken.generate()
        update { $0.append(ServedFile(token: token, fileURL: url, isActive: true)) }
        return token
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

    /// The server reports a transfer once the last byte is handed to the network, which can be a
    /// moment after the client has read it.
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

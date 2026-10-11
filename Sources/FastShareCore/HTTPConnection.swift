import Foundation
import Network

/// URL layout of a share link: `/<token>` is the landing page, `/<token>/download` and
/// `/<token>/view` stream the file as an attachment or inline.
enum ShareRoute: Equatable {
    enum Disposition: String {
        case attachment
        case inline
    }

    case home
    case landing(token: String)
    case file(token: String, Disposition)
    case notFound

    init(path: String) {
        let parts = path.split(separator: "/")
        guard let first = parts.first else {
            self = .home
            return
        }
        guard ShareToken.isWellFormed(first) else {
            self = .notFound
            return
        }
        let token = String(first)
        switch parts.count {
        case 1: self = .landing(token: token)
        case 2 where parts[1] == "download": self = .file(token: token, .attachment)
        case 2 where parts[1] == "view": self = .file(token: token, .inline)
        default: self = .notFound
        }
    }
}

/// An open shared file plus the metadata a response needs.
struct OpenedFile {
    let handle: FileHandle
    let name: String
    let size: UInt64
    let etag: String
    let mimeType: String

    /// Nil when the path no longer leads to a readable regular file.
    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        self.handle = handle
        name = url.lastPathComponent.precomposedStringWithCanonicalMapping
        size = UInt64(info.st_size)
        let modified = info.st_mtimespec
        etag = "\"\(String(size, radix: 16))-\(String(modified.tv_sec, radix: 16)).\(String(modified.tv_nsec, radix: 16))\""
        mimeType = MIMEType.forFileName(name)
    }
}

/// Serves requests on one TCP connection, keep-alive included. All state is confined to `queue`.
final class HTTPConnection: @unchecked Sendable {
    private static let chunkSize = 1 << 20
    private static let idleTimeout: TimeInterval = 30

    private let connection: NWConnection
    private let context: HTTPServer.Context
    private let onClose: @Sendable (ObjectIdentifier) -> Void
    private let queue = DispatchQueue(label: "app.fastshare.connection")

    private var buffer: [UInt8] = []
    private var peerClosed = false
    private var closed = false
    private var idleTimer: DispatchWorkItem?
    private var transfer: Transfer?

    private struct Transfer {
        let token: String
        let file: FileHandle
        let countsAsDownload: Bool
        let keepAlive: Bool
        var remaining: UInt64
    }

    private enum Lookup {
        case found(OpenedFile)
        case unavailable(HTTPStatus, page: String)
    }

    init(_ connection: NWConnection, context: HTTPServer.Context, onClose: @escaping @Sendable (ObjectIdentifier) -> Void) {
        self.connection = connection
        self.context = context
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        queue.async { self.readNextRequest() }
    }

    func cancel() {
        queue.async { self.close() }
    }

    // MARK: - Requests

    private func readNextRequest() {
        guard !closed else { return }
        switch HTTPRequestParser.parse(buffer) {
        case .complete(let request, let consumed):
            buffer.removeFirst(consumed)
            idleTimer?.cancel()
            idleTimer = nil
            respond(to: request)
        case .malformed:
            sendPage(.badRequest, SharePages.badRequest(), isHead: false, keepAlive: false)
        case .headTooLarge:
            sendPage(.requestHeaderFieldsTooLarge, SharePages.badRequest(), isHead: false, keepAlive: false)
        case .incomplete:
            if peerClosed {
                close()
                return
            }
            if idleTimer == nil { armIdleTimer() }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { self.buffer.append(contentsOf: data) }
                if isComplete { self.peerClosed = true }
                if error != nil {
                    self.close()
                } else {
                    self.readNextRequest()
                }
            }
        }
    }

    /// Closes connections that sit idle between requests or trickle a request in too slowly.
    private func armIdleTimer() {
        let timer = DispatchWorkItem { [weak self] in self?.close() }
        idleTimer = timer
        queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: timer)
    }

    private func respond(to request: HTTPRequestHead) {
        let keepAlive = request.wantsKeepAlive && !request.hasBody && !peerClosed
        let isHead = request.method == "HEAD"
        guard isHead || request.method == "GET" else {
            sendPage(.methodNotAllowed, SharePages.methodNotAllowed(), isHead: false, keepAlive: false,
                     extraHeaders: [("Allow", "GET, HEAD")])
            return
        }

        switch ShareRoute(path: request.path) {
        case .home:
            sendPage(.ok, SharePages.home(senderName: context.senderName), isHead: isHead, keepAlive: keepAlive)
        case .notFound:
            sendPage(.notFound, SharePages.pageNotFound(), isHead: isHead, keepAlive: keepAlive)
        case .landing(let token):
            switch lookUp(token) {
            case .found(let file):
                let page = SharePages.landing(fileName: file.name, size: file.size, mimeType: file.mimeType,
                                              token: token, senderName: context.senderName)
                sendPage(.ok, page, isHead: isHead, keepAlive: keepAlive)
            case .unavailable(let status, let page):
                sendPage(status, page, isHead: isHead, keepAlive: keepAlive)
            }
        case .file(let token, let disposition):
            switch lookUp(token) {
            case .found(let file):
                sendFile(file, token: token, disposition: disposition, request: request, keepAlive: keepAlive)
            case .unavailable(let status, let page):
                sendPage(status, page, isHead: isHead, keepAlive: keepAlive)
            }
        }
    }

    private func lookUp(_ token: String) -> Lookup {
        guard let shared = context.registry.file(for: token) else {
            return .unavailable(.notFound, page: SharePages.linkNotFound())
        }
        guard shared.isActive else {
            return .unavailable(.forbidden, page: SharePages.linkInactive(token: token))
        }
        guard let file = OpenedFile(url: shared.fileURL) else {
            return .unavailable(.gone, page: SharePages.fileUnavailable())
        }
        return .found(file)
    }

    // MARK: - Responses

    private func sendFile(_ file: OpenedFile, token: String, disposition: ShareRoute.Disposition,
                          request: HTTPRequestHead, keepAlive: Bool) {
        var rangeHeader = request.header("range")
        if let ifRange = request.header("if-range"), ifRange != file.etag {
            rangeHeader = nil // The client's copy is stale: send the whole file.
        }

        var headers = baseHeaders(keepAlive: keepAlive) + [
            ("Content-Type", file.mimeType),
            ("Content-Disposition", ContentDisposition.header(disposition.rawValue, fileName: file.name)),
            ("Accept-Ranges", "bytes"),
            ("ETag", file.etag),
            ("Cache-Control", "no-store"),
            ("X-Content-Type-Options", "nosniff"),
        ]
        let status: HTTPStatus
        let start: UInt64
        let length: UInt64
        switch ByteRange.select(header: rangeHeader, fileSize: file.size) {
        case .entire:
            status = .ok
            start = 0
            length = file.size
        case .partial(let range):
            status = .partialContent
            start = range.lowerBound
            length = range.upperBound - range.lowerBound + 1
            headers.append(("Content-Range", "bytes \(range.lowerBound)-\(range.upperBound)/\(file.size)"))
        case .unsatisfiable:
            let headers = baseHeaders(keepAlive: keepAlive) + [
                ("Content-Range", "bytes */\(file.size)"),
                ("Content-Length", "0"),
            ]
            send(HTTPResponseHead(status: .rangeNotSatisfiable, headers: headers).serialized(), keepAlive: keepAlive)
            return
        }
        headers.append(("Content-Length", String(length)))
        let head = HTTPResponseHead(status: status, headers: headers).serialized()

        guard request.method == "GET" else {
            send(head, keepAlive: keepAlive)
            return
        }
        do {
            try file.handle.seek(toOffset: start)
        } catch {
            close()
            return
        }
        transfer = Transfer(token: token, file: file.handle, countsAsDownload: status == .ok,
                            keepAlive: keepAlive, remaining: length)
        context.emit(.transferStarted(token: token))
        connection.send(content: head, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.close()
            } else {
                self.sendNextChunk()
            }
        })
    }

    /// Streams the body one chunk at a time, reading the next chunk only after the previous one
    /// was handed to the network, so memory stays flat for files of any size.
    private func sendNextChunk() {
        guard !closed, var transfer else { return }
        if transfer.remaining == 0 {
            self.transfer = nil
            context.emit(.transferFinished(token: transfer.token, completedFile: transfer.countsAsDownload))
            finishResponse(keepAlive: transfer.keepAlive)
            return
        }
        let chunk: Data
        do {
            chunk = try transfer.file.read(upToCount: Int(min(UInt64(Self.chunkSize), transfer.remaining))) ?? Data()
        } catch {
            close()
            return
        }
        guard !chunk.isEmpty else {
            close() // The file shrank mid-transfer; the promised Content-Length can't be met.
            return
        }
        transfer.remaining -= UInt64(chunk.count)
        self.transfer = transfer
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.close()
            } else {
                self.sendNextChunk()
            }
        })
    }

    private func sendPage(_ status: HTTPStatus, _ html: String, isHead: Bool, keepAlive: Bool,
                          extraHeaders: [(String, String)] = []) {
        let body = Data(html.utf8)
        let headers = baseHeaders(keepAlive: keepAlive) + [
            ("Content-Type", "text/html; charset=utf-8"),
            ("Content-Length", String(body.count)),
            ("Cache-Control", "no-store"),
        ] + extraHeaders
        var data = HTTPResponseHead(status: status, headers: headers).serialized()
        if !isHead { data.append(body) }
        send(data, keepAlive: keepAlive)
    }

    private func send(_ data: Data, keepAlive: Bool) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.close()
            } else {
                self.finishResponse(keepAlive: keepAlive)
            }
        })
    }

    private func baseHeaders(keepAlive: Bool) -> [(String, String)] {
        [
            ("Date", HTTPDate.now()),
            ("Server", "FastShare"),
            ("Connection", keepAlive ? "keep-alive" : "close"),
        ]
    }

    private func finishResponse(keepAlive: Bool) {
        if keepAlive {
            readNextRequest()
        } else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [weak self] _ in self?.close() })
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        idleTimer?.cancel()
        idleTimer = nil
        if let transfer {
            self.transfer = nil
            context.emit(.transferFinished(token: transfer.token, completedFile: false))
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose(ObjectIdentifier(self))
    }
}

import Foundation
import os

/// A file the server may serve, addressed by its link token.
public struct ServedFile: Sendable, Equatable {
    public var token: String
    public var fileURL: URL
    public var isActive: Bool

    public init(token: String, fileURL: URL, isActive: Bool) {
        self.token = token
        self.fileURL = fileURL
        self.isActive = isActive
    }
}

/// Thread-safe token → file table: the app writes it, connection queues read it per request,
/// so toggling a link takes effect on the very next request.
public final class ShareRegistry: Sendable {
    private let files = OSAllocatedUnfairLock<[String: ServedFile]>(initialState: [:])

    public init() {}

    public func replaceAll(with newFiles: [ServedFile]) {
        let table = Dictionary(newFiles.map { ($0.token, $0) }, uniquingKeysWith: { _, last in last })
        files.withLock { $0 = table }
    }

    public func file(for token: String) -> ServedFile? {
        files.withLock { $0[token] }
    }
}

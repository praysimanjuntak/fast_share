import Foundation

/// Zips folders for sharing, the way Finder's Compress does, minus the Mac-only metadata.
public enum FolderArchiver {
    public struct Failure: LocalizedError {
        public let errorDescription: String?
    }

    /// Writes `folder`, as the archive's top-level entry, to `destination`. The archive only appears at
    /// `destination` once complete, atomically replacing any previous one, so a link never serves a
    /// half-written zip. Cancelling the task stops `ditto` and throws `CancellationError`.
    public static func zip(_ folder: URL, to destination: URL) async throws {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        let partial = directory.appendingPathComponent(".\(destination.lastPathComponent).partial")
        let log = directory.appendingPathComponent(".\(destination.lastPathComponent).log")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: partial)
        defer {
            try? fileManager.removeItem(at: partial)
            try? fileManager.removeItem(at: log)
        }
        fileManager.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // --norsrc leaves out resource forks, extended attributes and the __MACOSX folder phones would
        // show. Level 0 stores without compressing: shared folders are mostly photos and videos that
        // don't compress, and storing makes zipping about as fast as copying.
        process.arguments = ["-c", "-k", "--norsrc", "--keepParent", "--zlibCompressionLevel", "0", folder.path, partial.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = logHandle // A file, not a pipe: a full pipe would stall ditto.

        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        guard status == 0 else {
            let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let reason = output.split(separator: "\n").last.map(String.init)
            throw Failure(errorDescription: reason ?? "ditto stopped with status \(status).")
        }
        guard rename(partial.path, destination.path) == 0 else {
            throw Failure(errorDescription: String(cString: strerror(errno)))
        }
    }
}

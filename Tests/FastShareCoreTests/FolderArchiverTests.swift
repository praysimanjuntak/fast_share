import Foundation
import Testing
@testable import FastShareCore

struct FolderArchiverTests {
    private let workspace = FileManager.default.temporaryDirectory.appending(path: "FolderArchiverTests-\(UUID().uuidString)")

    @Test func zipsFolderAsTopLevelEntryAndReplacesPreviousArchive() async throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let folder = workspace.appending(path: "Trip Photos")
        try FileManager.default.createDirectory(at: folder.appending(path: "day 2"), withIntermediateDirectories: true)
        try Data("sunrise".utf8).write(to: folder.appending(path: "Café.txt"))
        try Data("beach".utf8).write(to: folder.appending(path: "day 2/beach.txt"))
        let archive = workspace.appending(path: "out/Trip Photos.zip")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old archive".utf8).write(to: archive)

        try await FolderArchiver.zip(folder, to: archive)

        let extracted = workspace.appending(path: "extracted")
        try run("/usr/bin/ditto", "-x", "-k", archive.path, extracted.path)
        #expect(try String(contentsOf: extracted.appending(path: "Trip Photos/Café.txt"), encoding: .utf8) == "sunrise")
        #expect(try String(contentsOf: extracted.appending(path: "Trip Photos/day 2/beach.txt"), encoding: .utf8) == "beach")
        #expect(try FileManager.default.contentsOfDirectory(atPath: extracted.path) == ["Trip Photos"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: archive.deletingLastPathComponent().path) == ["Trip Photos.zip"])
    }

    @Test func failureLeavesNothingBehind() async throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = workspace.appending(path: "out/Missing.zip")

        await #expect(throws: FolderArchiver.Failure.self) {
            try await FolderArchiver.zip(workspace.appending(path: "Missing"), to: archive)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: archive.deletingLastPathComponent().path).isEmpty)
    }

    private func run(_ executable: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

import Foundation
import Testing
@testable import FastShareCore

struct PathInputTests {
    private func resolve(_ input: String, existing: Set<String> = []) -> String? {
        PathInput.fileURL(from: input, fileExists: { existing.contains($0) })?.path
    }

    @Test(arguments: [
        ("/Users/me/Downloads/photos.zip", "/Users/me/Downloads/photos.zip"),
        ("  /Users/me/photos.zip \n", "/Users/me/photos.zip"),
        ("\"/Users/me/My File.zip\"", "/Users/me/My File.zip"),
        ("'/Users/me/My File.zip'", "/Users/me/My File.zip"),
        ("“/Users/me/My File.zip”", "/Users/me/My File.zip"),
        ("file:///Users/me/My%20File.zip", "/Users/me/My File.zip"),
        ("/Users/me/../me/./photos.zip", "/Users/me/photos.zip"),
    ])
    func acceptsAbsolutePathForms(input: String, path: String) {
        #expect(resolve(input) == path)
    }

    @Test func expandsTilde() {
        #expect(resolve("~/photos.zip") == NSHomeDirectory() + "/photos.zip")
    }

    @Test(arguments: ["", "   ", "photos.zip", "Downloads/photos.zip", "file://", "\"\""])
    func rejectsRelativeOrEmptyInput(input: String) {
        #expect(resolve(input) == nil)
    }

    @Test func undoesTerminalEscapesOnlyWhenLiteralPathIsMissing() {
        let escaped = #"/Users/me/My\ File\ (1).zip"#
        #expect(resolve(escaped, existing: ["/Users/me/My File (1).zip"]) == "/Users/me/My File (1).zip")
        #expect(resolve(escaped, existing: [escaped]) == escaped)
        #expect(resolve(escaped) == escaped)
    }
}

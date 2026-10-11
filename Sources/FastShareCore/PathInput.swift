import Foundation

/// Turns a typed or pasted path into a file URL.
public enum PathInput {
    private static let quotePairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’")]

    /// Accepts absolute paths, `~/…`, `file://` URLs, paths wrapped in quotes, and paths copied from
    /// Terminal with shell escapes (`My\ File.zip`). Returns nil when the input isn't an absolute path.
    public static func fileURL(
        from input: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, let first = text.first, let last = text.last,
           quotePairs.contains(where: { $0 == (first, last) }) {
            text = String(text.dropFirst().dropLast())
        }
        if text.lowercased().hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL, url.path.hasPrefix("/") else { return nil }
            return url.standardizedFileURL
        }
        text = (text as NSString).expandingTildeInPath
        guard text.hasPrefix("/") else { return nil }
        if !fileExists(text) {
            // Dragging a file into Terminal escapes spaces and symbols; a literal match still wins.
            let unescaped = removingShellEscapes(text)
            if unescaped != text, fileExists(unescaped) { text = unescaped }
        }
        return URL(fileURLWithPath: text).standardizedFileURL
    }

    private static func removingShellEscapes(_ text: String) -> String {
        var result = ""
        var isEscaped = false
        for character in text {
            if isEscaped || character != "\\" {
                result.append(character)
                isEscaped = false
            } else {
                isEscaped = true
            }
        }
        return result
    }
}

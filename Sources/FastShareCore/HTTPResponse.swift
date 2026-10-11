import Foundation
import UniformTypeIdentifiers

enum HTTPStatus: Int, Sendable {
    case ok = 200
    case partialContent = 206
    case badRequest = 400
    case forbidden = 403
    case notFound = 404
    case methodNotAllowed = 405
    case gone = 410
    case rangeNotSatisfiable = 416
    case requestHeaderFieldsTooLarge = 431

    var reasonPhrase: String {
        switch self {
        case .ok: "OK"
        case .partialContent: "Partial Content"
        case .badRequest: "Bad Request"
        case .forbidden: "Forbidden"
        case .notFound: "Not Found"
        case .methodNotAllowed: "Method Not Allowed"
        case .gone: "Gone"
        case .rangeNotSatisfiable: "Range Not Satisfiable"
        case .requestHeaderFieldsTooLarge: "Request Header Fields Too Large"
        }
    }
}

struct HTTPResponseHead {
    var status: HTTPStatus
    var headers: [(String, String)]

    func serialized() -> Data {
        var text = "HTTP/1.1 \(status.rawValue) \(status.reasonPhrase)\r\n"
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }
}

enum HTTPDate {
    // DateFormatter is Sendable and thread-safe for formatting.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    static func now() -> String {
        formatter.string(from: Date())
    }
}

enum ContentDisposition {
    /// RFC 5987 `attr-char`: everything else is percent-encoded in `filename*`.
    private static let attributeCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~"
    )

    /// `type` is `attachment` or `inline`. Carries an ASCII fallback plus the exact UTF-8 name (RFC 6266).
    static func header(_ type: String, fileName: String) -> String {
        let fallback = String(fileName.unicodeScalars.map { scalar -> Character in
            let isPlainASCII = (0x20..<0x7F).contains(scalar.value) && !"\"\\%".unicodeScalars.contains(scalar)
            return isPlainASCII ? Character(scalar) : "_"
        })
        let encoded = fileName.addingPercentEncoding(withAllowedCharacters: attributeCharacters) ?? fallback
        return "\(type); filename=\"\(fallback)\"; filename*=UTF-8''\(encoded)"
    }
}

enum MIMEType {
    static func forFileName(_ name: String) -> String {
        let pathExtension = (name as NSString).pathExtension
        guard !pathExtension.isEmpty,
              let mimeType = UTType(filenameExtension: pathExtension)?.preferredMIMEType
        else { return "application/octet-stream" }
        return mimeType.hasPrefix("text/") ? "\(mimeType); charset=utf-8" : mimeType
    }

    /// Types a phone browser can show directly; from there photos and videos can be saved to the library.
    static func isPreviewable(_ mimeType: String) -> Bool {
        ["image/", "video/", "audio/", "application/pdf", "text/plain"].contains { mimeType.hasPrefix($0) }
    }
}

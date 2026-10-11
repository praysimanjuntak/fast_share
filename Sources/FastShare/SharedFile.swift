import Foundation
import UniformTypeIdentifiers

/// One shared file and its link. Persisted between launches.
struct SharedFile: Codable, Identifiable, Hashable {
    /// The random part of the link: `http://<mac-ip>:<port>/<token>`.
    var token: String
    var path: String
    var isActive: Bool
    var createdAt: Date
    var downloadCount: Int
    /// Set when `path` is a zip the app made from this folder.
    var sourceFolder: String? = nil

    var id: String { token }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var kindDescription: String? { UTType(filenameExtension: url.pathExtension)?.localizedDescription }
}

enum FileStatus: Equatable {
    case available(size: Int64)
    case missing
}

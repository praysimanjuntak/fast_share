import AppKit
import FastShareCore
import Network
import Observation
import os
import SystemConfiguration

struct ShareAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

/// What a file's link looks like right now.
enum LinkState: Equatable {
    case ready(URL)
    case starting
    case noNetwork
    case serverFailed(String)
}

/// A folder being zipped. Its link token is reserved up front and goes live with the zip.
struct PendingArchive: Identifiable, Equatable {
    let id: String
    let folderPath: String

    var name: String { (folderPath as NSString).lastPathComponent }
}

/// App state: shared files, the sharing server, and the network address links point at.
@MainActor
@Observable
final class ShareStore {
    private(set) var files: [SharedFile] = []
    private(set) var pendingArchives: [PendingArchive] = []
    var selectedID: SharedFile.ID?
    private(set) var fileStatus: [SharedFile.ID: FileStatus] = [:]
    private(set) var addresses: [LocalAddress] = []
    private(set) var preferredInterface: String?
    private(set) var serverState: HTTPServer.State = .starting
    private(set) var activeTransfers: [SharedFile.ID: Int] = [:]
    var alert: ShareAlert?

    var isShowingAlert: Bool {
        get { alert != nil }
        set { if !newValue { alert = nil } }
    }

    @ObservationIgnored private let registry = ShareRegistry()
    @ObservationIgnored private var server: HTTPServer?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var addressRecheck: Task<Void, Never>?
    @ObservationIgnored private var archiveTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let libraryURL: URL
    /// Zips of shared folders, one subfolder per link token; each is deleted with its link.
    @ObservationIgnored private let archivesURL: URL
    @ObservationIgnored private let logger = Logger(subsystem: "app.fastshare.FastShare", category: "ShareStore")

    private static let preferredInterfaceKey = "preferredInterface"
    /// A fixed port keeps links stable across launches; the rest are fallbacks when it's taken.
    private static let ports: [UInt16] = Array(UInt16(8642)...UInt16(8660)) + [0]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Fast Share")
        libraryURL = support.appending(path: "shares.json")
        archivesURL = support.appending(path: "Archives")
        preferredInterface = UserDefaults.standard.string(forKey: Self.preferredInterfaceKey)
        files = loadLibrary()
        selectedID = files.first?.id
        filesChanged(persist: false)
        removeUnusedArchives()
    }

    // MARK: - Lifecycle

    func start() {
        refresh()
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.networkChanged() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "app.fastshare.path-monitor"))
        startServer()
    }

    func stop() {
        pathMonitor.cancel()
        server?.stop()
        for task in archiveTasks.values {
            task.cancel()
        }
    }

    /// Re-reads network addresses and whether shared files still exist.
    func refresh() {
        refreshAddresses()
        refreshFileStatus()
    }

    func restartServer() {
        server?.stop()
        startServer()
    }

    // MARK: - Links

    var selectedFile: SharedFile? {
        files.first { $0.id == selectedID }
    }

    var selectedPendingArchive: PendingArchive? {
        pendingArchives.first { $0.id == selectedID }
    }

    /// Folders being zipped for the first time; re-zips of shared folders keep their file row.
    var newArchives: [PendingArchive] {
        pendingArchives.filter { archive in !files.contains { $0.id == archive.id } }
    }

    func isZipping(_ id: SharedFile.ID) -> Bool {
        pendingArchives.contains { $0.id == id }
    }

    /// The user's chosen network if it's still connected, else the best available one.
    var currentAddress: LocalAddress? {
        addresses.first { $0.interfaceName == preferredInterface } ?? addresses.first
    }

    func linkState(for file: SharedFile) -> LinkState {
        switch serverState {
        case .starting:
            return .starting
        case .failed(let message):
            return .serverFailed(message)
        case .running(let port):
            guard let address = currentAddress,
                  let url = URL(string: "http://\(address.ip):\(port)/\(file.token)")
            else { return .noNetwork }
            return .ready(url)
        }
    }

    func link(for file: SharedFile) -> URL? {
        if case .ready(let url) = linkState(for: file) { url } else { nil }
    }

    func selectInterface(_ interfaceName: String) {
        preferredInterface = interfaceName
        UserDefaults.standard.set(interfaceName, forKey: Self.preferredInterfaceKey)
    }

    // MARK: - Sharing

    func chooseFilesToShare() {
        Task {
            let urls = await FilePicker.chooseFiles()
            if !urls.isEmpty { share(urls) }
        }
    }

    /// Gives every file its own link and selects the last one. Folders are zipped first, so a link
    /// still means one file. Sharing something again keeps its link and switches it back on; for a
    /// folder it also refreshes the zip.
    func share(_ urls: [URL]) {
        var unreadable: [String] = []
        var lastShared: SharedFile.ID?

        for url in urls where url.isFileURL {
            let itemURL = url.standardizedFileURL.resolvingSymlinksInPath()
            switch Self.inspect(itemURL) {
            case .file: lastShared = shareFile(itemURL)
            case .folder: lastShared = shareFolder(itemURL)
            case .missing, .unreadable: unreadable.append(itemURL.lastPathComponent)
            }
        }
        if let lastShared { selectedID = lastShared }
        filesChanged()

        if let name = unreadable.first {
            alert = ShareAlert(
                title: "Can’t share “\(name)”",
                message: "Fast Share couldn’t read it. Check that it still exists and that you’re allowed to open it."
            )
        }
    }

    /// Shares the file or folder at a typed or pasted path. Returns the reason when it can't.
    func share(path input: String) -> String? {
        guard let url = PathInput.fileURL(from: input)?.resolvingSymlinksInPath() else {
            return "Enter a full path, like /Users/you/Downloads/photos.zip."
        }
        switch Self.inspect(url) {
        case .missing: return "There’s nothing at that path."
        case .unreadable: return "Fast Share isn’t allowed to read that."
        case .file, .folder:
            share([url])
            return nil
        }
    }

    func setActive(_ isActive: Bool, for id: SharedFile.ID) {
        guard let index = files.firstIndex(where: { $0.id == id }), files[index].isActive != isActive else { return }
        files[index].isActive = isActive
        filesChanged()
    }

    /// Deletes the link, plus the zip if it was made from a folder. Shared files themselves stay put.
    func remove(_ id: SharedFile.ID) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        files.remove(at: index)
        archiveTasks.removeValue(forKey: id)?.cancel()
        pendingArchives.removeAll { $0.id == id }
        deleteArchiveIfUnused(id)
        if selectedID == id {
            selectedID = files.isEmpty ? nil : files[min(index, files.count - 1)].id
        }
        filesChanged()
    }

    func cancelArchive(_ id: SharedFile.ID) {
        archiveTasks.removeValue(forKey: id)?.cancel()
        pendingArchives.removeAll { $0.id == id }
        deleteArchiveIfUnused(id)
        if selectedID == id, !files.contains(where: { $0.id == id }) {
            selectedID = pendingArchives.first?.id ?? files.first?.id
        }
    }

    func copyLink(for file: SharedFile) {
        guard let url = link(for: file) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// Reveals the file, or for a zipped folder the original folder.
    func revealInFinder(_ file: SharedFile) {
        if let folder = file.sourceFolder, FileManager.default.fileExists(atPath: folder) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([file.url])
        }
    }

    // MARK: - Private

    private enum ItemKind {
        case file, folder, missing, unreadable
    }

    private static func inspect(_ url: URL) -> ItemKind {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else { return .missing }
        guard FileManager.default.isReadableFile(atPath: url.path) else { return .unreadable }
        if values.isDirectory == true { return .folder }
        return values.isRegularFile == true ? .file : .unreadable
    }

    private func shareFile(_ fileURL: URL) -> SharedFile.ID {
        if let index = files.firstIndex(where: { $0.path == fileURL.path }) {
            files[index].isActive = true
            return files[index].id
        }
        let file = SharedFile(token: makeToken(), path: fileURL.path, isActive: true, createdAt: Date(), downloadCount: 0)
        files.insert(file, at: 0)
        return file.id
    }

    /// Zips the folder in the background. Re-sharing a folder re-zips it under its existing link,
    /// which keeps serving the previous zip until the new one is complete.
    private func shareFolder(_ folderURL: URL) -> SharedFile.ID {
        if let pending = pendingArchives.first(where: { $0.folderPath == folderURL.path }) {
            return pending.id
        }
        let existing = files.firstIndex { $0.sourceFolder == folderURL.path }
        if let existing { files[existing].isActive = true }
        let token = existing.map { files[$0].token } ?? makeToken()
        let archive = archivesURL.appending(path: token).appending(path: folderURL.lastPathComponent + ".zip")
        pendingArchives.insert(PendingArchive(id: token, folderPath: folderURL.path), at: 0)
        archiveTasks[token] = Task { [weak self] in
            do {
                try await FolderArchiver.zip(folderURL, to: archive)
                self?.archiveFinished(token: token, folder: folderURL, archive: archive)
            } catch is CancellationError {
                // cancelArchive(_:) or remove(_:) already cleaned up.
            } catch {
                self?.archiveFailed(token: token, folderName: folderURL.lastPathComponent, error: error)
            }
        }
        return token
    }

    private func archiveFinished(token: String, folder: URL, archive: URL) {
        archiveTasks[token] = nil
        pendingArchives.removeAll { $0.id == token }
        if let index = files.firstIndex(where: { $0.token == token }) {
            files[index].path = archive.path
        } else {
            files.insert(SharedFile(token: token, path: archive.path, isActive: true, createdAt: Date(),
                                    downloadCount: 0, sourceFolder: folder.path), at: 0)
        }
        filesChanged()
    }

    private func archiveFailed(token: String, folderName: String, error: Error) {
        archiveTasks[token] = nil
        pendingArchives.removeAll { $0.id == token }
        deleteArchiveIfUnused(token)
        if selectedID == token, !files.contains(where: { $0.token == token }) {
            selectedID = pendingArchives.first?.id ?? files.first?.id
        }
        alert = ShareAlert(title: "Couldn’t zip “\(folderName)”", message: error.localizedDescription)
    }

    /// Only ever deletes inside the app's own Archives folder.
    private func deleteArchiveIfUnused(_ token: String) {
        guard !files.contains(where: { $0.token == token }) else { return }
        try? FileManager.default.removeItem(at: archivesURL.appending(path: token))
    }

    /// Deletes zips that no link uses any more and leftovers of zips interrupted by quitting.
    private func removeUnusedArchives() {
        let fileManager = FileManager.default
        let tokens = Set(files.map(\.token))
        for entry in (try? fileManager.contentsOfDirectory(at: archivesURL, includingPropertiesForKeys: nil)) ?? [] {
            guard tokens.contains(entry.lastPathComponent) else {
                try? fileManager.removeItem(at: entry)
                continue
            }
            for leftover in (try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []
            where leftover.lastPathComponent.hasPrefix(".") {
                try? fileManager.removeItem(at: leftover)
            }
        }
    }

    private func makeToken() -> String {
        var token: String
        repeat {
            token = ShareToken.generate()
        } while files.contains(where: { $0.token == token }) || pendingArchives.contains(where: { $0.id == token })
        return token
    }

    /// Pushes the file list to the server so the next request sees the change.
    private func filesChanged(persist: Bool = true) {
        if persist { saveLibrary() }
        registry.replaceAll(with: files.map { ServedFile(token: $0.token, fileURL: $0.url, isActive: $0.isActive) })
        refreshFileStatus()
    }

    private func refreshFileStatus() {
        var status: [SharedFile.ID: FileStatus] = [:]
        for file in files {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
               attributes[.type] as? FileAttributeType == .typeRegular,
               let size = attributes[.size] as? NSNumber {
                status[file.id] = .available(size: size.int64Value)
            } else {
                status[file.id] = .missing
            }
        }
        if status != fileStatus { fileStatus = status }
    }

    private func refreshAddresses() {
        let latest = LocalAddresses.current()
        if latest != addresses { addresses = latest }
    }

    private func networkChanged() {
        refreshAddresses()
        // DHCP can assign the address a moment after the path changes, so look again shortly.
        addressRecheck?.cancel()
        addressRecheck = Task { [weak self] in
            for _ in 0..<3 {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                self?.refreshAddresses()
            }
        }
    }

    private func startServer() {
        let server = HTTPServer(
            registry: registry,
            senderName: Self.computerName(),
            onStateChange: { [weak self] state in
                guard let self else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.serverState = state } }
            },
            onEvent: { [weak self] event in
                guard let self else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.handle(event) } }
            }
        )
        self.server = server
        server.start(ports: Self.ports)
    }

    private func handle(_ event: HTTPServer.Event) {
        switch event {
        case .transferStarted(let token):
            activeTransfers[token, default: 0] += 1
        case .transferFinished(let token, let completedFile):
            let remaining = (activeTransfers[token] ?? 0) - 1
            activeTransfers[token] = remaining > 0 ? remaining : nil
            if completedFile, let index = files.firstIndex(where: { $0.token == token }) {
                files[index].downloadCount += 1
                saveLibrary()
            }
        }
    }

    private func loadLibrary() -> [SharedFile] {
        guard let data = try? Data(contentsOf: libraryURL) else { return [] }
        do {
            return try Self.decoder.decode([SharedFile].self, from: data)
        } catch {
            logger.error("Ignoring unreadable share library: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func saveLibrary() {
        do {
            try FileManager.default.createDirectory(at: libraryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(files).write(to: libraryURL, options: .atomic)
        } catch {
            logger.error("Couldn’t save share library: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func computerName() -> String {
        SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "a Mac"
    }
}

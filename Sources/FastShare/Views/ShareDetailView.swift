import SwiftUI

/// The main page: the selected file's QR code and link controls.
struct DetailView: View {
    @Environment(ShareStore.self) private var store

    var body: some View {
        if let file = store.selectedFile {
            ShareDetailView(file: file)
        } else if let archive = store.selectedPendingArchive {
            ZippingView(archive: archive)
        } else if store.files.isEmpty && store.pendingArchives.isEmpty {
            EmptyStateView()
        } else {
            VStack(spacing: 10) {
                Image(systemName: "qrcode")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.tertiaryText)
                Text("Select a file to show its QR code")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

/// Shown while a newly shared folder is zipped; the QR code replaces it once the zip is ready.
private struct ZippingView: View {
    let archive: PendingArchive
    @Environment(ShareStore.self) private var store

    var body: some View {
        VStack(spacing: 14) {
            FileIcon(path: archive.folderPath)
                .frame(width: 64, height: 64)
            VStack(spacing: 6) {
                Text("Zipping “\(archive.name)”…")
                    .font(.system(size: 18, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text("The QR code appears here as soon as the zip is ready. Big folders can take a moment.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            ProgressView()
                .padding(.top, 4)
            Button("Cancel") { store.cancelArchive(archive.id) }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(40)
    }
}

private struct ShareDetailView: View {
    let file: SharedFile
    @Environment(ShareStore.self) private var store
    @State private var didCopy = false

    var body: some View {
        let linkState = store.linkState(for: file)
        let isMissing = store.fileStatus[file.id] == .missing

        VStack(spacing: 0) {
            Spacer(minLength: 24)
            header
            QRCard(state: linkState, isActive: file.isActive, isMissing: isMissing) {
                store.setActive(true, for: file.id)
            }
            .padding(.top, 24)
            caption(linkState: linkState, isMissing: isMissing)
                .frame(minHeight: 34, alignment: .top)
                .padding(.top, 14)
            linkField(linkState)
                .padding(.top, 10)
            LinkToggleCard(isActive: Binding(
                get: { file.isActive },
                set: { store.setActive($0, for: file.id) }
            ))
            .padding(.top, 12)
            footer(isMissing: isMissing)
                .padding(.top, 16)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: 440)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: file.id) { didCopy = false }
    }

    private var header: some View {
        HStack(spacing: 14) {
            FileIcon(path: file.path)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(metadata)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var metadata: String {
        var parts: [String] = []
        switch store.fileStatus[file.id] {
        case .available(let size): parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        case .missing: parts.append("File not found")
        case nil: break
        }
        if let kind = file.kindDescription { parts.append(kind) }
        if let folder = file.sourceFolder { parts.append("zipped from “\((folder as NSString).lastPathComponent)”") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func caption(linkState: LinkState, isMissing: Bool) -> some View {
        let transfers = store.activeTransfers[file.id] ?? 0
        if store.isZipping(file.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Updating the zip… the link keeps the previous version until it’s done.")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.accent)
        } else if transfers > 0 {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(transfers == 1 ? "Sending to a device…" : "Sending to \(transfers) devices…")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.accent)
        } else {
            Text(captionText(linkState: linkState, isMissing: isMissing))
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
    }

    private func captionText(linkState: LinkState, isMissing: Bool) -> String {
        if isMissing { return "Put the file back, or remove this link and share it again." }
        switch linkState {
        case .ready:
            return file.isActive
                ? "Scan with your phone’s camera. Your phone needs to be on the same Wi‑Fi, or this Mac on your phone’s hotspot."
                : "Turn the link on to let your phone download this file."
        case .starting: return "Starting the sharing server…"
        case .noNetwork: return "Connect this Mac to Wi‑Fi or to your phone’s hotspot to get a link."
        case .serverFailed(let message): return message
        }
    }

    @ViewBuilder
    private func linkField(_ linkState: LinkState) -> some View {
        let url: URL? = if case .ready(let url) = linkState { url } else { nil }
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
            Text(url?.absoluteString ?? "No link yet")
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(url == nil ? Theme.tertiaryText : Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                store.copyLink(for: file)
                didCopy = true
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    didCopy = false
                }
            } label: {
                Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(SecondaryButtonStyle(isCompact: true, background: .white))
            .disabled(url == nil)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill))
    }

    private func footer(isMissing: Bool) -> some View {
        HStack(spacing: 8) {
            Label(downloadsText, systemImage: "arrow.down.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 8)
            Button {
                store.revealInFinder(file)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(isMissing && file.sourceFolder == nil)
            Button {
                store.remove(file.id)
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(SecondaryButtonStyle(isDestructive: true))
            .help("Delete this link. The original file or folder stays where it is.")
        }
    }

    private var downloadsText: String {
        switch file.downloadCount {
        case 0: "No downloads yet"
        case 1: "Downloaded once"
        case let count: "Downloaded \(count) times"
        }
    }
}

private struct QRCard: View {
    let state: LinkState
    let isActive: Bool
    let isMissing: Bool
    let turnOn: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.07), radius: 20, y: 8)
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Theme.border)
            content
        }
        .frame(width: 264, height: 264)
        .animation(.easeInOut(duration: 0.2), value: isActive)
    }

    @ViewBuilder private var content: some View {
        if isMissing {
            Placeholder(symbol: "exclamationmark.triangle", title: "File not found", detail: "It was moved, renamed or deleted.")
        } else {
            switch state {
            case .ready(let url):
                ZStack {
                    QRCodeView(text: url.absoluteString)
                        .padding(20)
                        .opacity(isActive ? 1 : 0.07)
                    if !isActive {
                        VStack(spacing: 10) {
                            Image(systemName: "pause.circle.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(Theme.secondaryText)
                            Text("Link is off")
                                .font(.system(size: 14, weight: .semibold))
                            Button("Turn On", action: turnOn)
                                .buttonStyle(PrimaryButtonStyle())
                        }
                    }
                }
            case .starting:
                ProgressView()
            case .noNetwork:
                Placeholder(symbol: "wifi.slash", title: "No network", detail: "Join Wi‑Fi or your phone’s hotspot.")
            case .serverFailed:
                Placeholder(symbol: "exclamationmark.triangle", title: "Sharing unavailable", detail: "Press Retry in the sidebar.")
            }
        }
    }
}

private struct Placeholder: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.tertiaryText)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}

private struct LinkToggleCard: View {
    @Binding var isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(isActive ? Theme.success.opacity(0.12) : Theme.fill)
                Image(systemName: isActive ? "dot.radiowaves.left.and.right" : "pause.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActive ? Theme.success : Theme.secondaryText)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(isActive ? "Link is active" : "Link is off")
                    .font(.system(size: 13, weight: .semibold))
                Text(isActive
                    ? "Anyone on this network with the link can download the file."
                    : "Opening the link shows “turned off” until you switch it back on.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("Link active", isOn: $isActive)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }
}

import FastShareCore
import SwiftUI

struct SidebarView: View {
    @Environment(ShareStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Fast Share")
                    .font(.system(size: 22, weight: .bold))
                NetworkStatusView()
            }
            .padding(.horizontal, 16)
            .padding(.top, 52) // Clears the traffic lights.
            .padding(.bottom, 16)

            Hairline(axis: .horizontal)

            if store.files.isEmpty && store.pendingArchives.isEmpty {
                Text("Shared files appear here")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        // Distinct row IDs: a finished zip's file row reuses the pending row's token,
                        // and a shared ID would make the lazy stack keep the stale "Zipping…" row.
                        ForEach(store.newArchives, id: \.folderPath) { archive in
                            PendingArchiveRow(archive: archive, isSelected: archive.id == store.selectedID)
                        }
                        ForEach(store.files) { file in
                            FileRow(file: file, isSelected: file.id == store.selectedID)
                        }
                    }
                    .padding(8)
                }
            }

            Hairline(axis: .horizontal)

            VStack(spacing: 10) {
                PathField()
                Button {
                    store.chooseFilesToShare()
                } label: {
                    Label("Share a File…", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(14)
        }
        .background(Theme.sidebar)
    }
}

/// Which network links point at, or why there's no link.
private struct NetworkStatusView: View {
    @Environment(ShareStore.self) private var store

    var body: some View {
        let status = status
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(status.tint.opacity(0.12))
                Image(systemName: status.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(status.tint)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(status.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(status.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            accessory
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
    }

    @ViewBuilder private var accessory: some View {
        if case .failed = store.serverState {
            Button("Retry") { store.restartServer() }
                .buttonStyle(SecondaryButtonStyle(isCompact: true))
        } else if store.addresses.count > 1 {
            Menu {
                ForEach(store.addresses) { address in
                    Toggle(isOn: Binding(
                        get: { address == store.currentAddress },
                        set: { if $0 { store.selectInterface(address.interfaceName) } }
                    )) {
                        Text("\(address.displayName) — \(address.ip)")
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose the network your links use")
        }
    }

    private var status: (symbol: String, tint: Color, title: String, detail: String) {
        switch store.serverState {
        case .starting:
            return ("hourglass", Theme.secondaryText, "Starting…", "Preparing the sharing server")
        case .failed(let message):
            return ("exclamationmark.triangle.fill", Theme.danger, "Sharing unavailable", message)
        case .running(let port):
            guard let address = store.currentAddress else {
                return ("wifi.slash", Theme.warning, "Not connected", "Join Wi‑Fi or your phone’s hotspot")
            }
            let symbol = switch address.kind {
            case .wifi: "wifi"
            case .ethernet: "cable.connector"
            case .other: "network"
            }
            return (symbol, Theme.success, address.displayName, "\(address.ip) · port \(port)")
        }
    }
}

private struct FileRow: View {
    let file: SharedFile
    let isSelected: Bool
    @Environment(ShareStore.self) private var store
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                store.selectedID = file.id
            } label: {
                HStack(spacing: 10) {
                    FileIcon(path: file.path)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 6, height: 6)
                            Text(statusText)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                }
                .padding(.leading, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Toggle("Link active", isOn: Binding(
                get: { file.isActive },
                set: { store.setActive($0, for: file.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(file.isActive ? "Turn link off" : "Turn link on")
            .padding(.trailing, 10)
        }
        .sidebarRow(isSelected: isSelected, isHovered: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Copy Link") { store.copyLink(for: file) }
                .disabled(store.link(for: file) == nil)
            Button(file.isActive ? "Turn Link Off" : "Turn Link On") {
                store.setActive(!file.isActive, for: file.id)
            }
            Button("Show in Finder") { store.revealInFinder(file) }
            Divider()
            Button("Remove Link", role: .destructive) { store.remove(file.id) }
        }
    }

    private var isMissing: Bool { store.fileStatus[file.id] == .missing }

    private var statusColor: Color {
        if isMissing { return Theme.danger }
        return file.isActive ? Theme.success : Theme.tertiaryText
    }

    private var statusText: String {
        if store.isZipping(file.id) { return "Updating zip…" }
        if isMissing { return "File missing" }
        var parts: [String] = []
        if case .available(let size) = store.fileStatus[file.id] {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        parts.append(file.isActive ? "Active" : "Off")
        return parts.joined(separator: " · ")
    }
}

/// A folder that's still being zipped; it becomes a regular row once its link is live.
private struct PendingArchiveRow: View {
    let archive: PendingArchive
    let isSelected: Bool
    @Environment(ShareStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            Button {
                store.selectedID = archive.id
            } label: {
                HStack(spacing: 10) {
                    FileIcon(path: archive.folderPath)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(archive.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Zipping…")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    Spacer(minLength: 6)
                }
                .padding(.leading, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button {
                store.cancelArchive(archive.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Stop zipping")
            .accessibilityLabel("Stop zipping")
            .padding(.trailing, 12)
        }
        .sidebarRow(isSelected: isSelected, isHovered: false)
    }
}

/// Type or paste a path, press Return, and the file (or zipped folder) is shared right away.
private struct PathField: View {
    @Environment(ShareStore.self) private var store
    @State private var text = ""
    @State private var problem: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryText)
                TextField("Paste a file or folder path…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .autocorrectionDisabled()
                    .focused($isFocused)
                    .onSubmit(share)
                if !text.isEmpty {
                    Button(action: share) {
                        Image(systemName: "return")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Share (Return)")
                    .accessibilityLabel("Share path")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(problem != nil ? Theme.danger.opacity(0.7) : isFocused ? Theme.accent.opacity(0.6) : Theme.border)
            )
            if let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: text) { problem = nil }
        .onAppear { isFocused = true } // Open the app, paste, press Return.
    }

    private func share() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        problem = store.share(path: text)
        if problem == nil { text = "" }
    }
}

private extension View {
    func sidebarRow(isSelected: Bool, isHovered: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Theme.accentSoft : isHovered ? Theme.hover : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.25) : .clear)
        )
    }
}

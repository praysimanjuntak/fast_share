import SwiftUI

/// First-run page: invites a drop or a pick.
struct EmptyStateView: View {
    @Environment(ShareStore.self) private var store

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Theme.accentSoft)
                    .frame(width: 84, height: 84)
                Image(systemName: "arrow.up.doc.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            VStack(spacing: 8) {
                Text("Share a file with your phone")
                    .font(.system(size: 20, weight: .semibold))
                Text("Drop a file or folder here, choose one, or paste its path on the left. You’ll get a link and a QR code to open on your phone — on the same Wi‑Fi, or with this Mac on your phone’s hotspot.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            Button {
                store.chooseFilesToShare()
            } label: {
                Label("Choose File…", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
            Text("One link per file. Folders are zipped automatically.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                .padding(32)
        )
    }
}

import SwiftUI

struct ContentView: View {
    @Environment(ShareStore.self) private var store
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 300)
            Hairline(axis: .vertical)
            DetailView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white)
        }
        .ignoresSafeArea()
        .frame(minWidth: 840, minHeight: 620)
        .overlay {
            if isDropTargeted { DropOverlay() }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.share(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .alert(store.alert?.title ?? "", isPresented: $store.isShowingAlert, presenting: store.alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
    }
}

/// Shown while files are dragged over the window.
private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Color.white.opacity(0.88)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(16)
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accent)
                Text("Drop to share")
                    .font(.system(size: 18, weight: .semibold))
                Text("Each file gets its own link; folders are zipped")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

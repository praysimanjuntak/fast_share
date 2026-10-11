import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let store = ShareStore()
    private var window: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua) // White theme everywhere, panels and alerts included.
        NSApp.mainMenu = MainMenu.make(target: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
        showMainWindow(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    /// Closing the window keeps links alive; quitting stops sharing.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow(nil) }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        store.refresh()
    }

    /// Files dropped on the Dock icon or opened with "Open With › Fast Share".
    func application(_ application: NSApplication, open urls: [URL]) {
        store.share(urls)
        showMainWindow(nil)
    }

    // MARK: - Menu actions

    @objc func showMainWindow(_ sender: Any?) {
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func shareFile(_ sender: Any?) {
        showMainWindow(nil)
        store.chooseFilesToShare()
    }

    @objc func copyLink(_ sender: Any?) {
        guard let file = store.selectedFile else { return }
        store.copyLink(for: file)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copyLink(_:)) {
            return store.selectedFile.flatMap(store.link(for:)) != nil
        }
        return true
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Fast Share"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .white
        window.isReleasedWhenClosed = false
        let hostingView = NSHostingView(rootView: ContentView().environment(store))
        hostingView.sizingOptions = [.minSize]
        window.contentView = hostingView
        window.center()
        window.setFrameAutosaveName("MainWindow")
        return window
    }
}

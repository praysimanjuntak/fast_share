import AppKit

@MainActor
enum FilePicker {
    /// Lets the user pick files or folders to share.
    static func chooseFiles() async -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Share Files or Folders"
        panel.message = "Each file gets its own link. Folders are zipped automatically."
        panel.prompt = "Share"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.urls : []
    }
}

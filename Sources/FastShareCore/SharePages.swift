import Foundation

/// HTML the phone sees. Self-contained (no external assets) and light-themed to match the app.
enum SharePages {
    static func landing(fileName: String, size: UInt64, mimeType: String, token: String, senderName: String) -> String {
        let name = escape(fileName)
        let pathExtension = (fileName as NSString).pathExtension
        let badge = (1...5).contains(pathExtension.count) ? escape(pathExtension.uppercased()) : "FILE"
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)
        let openButton = MIMEType.isPreviewable(mimeType)
            ? #"<a class="button secondary" href="/\#(token)/view">Open</a>"#
            : ""
        return document(title: name, content: """
            <div class="badge">\(badge)</div>
            <h1>\(name)</h1>
            <p class="meta">\(sizeText)</p>
            <div class="actions">
              <a class="button primary" href="/\(token)/download" download>\(Icon.download)Download</a>
              \(openButton)
            </div>
            <p class="footnote">Shared from \(escape(senderName)) with Fast Share</p>
            """)
    }

    static func linkInactive(token: String) -> String {
        message(
            icon: Icon.pause,
            title: "This link is turned off",
            detail: "Ask the sender to turn it back on in Fast Share, then try again.",
            action: (label: "Try Again", href: "/\(token)")
        )
    }

    static func linkNotFound() -> String {
        message(
            icon: Icon.question,
            title: "Link not found",
            detail: "This link doesn’t exist or was removed. Scan the latest QR code in Fast Share."
        )
    }

    static func fileUnavailable() -> String {
        message(
            icon: Icon.missingFile,
            title: "File no longer available",
            detail: "The shared file was moved, renamed or deleted on the Mac."
        )
    }

    static func pageNotFound() -> String {
        message(icon: Icon.question, title: "Page not found", detail: "Scan a QR code in Fast Share to open a shared file.")
    }

    static func home(senderName: String) -> String {
        message(
            icon: Icon.qrCode,
            title: "Fast Share is running",
            detail: "Scan a file’s QR code in Fast Share on \(senderName) to open it here."
        )
    }

    static func badRequest() -> String {
        message(icon: Icon.question, title: "Bad request", detail: "The browser sent a request Fast Share doesn’t understand.")
    }

    static func methodNotAllowed() -> String {
        message(icon: Icon.question, title: "Not supported", detail: "Fast Share only serves downloads.")
    }

    // MARK: - Building blocks

    private static func message(icon: String, title: String, detail: String, action: (label: String, href: String)? = nil) -> String {
        let button = action.map {
            #"<div class="actions"><a class="button secondary" href="\#($0.href)">\#(escape($0.label))</a></div>"#
        } ?? ""
        return document(title: escape(title), content: """
            <div class="icon">\(icon)</div>
            <h1>\(escape(title))</h1>
            <p class="meta">\(escape(detail))</p>
            \(button)
            """)
    }

    private static func document(title: String, content: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="color-scheme" content="light">
        <meta name="theme-color" content="#ffffff">
        <title>\(title)</title>
        <style>\(stylesheet)</style>
        </head>
        <body>
        <main>
        \(content)
        </main>
        </body>
        </html>
        """
    }

    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    private static let stylesheet = """
        :root{--accent:#2563eb;--accent-pressed:#1d4ed8;--text:#0f172a;--muted:#64748b;--line:#e2e8f0;--soft:#eff6ff;--fill:#f1f5f9}
        *{box-sizing:border-box;margin:0}
        html{-webkit-text-size-adjust:100%}
        body{background:#fff;color:var(--text);font:16px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased}
        main{min-height:100vh;min-height:100dvh;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:40px 24px calc(40px + env(safe-area-inset-bottom));text-align:center}
        .badge{width:84px;height:100px;border-radius:20px;background:var(--soft);border:1px solid #dbeafe;color:var(--accent);display:flex;align-items:center;justify-content:center;font-weight:700;font-size:17px;letter-spacing:.06em;margin-bottom:28px}
        .icon{width:84px;height:84px;border-radius:50%;background:var(--fill);color:var(--muted);display:flex;align-items:center;justify-content:center;margin-bottom:24px}
        h1{font-size:22px;font-weight:650;line-height:1.3;max-width:520px;overflow-wrap:anywhere}
        .meta{color:var(--muted);font-size:15px;margin-top:6px;max-width:420px}
        .actions{width:100%;max-width:360px;display:flex;flex-direction:column;gap:12px;margin-top:32px}
        .button{display:flex;align-items:center;justify-content:center;gap:8px;padding:16px 20px;border-radius:14px;font-size:17px;font-weight:600;text-decoration:none;-webkit-tap-highlight-color:transparent}
        .primary{background:var(--accent);color:#fff}
        .primary:active{background:var(--accent-pressed)}
        .secondary{background:var(--fill);color:var(--text)}
        .secondary:active{background:var(--line)}
        .footnote{margin-top:36px;color:var(--muted);font-size:13px}
        """

    private enum Icon {
        static let download = #"<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 4v11"/><path d="m7 10 5 5 5-5"/><path d="M5 20h14"/></svg>"#
        static let pause = #"<svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="9.5"/><path d="M10 9v6M14 9v6"/></svg>"#
        static let question = #"<svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="9.5"/><path d="M9.5 9.2a2.6 2.6 0 0 1 5 1c0 1.7-2.5 2.2-2.5 3.8"/><path d="M12 17.2h.01"/></svg>"#
        static let missingFile = #"<svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/><path d="m10 12.5 4 4M14 12.5l-4 4"/></svg>"#
        static let qrCode = #"<svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" aria-hidden="true"><rect x="3.5" y="3.5" width="6.5" height="6.5" rx="1.5"/><rect x="14" y="3.5" width="6.5" height="6.5" rx="1.5"/><rect x="3.5" y="14" width="6.5" height="6.5" rx="1.5"/><path d="M14 14h2.5v2.5H14zM18 18h2.5v2.5H18zM14 18.5h1.5M18.5 14h2"/></svg>"#
    }
}

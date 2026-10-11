import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct Hairline: View {
    let axis: Axis

    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}

/// Finder's icon for the file.
struct FileIcon: View {
    let path: String

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
}

/// A crisp QR code: modules are scaled with nearest-neighbor sampling.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = QRCodeRenderer.image(for: text) {
            Image(image, scale: 1, label: Text("QR code for \(text)"))
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
        }
    }
}

@MainActor
private enum QRCodeRenderer {
    private static let context = CIContext()
    private static var cache: [String: CGImage] = [:]

    static func image(for text: String) -> CGImage? {
        if let cached = cache[text] { return cached }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = context.createCGImage(output, from: output.extent)
        else { return nil }
        cache[text] = image
        return image
    }
}

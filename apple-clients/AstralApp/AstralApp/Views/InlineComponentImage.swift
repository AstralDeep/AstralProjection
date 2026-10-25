// Decodes bounded JPEG and PNG data URIs for the shared component renderer without network access.
// Loaded pixels use the existing canvas capture registry and its owner-bound retention checks.

import AstralCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum InlineComponentImage {
    static func permitsDimensions(width: Int, height: Int) -> Bool {
        (1...8192).contains(width) && (1...8192).contains(height) && width <= 16_777_216 / height
    }

    static func decode(_ source: String) -> CGImage? {
        let prefix: String
        let type: UTType
        if source.hasPrefix("data:image/jpeg;base64,") {
            prefix = "data:image/jpeg;base64,"
            type = .jpeg
        } else if source.hasPrefix("data:image/png;base64,") {
            prefix = "data:image/png;base64,"
            type = .png
        } else {
            return nil
        }
        guard source.utf8.count <= 8 * 1024 * 1024 + prefix.utf8.count,
            let data = Data(base64Encoded: String(source.dropFirst(prefix.count))), !data.isEmpty,
            data.count <= 6 * 1024 * 1024,
            let imageSource = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetType(imageSource) as String? == type.identifier,
            CGImageSourceGetCount(imageSource) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            permitsDimensions(width: width, height: height)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(
            imageSource, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

struct InlineComponentImageView: View {
    let source: String
    let node: CanvasCaptureNode?
    let registry: CanvasCaptureRegistry
    @State private var decoded: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let decoded {
                CanvasLoadedImage(image: Image(decorative: decoded, scale: 1), node: node, registry: registry)
            } else if failed {
                Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                    .font(ConsoleTypography.caption)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: source) {
            decoded = nil
            failed = false
            let image = await Task.detached(priority: .userInitiated) { InlineComponentImage.decode(source) }.value
            guard !Task.isCancelled else { return }
            decoded = image
            failed = image == nil
            if failed, let node { registry.retain(nil, for: node) }
        }
    }
}

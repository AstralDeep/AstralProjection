// Reads a user-selected local file within the kernel's attachment limits before passing its bytes to the encrypted log.
// The composer uses the same type list for its picker, while the kernel remains responsible for content and authorization checks.

import Foundation
import UniformTypeIdentifiers

nonisolated enum MeshAttachmentFile {
    struct Input: Sendable {
        let bytes: Data
        let mime: String
        let name: String
    }

    static let maximumBytes = 16 * 1024 * 1024
    static let maximumCount = 8
    private static let mimeByExtension = [
        "json": "application/json", "pdf": "application/pdf", "gif": "image/gif", "jpg": "image/jpeg",
        "jpeg": "image/jpeg", "png": "image/png", "webp": "image/webp", "csv": "text/csv",
        "md": "text/markdown", "markdown": "text/markdown", "txt": "text/plain",
    ]
    static var contentTypes: [UTType] {
        Set(mimeByExtension.values).sorted().compactMap { UTType(mimeType: $0) }
    }

    static func read(_ url: URL) throws -> Input {
        guard url.isFileURL else { throw MeshKernelError.refused("Choose a file on this device.") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MeshKernelError.refused("Choose a regular file.")
        }
        guard let mime = mimeByExtension[url.pathExtension.lowercased()] else {
            throw MeshKernelError.refused("Choose a PDF, image, text, Markdown, CSV or JSON file.")
        }
        let name = url.lastPathComponent
        guard !name.isEmpty, name.count <= 255, !name.contains("\\"),
            name.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
        else { throw MeshKernelError.refused("Rename the file before attaching it.") }
        guard (values.fileSize ?? 0) <= maximumBytes else {
            throw MeshKernelError.refused("Choose a file no larger than 16 MB.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var bytes = Data()
        while let chunk = try file.read(upToCount: min(262_144, maximumBytes + 1 - bytes.count)), !chunk.isEmpty {
            bytes.append(chunk)
            guard bytes.count <= maximumBytes else {
                throw MeshKernelError.refused("Choose a file no larger than 16 MB.")
            }
        }
        guard !bytes.isEmpty else { throw MeshKernelError.refused("That file is empty.") }
        return Input(bytes: bytes, mime: mime, name: name)
    }
}

// The plain-text document the recovery screen hands to the system save panel, holding one numbered recovery word per line.
// MeshRecoveryView supplies the words and the person picks where the file goes, so nothing here writes to disk itself.

import SwiftUI
import UniformTypeIdentifiers

struct MeshRecoveryWordsDocument: FileDocument {
    static let defaultFilename = "AstralDeep Recovery Words"
    static var readableContentTypes: [UTType] { [.plainText] }
    static var writableContentTypes: [UTType] { [.plainText] }
    private let words: [String]

    init(words: [String]) { self.words = words }

    init(configuration: ReadConfiguration) throws { throw CocoaError(.fileReadUnsupportedScheme) }

    var text: String {
        words.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") + "\n"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

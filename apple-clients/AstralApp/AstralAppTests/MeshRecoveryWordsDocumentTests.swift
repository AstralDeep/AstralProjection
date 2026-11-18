// Verifies the recovery-words text file holds exactly one numbered word per line and nothing else.
// The document builds in memory, so no test writes a file or touches the save panel.

import XCTest

@testable import AstralDeep

final class MeshRecoveryWordsDocumentTests: XCTestCase {
    func testTextIsOneNumberedWordPerLineAndNothingElse() {
        let words = (1...24).map { "word\($0)" }
        let lines = MeshRecoveryWordsDocument(words: words).text.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 25)
        XCTAssertEqual(lines.last, "")
        for (index, word) in words.enumerated() { XCTAssertEqual(String(lines[index]), "\(index + 1). \(word)") }
    }

    func testFileBytesMatchTheTextAndTheDefaultNameIsStable() {
        let document = MeshRecoveryWordsDocument(words: ["alpha", "beta"])
        XCTAssertEqual(document.text, "1. alpha\n2. beta\n")
        XCTAssertEqual(MeshRecoveryWordsDocument.defaultFilename, "AstralDeep Recovery Words")
    }
}

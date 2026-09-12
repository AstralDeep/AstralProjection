// Feature 053 — the shared inline-markdown parse every surface renders through.
// The contract under test: inline spans are styled (no literal asterisks reach
// a screen), block syntax and newlines survive verbatim, and no input can
// yield a blank or thrown result.
import XCTest

@testable import AstralCore

final class InlineMarkdownTests: XCTestCase {

    private func plain(_ s: String) -> String {
        String(InlineMarkdown.attributed(s).characters)
    }

    func testBoldMarkersAreConsumed() {
        XCTAssertEqual(plain("The **answer** is 42"), "The answer is 42")
    }

    func testItalicAndCodeMarkersAreConsumed() {
        XCTAssertEqual(plain("*emphasis* and `code`"), "emphasis and code")
    }

    func testLinkShowsItsLabel() {
        XCTAssertEqual(plain("see [the docs](https://sandbox.ai.uky.edu)"), "see the docs")
    }

    func testDangerousLinkSchemesLoseOnlyClickability() {
        for destination in [
            "javascript:alert(1)", "data:text/html,test", "file:///private/test", "tel:123",
            "astraldeep://callback?code=test", "intent://example", "ftp://files.example/test",
        ] {
            let text = InlineMarkdown.attributed("**Read** [the docs](\(destination))\n*Carefully*")
            XCTAssertEqual(String(text.characters), "Read the docs\nCarefully", destination)
            XCTAssertTrue(text.runs.allSatisfy { $0.link == nil }, destination)
            XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
            XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        }
    }

    func testApprovedLinksAndRootReferencesRetainClickability() throws {
        for destination in [
            "https://docs.example.test/guide?q=one#part", "http://localhost:8001/guide",
            "mailto:support@example.test", "/guide?q=one#part", "//docs.example.test/guide",
        ] {
            let text = InlineMarkdown.attributed("[the docs](\(destination))")
            XCTAssertEqual(try XCTUnwrap(text.runs.first?.link).absoluteString, destination)
        }
    }

    func testRootLinksResolveUsingConfiguredBackendWithoutBorrowingCredentials() throws {
        let base = try XCTUnwrap(URL(string: "https://configured.example.test:8443/workspace?mode=one"))
        let relative = try XCTUnwrap(URL(string: "/guide?q=one#part"))
        XCTAssertEqual(InlineMarkdown.safeLink(relative)?.absoluteString, "/guide?q=one#part")
        XCTAssertEqual(
            InlineMarkdown.safeLink(relative, relativeTo: base)?.absoluteString,
            "https://configured.example.test:8443/guide?q=one#part")
        XCTAssertEqual(
            InlineMarkdown.safeLink(URL(string: "//docs.example.test/guide")!, relativeTo: base)?.absoluteString,
            "https://docs.example.test/guide")
        for invalidBase in [
            "file:///private/test", "https://user:password@example.test", "https://example.test/#fragment",
        ] {
            XCTAssertNil(InlineMarkdown.safeLink(relative, relativeTo: URL(string: invalidBase)!))
        }
    }

    func testMalformedAndUnsupportedRelativeLinksAreInert() {
        for destination in ["https:", "https:///guide", "mailto:", "mailto://example.test", "#part", "guide", "//"] {
            if let url = URL(string: destination) { XCTAssertNil(InlineMarkdown.safeLink(url), destination) }
        }
        let text = InlineMarkdown.attributed("[label](file:///private/test) and `code`")
        XCTAssertEqual(String(text.characters), "label and code")
        XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }

    func testNewlinesArePreserved() {
        // inlineOnlyPreservingWhitespace: multi-line narrative keeps its shape.
        XCTAssertEqual(plain("line one\nline two"), "line one\nline two")
    }

    func testBlockSyntaxStaysLiteral() {
        // Inline-only by design (parity with the phone renderer): a heading
        // marker is not a style, it is content.
        XCTAssertEqual(plain("# Heading"), "# Heading")
    }

    func testPlainTextPassesThroughUnchanged() {
        XCTAssertEqual(plain("2 * 3 * 4 = 24"), "2 * 3 * 4 = 24")
    }

    func testEmptyStringDoesNotThrowOrBlank() {
        XCTAssertEqual(plain(""), "")
    }
}

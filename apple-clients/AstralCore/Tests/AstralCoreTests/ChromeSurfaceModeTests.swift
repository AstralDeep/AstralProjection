// Tests for the chrome_surface mode field: defaults to replace when absent, parses when present, and falls
// back safely for non-string values.

import XCTest

@testable import AstralCore

final class ChromeSurfaceModeTests: XCTestCase {

    private func frame(_ json: String) -> InboundFrame {
        InboundFrame.parse(json)!
    }

    func testMandatoryModeParsesWhenPresent() {
        let f = frame(
            #"{"type":"chrome_surface","surface_key":"llm","title":"Set up your AI provider","components":[],"mode":"mandatory"}"#
        )
        XCTAssertEqual(f.surfaceMode, "mandatory")
    }

    func testModeDefaultsToReplaceWhenAbsent() {
        let f = frame(#"{"type":"chrome_surface","surface_key":"theme","title":"Appearance","components":[]}"#)
        XCTAssertEqual(f.surfaceMode, "replace")
    }

    func testExplicitReplaceParses() {
        let f = frame(#"{"type":"chrome_surface","surface_key":"","components":[],"mode":"replace"}"#)
        XCTAssertEqual(f.surfaceMode, "replace")
    }

    func testNonStringModeFallsBackToReplace() {
        let f = frame(#"{"type":"chrome_surface","surface_key":"llm","components":[],"mode":7}"#)
        XCTAssertEqual(f.surfaceMode, "replace")
    }
}

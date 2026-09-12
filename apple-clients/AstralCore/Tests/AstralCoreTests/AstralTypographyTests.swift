import CoreText
import XCTest

@testable import AstralCore

final class AstralTypographyTests: XCTestCase {
    func testApprovedBundledFontsRegisterWithoutFamilySubstitution() {
        AstralTypography.registerFonts()
        for name in [AstralTypography.sansName, AstralTypography.monoName] {
            let font = CTFontCreateWithName(name as CFString, 16, nil)
            XCTAssertEqual(CTFontCopyPostScriptName(font) as String, name)
        }
    }
}

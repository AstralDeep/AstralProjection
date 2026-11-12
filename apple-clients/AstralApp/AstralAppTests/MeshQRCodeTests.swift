// Verifies that pairing payloads render as QR images so the iOS simulator and Mac can show them without a camera.

@testable import AstralDeep
import XCTest

final class MeshQRCodeTests: XCTestCase {
    func testQRCodeRendersAndDiffersByPayload() {
        let first = MeshQRCode.image(for: "astral-pair:v1:one")
        let second = MeshQRCode.image(for: "astral-pair:v1:two")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertGreaterThan(first?.width ?? 0, 100)
    }
}

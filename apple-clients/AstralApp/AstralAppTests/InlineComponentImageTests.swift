// Verifies bounded inline screenshot decoding before images enter the shared component renderer.

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import AstralDeep

final class InlineComponentImageTests: XCTestCase {
    func testPNGAndJPEGDecodeToTheirActualPixelDimensions() throws {
        for (mime, type) in [("image/png", UTType.png), ("image/jpeg", UTType.jpeg)] {
            let source = try encodedImage(mime: mime, type: type)
            let image = try XCTUnwrap(InlineComponentImage.decode(source))
            XCTAssertEqual(image.width, 32)
            XCTAssertEqual(image.height, 16)
        }
    }

    func testSpoofedUnsupportedMalformedAndRemoteSourcesAreRejected() throws {
        let png = try encodedImage(mime: "image/png", type: .png)
        for source in [
            png.replacingOccurrences(of: "image/png", with: "image/jpeg"),
            png.replacingOccurrences(of: "image/png", with: "image/gif"),
            png.replacingOccurrences(of: ";base64,", with: ","),
            "data:image/png;base64,%%%%", "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=",
            "https://example.test/image.png", "file:///tmp/image.png", "data:image/png;base64,",
        ] {
            XCTAssertNil(InlineComponentImage.decode(source))
        }
    }

    func testByteAndPixelBudgetsRejectOversizedImages() throws {
        let oversized = "data:image/png;base64," + String(repeating: "A", count: 8 * 1024 * 1024 + 4)
        XCTAssertNil(InlineComponentImage.decode(oversized))
        XCTAssertNil(
            InlineComponentImage.decode(try encodedImage(mime: "image/png", type: .png, width: 8193, height: 1)))
        XCTAssertTrue(InlineComponentImage.permitsDimensions(width: 1920, height: 1200))
        XCTAssertTrue(InlineComponentImage.permitsDimensions(width: 4096, height: 4096))
        XCTAssertFalse(InlineComponentImage.permitsDimensions(width: 4097, height: 4097))
        XCTAssertFalse(InlineComponentImage.permitsDimensions(width: 0, height: 16))
        XCTAssertFalse(InlineComponentImage.permitsDimensions(width: Int.max, height: Int.max))
    }

    private func encodedImage(mime: String, type: UTType, width: Int = 32, height: Int = 16) throws -> String {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return "data:\(mime);base64," + (data as Data).base64EncodedString()
    }
}

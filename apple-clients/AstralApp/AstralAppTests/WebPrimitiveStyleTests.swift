import AstralCore
import SwiftUI
import XCTest

@testable import AstralDeep

@MainActor
final class WebPrimitiveStyleTests: XCTestCase {
    private func render(_ json: String, viewport: CGFloat = 411, preset: String = "midnight") throws -> CGImage {
        let model = AppModel()
        let theme = ThemeStore()
        theme.apply(preset: preset)
        let component = try XCTUnwrap(AstralComponent(json: JSONValue.parse(Data(json.utf8))))
        let renderer = ImageRenderer(
            content:
                ComponentView(component: component)
                .environment(model).environment(theme)
                .environment(\.astralViewportWidth, viewport)
                .frame(width: 320).padding(20).background(theme.palette.bg)
                .environment(\.dynamicTypeSize, .large)
        )
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private func rgb(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: CGFloat(-x), y: CGFloat(y + 1 - image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixel.prefix(3).map(Int.init)
    }

    private func assertRGB(_ actual: [Int], _ expected: [Int], file: StaticString = #filePath, line: UInt = #line) {
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(Double(a), Double(e), accuracy: 3, file: file, line: line)
        }
    }

    func testCardUsesWebTranslucencyWithoutPaintingShadowInsideInBothThemes() throws {
        for (preset, expected) in [("midnight", [20, 23, 39]), ("daylight", [251, 252, 253])] {
            let image = try render(#"{"type":"card","content":[]}"#, preset: preset)
            assertRGB(try rgb(image, x: 180, y: image.height / 2), expected)
            let attachment = XCTAttachment(image: platformImage(image))
            attachment.name = "088-apple-card-\(preset)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testCardPaddingFollowsViewportEvenInNarrowGridSlot() throws {
        let compact = try render(#"{"type":"card","content":[]}"#, viewport: 699)
        let wide = try render(#"{"type":"card","content":[]}"#, viewport: 700)
        XCTAssertEqual(compact.width, wide.width)
        XCTAssertEqual(wide.height - compact.height, 8)
    }

    func testMetricRendersCanonicalTitleVariantEdgeAndClampedProgress() throws {
        let image = try render(
            #"{"type":"metric","title":"Total","value":18,"subtitle":"Six dice","variant":"success","progress":2}"#)
        // The green variant edge and red full progress bar have separate meanings.
        assertRGB(try rgb(image, x: 21, y: image.height / 2), [32, 172, 84])
        assertRGB(try rgb(image, x: 300, y: image.height - 40), [239, 68, 68])
        let empty = try render(#"{"type":"metric","title":"Total","value":18,"progress":-1}"#)
        let noProgress = try render(#"{"type":"metric","title":"Total","value":18}"#)
        XCTAssertEqual(empty.height - noProgress.height, 18)
        let unknown = try render(#"{"type":"metric","title":"Total","value":18,"variant":"accent"}"#)
        let ordinary = try render(#"{"type":"metric","title":"Total","value":18}"#)
        XCTAssertEqual(
            try rgb(unknown, x: 21, y: unknown.height / 2),
            try rgb(ordinary, x: 21, y: ordinary.height / 2))
        let attachment = XCTAttachment(image: platformImage(image))
        attachment.name = "088-apple-metric-variant-progress"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNewChatKeepsNativeTargetAndOnlyAddsVisibleLabelAtWebBreakpoint() throws {
        var widths: [Int] = []
        for viewport: CGFloat in [639, 640] {
            let renderer = ImageRenderer(
                content:
                    AstralNewChatButton(viewportWidth: viewport, palette: .midnight, action: {})
                    .fixedSize().background(AstralPalette.midnight.surface)
                    .environment(\.dynamicTypeSize, .large)
            )
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertGreaterThanOrEqual(image.height, 44)
            XCTAssertGreaterThanOrEqual(image.width, 44)
            widths.append(image.width)
            // A corner inside the outline remains the unfilled top-bar color.
            assertRGB(try rgb(image, x: 8, y: image.height / 2), [26, 30, 46])
        }
        XCTAssertGreaterThan(widths[1], widths[0] + 40)
    }

    #if os(iOS)
        private func platformImage(_ image: CGImage) -> UIImage { UIImage(cgImage: image) }
    #else
        private func platformImage(_ image: CGImage) -> NSImage {
            NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    #endif
}

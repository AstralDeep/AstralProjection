// Tests for web-parity primitive styling (ComponentView.swift): card translucency and padding, metric variant
// colors and clamped progress, and the New Chat button's native target at the web breakpoint.

import AstralCore
import SwiftUI
import Vision
import XCTest

@testable import AstralDeep

@MainActor
final class WebPrimitiveStyleTests: XCTestCase {
    private func render(
        _ json: String, viewport: CGFloat = 411, preset: String = "graphite",
        width: CGFloat = 320, textSize: DynamicTypeSize = .large
    ) throws -> CGImage {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        let theme = ThemeStore()
        theme.apply(preset: preset)
        let component = try XCTUnwrap(AstralComponent(json: JSONValue.parse(Data(json.utf8))))
        let renderer = ImageRenderer(
            content:
                ComponentView(component: component)
                .environment(model).environment(theme)
                .environment(\.astralViewportWidth, viewport)
                .frame(width: width).padding(20).background(theme.palette.bg)
                .environment(\.dynamicTypeSize, textSize)
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
        for (preset, expected) in [
            ("graphite", [22, 22, 25]), ("midnight", [20, 23, 39]), ("daylight", [251, 252, 253]),
        ] {
            let image = try render(#"{"type":"card","content":[]}"#, preset: preset)
            assertRGB(try rgb(image, x: 180, y: image.height / 2), expected)
            let attachment = XCTAttachment(image: platformImage(image))
            attachment.name = "088-apple-card-\(preset)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testCodeUsesPaletteSuccessOnSurface2AndMarkdownFencesUseSurface2() throws {
        let code = try render(#"{"type":"code","content":"ok"}"#)
        assertRGB(try rgb(code, x: 300, y: code.height / 2), [35, 35, 40])
        #if os(macOS)
            let model = AppModel(tokenStore: InMemoryTokenStore())
            let theme = ThemeStore()
            let component = try XCTUnwrap(
                AstralComponent(json: JSONValue.parse(Data(#"{"type":"code","content":"OK OK OK"}"#.utf8))))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 360, height: 100), styleMask: .borderless,
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = NSHostingView(
                rootView: ComponentView(component: component).environment(model).environment(theme)
                    .frame(width: 320).padding(20).background(theme.palette.bg))
            window.contentView = view
            defer {
                window.contentView = nil
                window.close()
            }
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            var brightest = [0.0, 0.0, 0.0]
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if color.greenComponent * 255 > brightest[1] {
                        brightest = [color.redComponent, color.greenComponent, color.blueComponent].map { $0 * 255 }
                    }
                }
            }
            XCTAssertEqual(brightest[1], 194, accuracy: 12)
            XCTAssertGreaterThan(brightest[1], brightest[0] + 40)
            XCTAssertGreaterThan(brightest[1], brightest[2] + 20)
        #endif
        let fence = try render(#"{"type":"text","variant":"markdown","content":"```\nok\n```"}"#)
        assertRGB(try rgb(fence, x: 300, y: fence.height / 2), [35, 35, 40])
        let midnight = try render(#"{"type":"code","content":"ok"}"#, preset: "midnight")
        assertRGB(try rgb(midnight, x: 300, y: midnight.height / 2), [30, 35, 56])
    }

    private func recognized(_ image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    func testUploadHintEmptyHistoryAndUntitledWelcomeDisclosureDrawNoHelperCopy() throws {
        let upload = try recognized(render(#"{"type":"file_upload","label":"Quarterly report"}"#))
        XCTAssertTrue(upload.contains { $0.contains("Quarterly report") })
        XCTAssertFalse(upload.contains { $0.contains("paperclip") || $0.contains("chat input") })
        XCTAssertTrue(try recognized(render(#"{"type":"chat_history","items":[]}"#)).isEmpty)
        let more = try recognized(
            render(
                #"{"type":"collapsible","title":"","data-welcome":"more","aria-label":"More examples","content":[]}"#))
        XCTAssertFalse(more.contains { $0.contains("More examples") || $0.contains("Details") })
        let details = try recognized(render(#"{"type":"collapsible","title":"","content":[]}"#))
        XCTAssertTrue(details.contains { $0.contains("Details") })
    }

    func testCardPaddingFollowsViewportEvenInNarrowGridSlot() throws {
        let compact = try render(#"{"type":"card","content":[]}"#, viewport: 699)
        let wide = try render(#"{"type":"card","content":[]}"#, viewport: 700)
        XCTAssertEqual(compact.width, wide.width)
        XCTAssertEqual(wide.height - compact.height, 8)
    }

    func testServerPaletteSwatchesPaintAllColorsAtTheSpecifiedPreviewHeight() throws {
        let image = try render(
            ##"{"type":"container","direction":"row","children":[{"type":"container","css":{"background":"#123ABC","height":"32px"}},{"type":"container","css":{"background":"#12BC3A","height":"32px"}},{"type":"container","css":{"background":"#BC123A","height":"32px"}}]}"##
        )
        XCTAssertEqual(image.height, 72)
        assertRGB(try rgb(image, x: 60, y: 36), [18, 58, 188])
        assertRGB(try rgb(image, x: 180, y: 36), [18, 188, 58])
        assertRGB(try rgb(image, x: 300, y: 36), [188, 18, 58])
    }

    func testMetricRendersCanonicalTitleVariantEdgeAndClampedProgress() throws {
        let image = try render(
            #"{"type":"metric","title":"Total","value":18,"subtitle":"Six dice","variant":"success","progress":2}"#)
        assertRGB(try rgb(image, x: 21, y: image.height / 2), [84, 171, 127])
        assertRGB(try rgb(image, x: 300, y: image.height - 40), [224, 108, 108])
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
                    AstralNewChatButton(viewportWidth: viewport, palette: .graphite, action: {})
                    .fixedSize().background(AstralPalette.graphite.surface)
                    .environment(\.dynamicTypeSize, .large)
            )
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertGreaterThanOrEqual(image.height, 44)
            XCTAssertGreaterThanOrEqual(image.width, 44)
            widths.append(image.width)
            assertRGB(try rgb(image, x: 8, y: image.height / 2), [27, 27, 31])
        }
        XCTAssertGreaterThan(widths[1], widths[0] + 40)
    }

    func testCompositeRenderersPreserveVisibleContentInBothThemes() throws {
        let components = [
            #"{"type":"action_group","label":"Actions","align":"between","buttons":[{"label":"Run","action":"chat","variant":"primary"},{"label":"Details","action":"open","variant":"secondary","disabled":true}]}"#,
            #"{"type":"stat_group","title":"Overview","columns":3,"items":[{"label":"Revenue","value":"$120","delta":"+12%","trend":"up","variant":"success","hint":"Today"},{"label":"Errors","value":"0","delta":"-2","trend":"down","variant":"error"},{"label":"Stable","value":"12","trend":"flat","delta":"0","variant":"invalid"}]}"#,
            #"{"type":"gauge","label":"Capacity","value":0.75,"subtitle":"Available","thresholds":[{"at":0.5,"variant":"warning"}]}"#,
            #"{"type":"pipeline_stepper","title":"Process","steps":[{"label":"Load","status":"done"},{"label":"Validate","status":"active","detail":"Check all values"},{"label":"Deliver","status":"pending"},{"label":"Recover","status":"error"}]}"#,
            #"{"type":"donut_chart","title":"Shares","labels":["A","B","C","D","E","F","G"],"data":[10,20,10,10,20,20,10],"center_label":"Total","center_value":"100"}"#,
            #"{"type":"radar_chart","title":"Quality","axes":["Speed","Accuracy","Cost"],"datasets":[{"label":"One","data":[1,2,3]},{"label":"Two","data":[2,3,1]},{"label":"Three","data":[3,1,2]},{"label":"Four","data":[2,2,2]}]}"#,
        ]
        for preset in ["graphite", "midnight", "daylight"] {
            for (index, component) in components.enumerated() {
                let image = try render(component, preset: preset)
                XCTAssertEqual(image.width, 360)
                XCTAssertGreaterThan(image.height, 60)
                XCTAssertLessThan(image.height, 900)
                let attachment = XCTAttachment(image: platformImage(image))
                attachment.name = "composite-\(index)-\(preset)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testMalformedAndEmptyCompositesRemainBounded() throws {
        for type in ["action_group", "stat_group", "gauge", "pipeline_stepper", "donut_chart", "radar_chart"] {
            let image = try render(
                "{\"type\":\"\(type)\",\"data\":[],\"items\":[null],\"buttons\":[false],\"steps\":[3],\"axes\":[],\"value\":\"NaN\"}"
            )
            XCTAssertEqual(image.width, 360)
            XCTAssertLessThan(image.height, 300)
        }
        for alignment in ["start", "center", "end", "between", "invalid"] {
            let image = try render(
                "{\"type\":\"action_group\",\"align\":\"\(alignment)\",\"buttons\":[{\"label\":\"A very long action with enough words to wrap safely within the available space on phones\",\"action\":\"open\"},{\"label\":\"Continue\",\"action\":\"continue\"}]}"
            )
            XCTAssertEqual(image.width, 360)
            XCTAssertLessThan(image.height, 400)
        }
    }

    func testStatisticCellsStretchToTheSameRowHeight() throws {
        let image = try render(
            #"{"type":"stat_group","title":"Overview","columns":2,"items":[{"label":"First","value":"12","hint":"Extra detail"},{"label":"Second","value":"0"}]}"#
        )
        let first = try rgb(image, x: 26, y: 57)
        let second = try rgb(image, x: 194, y: 57)
        assertRGB(first, second)
        XCTAssertNotEqual(first, [15, 18, 33])
    }

    func testCompositeNarrowSlotsAndAccessibleTextKeepAllContentReachable() throws {
        for raw in [
            #"{"type":"action_group","label":"A longer group label","buttons":[{"label":"An action with a long description that must wrap","action":"open"},{"label":"Continue","action":"go"}]}"#,
            #"{"type":"stat_group","columns":1,"items":[{"label":"Measurements today","value":"123456789","hint":"All values remain visible with enlarged text"}]}"#,
            #"{"type":"gauge","label":"Capacity remaining","value":0.5,"subtitle":"Available right now"}"#,
            #"{"type":"pipeline_stepper","orientation":"vertical","steps":[{"label":"A lengthy current step","status":"active","detail":"Read every detail of the operation"},{"label":"The next operation","status":"pending"}]}"#,
            #"{"type":"donut_chart","labels":["A lengthy first group","A lengthy second group"],"data":[1,2],"center_value":"3","center_label":"Total"}"#,
            #"{"type":"radar_chart","axes":["A","B","C"],"datasets":[{"label":"A lengthy dataset title with details","data":[1,2,3]}]}"#,
        ] {
            let ordinary = try render(raw, width: 144)
            let accessible = try render(raw, width: 144, textSize: .accessibility3)
            XCTAssertEqual(ordinary.width, 184)
            XCTAssertEqual(accessible.width, 184)
            XCTAssertGreaterThanOrEqual(accessible.height, ordinary.height)
            XCTAssertLessThan(accessible.height, 1800)
        }
    }

    func testTypographyRemainsVisibleAcrossExistingPrimitiveVocabulary() throws {
        let samples = [
            #"{"type":"badge","label":"Live"}"#,
            #"{"type":"hero","title":"Report","subtitle":"Details","eyebrow":"Today","badges":["One"]}"#,
            #"{"type":"timeline","title":"Process","items":[{"time":"Now","title":"Started","description":"Current operation"}]}"#,
            #"{"type":"rating","label":"Quality","value":4,"subtitle":"Total ratings"}"#,
            #"{"type":"code","code":"print(1)"}"#,
            #"{"type":"progress","label":"Working","value":0.5}"#,
            #"{"type":"file_upload","label":"Upload"}"#,
            #"{"type":"unknown","title":"Readable fallback"}"#,
        ]
        for sample in samples {
            let image = try render(sample)
            XCTAssertEqual(image.width, 360)
            XCTAssertGreaterThan(image.height, 40)
        }
    }

    func testGaugeAndPipelineReflectUpdatesWithoutChangingIdentity() throws {
        let low = try render(#"{"type":"gauge","id":"capacity","value":0.1}"#)
        let high = try render(#"{"type":"gauge","id":"capacity","value":0.9}"#)
        XCTAssertNotEqual(low.dataProvider?.data as Data?, high.dataProvider?.data as Data?)
        let horizontal = try render(
            #"{"type":"pipeline_stepper","steps":[{"label":"First","status":"done"},{"label":"Next","status":"active"}]}"#
        )
        let vertical = try render(
            #"{"type":"pipeline_stepper","orientation":"vertical","steps":[{"label":"First","status":"done"},{"label":"Next","status":"active"}]}"#
        )
        XCTAssertGreaterThan(vertical.height, horizontal.height)
    }

    #if os(iOS)
        private func platformImage(_ image: CGImage) -> UIImage { UIImage(cgImage: image) }
    #else
        private func platformImage(_ image: CGImage) -> NSImage {
            NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    #endif
}

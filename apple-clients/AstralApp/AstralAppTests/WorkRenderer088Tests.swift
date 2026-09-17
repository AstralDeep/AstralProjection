import AstralCore
import SwiftUI
import XCTest

#if os(watchOS)
    @testable import AstralWatch
#else
    @testable import AstralDeep
#endif

@MainActor
final class WorkRenderer088Tests: XCTestCase {
    private let generation = "33333333-3333-4333-8333-333333333333"

    private func png<V: View>(_ view: V, width: CGFloat = 240) throws -> Data {
        let renderer = ImageRenderer(content: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
        #if os(macOS)
            return try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
        #else
            return try XCTUnwrap(renderer.uiImage?.pngData())
        #endif
    }

    func testMaximumRetainedExcerptRendersEveryCharacterAsNativeLiteralText() throws {
        let excerpt = "**[" + String(repeating: "x", count: 8186) + "]**"
        XCTAssertEqual(excerpt.utf8.count, 8192)
        let component = AstralComponent(
            json: .object([
                "type": .string("text"), "content": .string(excerpt), "variant": .string("body"),
            ]))!
        #if os(watchOS)
            let model = WatchModel()
            let actual = try png(WatchComponentView(component: component, workRead: true).environment(model))
            let expected = try png(
                Text(verbatim: excerpt).font(AstralTypography.footnote).fixedSize(horizontal: false, vertical: true))
            let interpreted = try png(WatchComponentView(component: component).environment(model))
        #else
            let model = AppModel(
                tokenStore: InMemoryTokenStore(), defaults: UserDefaults(suiteName: "WorkRenderer088Tests.literal")!)
            let theme = ThemeStore()
            let actual = try png(
                ComponentView(component: component).environment(model).environment(theme).environment(
                    \.astralWorkReadSurface, true))
            let expected = try png(
                Text(verbatim: excerpt).font(AstralTypography.body).foregroundStyle(theme.palette.text)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(
                        maxWidth: .infinity, alignment: .leading))
            let interpreted = try png(ComponentView(component: component).environment(model).environment(theme))
        #endif
        XCTAssertEqual(actual, expected)
        XCTAssertNotEqual(actual, interpreted)
    }

    func testActualWorkSurfaceRendersNestedEvidenceReadButtonsAndUnavailableState() throws {
        let components: [JSONValue] = [
            .object([
                "type": .string("card"), "variant": .string("default"),
                "title": .string("**Source** [title](https://example.test)"),
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "content": .string("# Exact [excerpt](https://example.test) <b>literal</b>"),
                        "variant": .string("h3"),
                    ]),
                    .object([
                        "type": .string("text"), "content": .string("Attribution and completeness"),
                        "variant": .string("caption"),
                    ]),
                    .object([
                        "type": .string("alert"), "title": .string("**Incomplete**"),
                        "message": .string("Original *markers* remain"), "variant": .string("warning"),
                    ]),
                    .object([
                        "type": .string("button"), "variant": .string("secondary"), "label": .string("Refresh"),
                        "action": .string("chrome_open"),
                        "disabled": .bool(false), "local": .bool(false),
                        "payload": .object(["surface": .string("work"), "params": .object(["mode": .string("list")])]),
                    ]),
                ]),
            ])
        ]
        let frame = InboundFrame(
            name: "chrome_surface",
            payload: .object([
                "type": .string("chrome_surface"), "surface_key": .string("work"), "region": .string("modal"),
                "title": .string("Retained evidence"), "mode": .string("replace"), "admin_only": .bool(false),
                "request_generation": .string(generation), "components": .array(components),
            ]))
        let request = WorkReadRequest(
            payload: .object(["surface": .string("work"), "params": .object(["mode": .string("list")])]))!
        #if os(watchOS)
            let model = WatchModel()
            model.bindConversationAccount(ConversationAccount(issuer: "https://iam.example.test", subject: "owner")!)
            model.connected = true
            model.workVisible = true
            model.workReadState.begin(request, generation: generation)
            model.handleFrame(frame)
            XCTAssertNotNil(model.workUpdate)
            let displayed = try png(WatchWorkSurfaceView().environment(model))
            model.workUpdate = nil
            model.workReadFailed = true
            let failed = try png(WatchWorkSurfaceView().environment(model))
        #else
            let suite = "WorkRenderer088Tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(tokenStore: InMemoryTokenStore(), defaults: defaults)
            let theme = ThemeStore()
            model.signedIn = true
            model.connected = true
            model.bindConversationAccount(ConversationAccount(issuer: "https://iam.example.test", subject: "owner")!)
            model.screen = .surface
            model.pendingSurfaceKey = "work"
            model.workReadState.begin(request, generation: generation)
            model.handleFrame(frame)
            XCTAssertNotNil(model.pendingSurface)
            let displayed = try png(SurfaceView().environment(model).environment(theme))
            model.pendingSurface = nil
            model.workReadFailed = true
            let failed = try png(SurfaceView().environment(model).environment(theme))
        #endif
        XCTAssertGreaterThan(displayed.count, 500)
        XCTAssertGreaterThan(failed.count, 500)
        XCTAssertNotEqual(displayed, failed)
    }
}

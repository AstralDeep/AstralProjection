// Tests for the notes-surface renderer: full multibyte note text and every shared form state render
// literally, and instructions stay scoped to their own form.

import AstralCore
import SwiftUI
import XCTest

#if os(watchOS)
    @testable import AstralWatch
#else
    @testable import AstralDeep
#endif

@MainActor
final class GuidanceRenderer088Tests: XCTestCase {
    private func image<V: View>(_ view: V, width: CGFloat = 240) throws -> Data {
        let renderer = ImageRenderer(content: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
        #if os(macOS)
            return try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
        #else
            return try XCTUnwrap(renderer.uiImage?.pngData())
        #endif
    }
    func testFullMultibyteNoteIsLiteralAndEverySharedFormStateRenders() throws {
        let text = "**[" + String(repeating: "🙂", count: 1022) + "]**xx"
        XCTAssertEqual(text.utf8.count, 4096)
        let component = AstralComponent(
            json: .object(["type": .string("text"), "content": .string(text), "variant": .string("body")]))!
        #if os(watchOS)
            let model = WatchModel()
            let actual = try image(WatchComponentView(component: component, guidance: true).environment(model))
            let expected = try image(
                Text(verbatim: text).font(AstralTypography.footnote).fixedSize(horizontal: false, vertical: true))
        #else
            let suite = "GuidanceRenderer088.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(tokenStore: InMemoryTokenStore(), defaults: defaults)
            let theme = ThemeStore()
            let actual = try image(
                ComponentView(component: component).environment(model).environment(theme).environment(
                    \.astralWorkReadSurface, true
                ).environment(\.astralGuidanceSurface, true))
            let expected = try image(
                Text(verbatim: text).font(ConsoleTypography.body).foregroundStyle(theme.palette.text).textSelection(
                    .enabled
                ).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading))
            model.signedIn = true
        #endif
        XCTAssertEqual(actual, expected)
        model.connected = true
        model.bindConversationAccount(ConversationAccount(issuer: "https://iam.example.test", subject: "owner")!)
        let frames = try JSONValue.parse(Data(Self.frames.utf8)).objectValue!
        var pictures: Set<Data> = []
        for mode in ["list", "new", "edit", "forget"] {
            let fields = frames[mode]!
            let generation = fields["request_generation"]!.stringValue!
            #if os(watchOS)
                model.guidanceVisible = true
            #else
                model.screen = .surface
                model.pendingSurfaceKey = "guidance"
            #endif
            XCTAssertTrue(model.guidanceState.begin(.list, generation: generation))
            model.handleFrame(InboundFrame(name: "chrome_surface", payload: fields))
            XCTAssertNotNil(model.guidanceUpdate)
            #if os(watchOS)
                let rendered = try image(WatchGuidanceSurfaceView().environment(model))
            #else
                let rendered = try image(SurfaceView().environment(model).environment(theme))
            #endif
            XCTAssertGreaterThan(rendered.count, 500)
            pictures.insert(rendered)
        }
        XCTAssertEqual(pictures.count, 4)
    }

    func testLiteralFormInstructionsAndOrdinaryFormDispositionRemainScoped() throws {
        var raw = try JSONValue.parse(Data(Self.frames.utf8))["edit"]!["components"]!.arrayValue!.last!.objectValue!
        raw["description"] = .string("**Keep** <b>these instructions</b> [literal](https://example.invalid)")
        let component = AstralComponent(json: .object(raw))!
        #if os(watchOS)
            let model = WatchModel()
            let notes = try image(WatchComponentView(component: component, guidance: true).environment(model))
            let ordinary = try image(WatchComponentView(component: component).environment(model))
            XCTAssertNotEqual(notes, ordinary)
            XCTAssertGreaterThan(ordinary.count, 500)
        #else
            let suite = "GuidanceRenderer088.instructions.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(tokenStore: InMemoryTokenStore(), defaults: defaults)
            let theme = ThemeStore()
            let notes = try image(
                ComponentView(component: component).environment(model).environment(theme).environment(
                    \.astralGuidanceSurface, true))
            let ordinary = try image(ComponentView(component: component).environment(model).environment(theme))
            XCTAssertNotEqual(notes, ordinary)
            let empty = AstralComponent(
                json: .object([
                    "type": .string("param_picker"),
                    "fields": .array([
                        .object([
                            "name": .string("unavailable"), "label": .string("Unavailable option"),
                            "kind": .string("select"), "options": .array([]),
                        ])
                    ]),
                ]))!
            XCTAssertGreaterThan(
                try image(ComponentView(component: empty).environment(model).environment(theme)).count, 500)
        #endif
        XCTAssertGreaterThan(notes.count, 500)
    }

    private static let frames =
        #"{"list":{"type":"chrome_surface","region":"modal","surface_key":"guidance","title":"Private notes","admin_only":false,"components":[{"type":"text","content":"Private notes are guidance you can select for your work.","variant":"body"},{"type":"button","label":"Add note","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"new"}},"variant":"secondary","disabled":false,"local":false},{"type":"param_picker","title":"","description":"","fields":[{"name":"search","label":"Search notes","kind":"text","default":""}],"submit_label":"Search","submit_action":"chrome_note_search","submit_payload":{}},{"type":"card","title":"Preference","content":[{"type":"badge","label":"Enabled","variant":"default"},{"type":"text","content":"Use complete source text: **literal** <script>alert(1)</script> https://example.invalid/private","variant":"body"},{"type":"text","content":"No expiry","variant":"caption"},{"type":"button","label":"Edit","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"edit","note_id":"5106d0c8-09a0-47cf-910f-0cc1408b73a4","expected_revision":3}},"variant":"secondary","disabled":false,"local":false},{"type":"button","label":"Disable","action":"chrome_note_toggle","payload":{"note_id":"5106d0c8-09a0-47cf-910f-0cc1408b73a4","expected_revision":3,"enabled":false},"variant":"secondary","disabled":false,"local":false},{"type":"button","label":"Forget","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"forget","note_id":"5106d0c8-09a0-47cf-910f-0cc1408b73a4","expected_revision":3}},"variant":"secondary","disabled":false,"local":false}],"variant":"default"},{"type":"button","label":"Refresh","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"list","search":""}},"variant":"secondary","disabled":false,"local":false}],"mode":"replace","request_generation":"8c7c08ee-0d23-43db-9156-ea3e4e729f89"},"new":{"type":"chrome_surface","region":"modal","surface_key":"guidance","title":"Private notes","admin_only":false,"components":[{"type":"button","label":"Back to notes","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"list"}},"variant":"secondary","disabled":false,"local":false},{"type":"param_picker","title":"Add note","description":"","fields":[{"name":"category","label":"Category","kind":"select","default":"Context","options":["Profession","Goal","Preference","Workflow tag","Context"]},{"name":"value","label":"Note","kind":"textarea","default":"","help":"Describe your preferences or context. Do not include patient information."},{"name":"enabled","label":"Enabled","kind":"boolean","default":true},{"name":"expiry","label":"Expiry","kind":"select","default":"No expiry","options":["No expiry","Set a date"]},{"name":"expiry_date","label":"Expiry date (UTC)","kind":"text","default":"","help":"Use a UTC date and time, for example 2026-12-31T23:59:00Z.","visible_when":{"expiry":"Set a date"}}],"submit_label":"Save note","submit_action":"chrome_note_save","submit_payload":{"note_id":"0fe0d7ba-812a-4881-9f61-77e23327d492","expected_revision":0}}],"mode":"replace","request_generation":"8c7c08ee-0d23-43db-9156-ea3e4e729f89"},"edit":{"type":"chrome_surface","region":"modal","surface_key":"guidance","title":"Private notes","admin_only":false,"components":[{"type":"button","label":"Back to notes","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"list"}},"variant":"secondary","disabled":false,"local":false},{"type":"text","content":"Current note","variant":"h3"},{"type":"badge","label":"Enabled","variant":"default"},{"type":"text","content":"Use complete source text: **literal** <script>alert(1)</script> https://example.invalid/private","variant":"body"},{"type":"text","content":"No expiry","variant":"caption"},{"type":"param_picker","title":"Edit note","description":"","fields":[{"name":"category","label":"Category","kind":"select","default":"Preference","options":["Profession","Goal","Preference","Workflow tag","Context"]},{"name":"value","label":"Note","kind":"textarea","default":"Use complete source text: **literal** <script>alert(1)</script> https://example.invalid/private","help":"Describe your preferences or context. Do not include patient information."},{"name":"enabled","label":"Enabled","kind":"boolean","default":true},{"name":"expiry","label":"Expiry","kind":"select","default":"Keep current expiry","options":["Keep current expiry","No expiry","Set a date"]},{"name":"expiry_date","label":"Expiry date (UTC)","kind":"text","default":"","help":"Use a UTC date and time, for example 2026-12-31T23:59:00Z.","visible_when":{"expiry":"Set a date"}}],"submit_label":"Save note","submit_action":"chrome_note_save","submit_payload":{"note_id":"5106d0c8-09a0-47cf-910f-0cc1408b73a4","expected_revision":3}}],"mode":"replace","request_generation":"8c7c08ee-0d23-43db-9156-ea3e4e729f89"},"forget":{"type":"chrome_surface","region":"modal","surface_key":"guidance","title":"Private notes","admin_only":false,"components":[{"type":"button","label":"Keep note","action":"chrome_open","payload":{"surface":"guidance","params":{"mode":"list"}},"variant":"secondary","disabled":false,"local":false},{"type":"card","title":"Preference","content":[{"type":"badge","label":"Enabled","variant":"default"},{"type":"text","content":"Use complete source text: **literal** <script>alert(1)</script> https://example.invalid/private","variant":"body"},{"type":"text","content":"No expiry","variant":"caption"}],"variant":"default"},{"type":"alert","message":"Forget permanently erases this note's current value. This cannot be undone.","variant":"warning"},{"type":"button","label":"Forget note","action":"chrome_note_forget","payload":{"note_id":"5106d0c8-09a0-47cf-910f-0cc1408b73a4","expected_revision":3},"variant":"danger","disabled":false,"local":false}],"mode":"replace","request_generation":"8c7c08ee-0d23-43db-9156-ea3e4e729f89"}}"#
}

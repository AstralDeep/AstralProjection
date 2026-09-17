import AstralCore
import SwiftUI
import XCTest

@testable import AstralDeep

@MainActor
final class AppWorkSurface088Tests: XCTestCase {
    private var suites: [String] = []
    private let first = "33333333-3333-4333-8333-333333333333"
    private let second = "44444444-4444-4444-8444-444444444444"

    func testWorkAlertEvidenceRendersAsLiteralTextIncludingLinkAndHTMLSyntax() throws {
        let evidence = "[Source](https://example.test/read) **exact** <script>alert(1)</script>\nSecond line"
        func rendered<V: View>(_ view: V) throws -> Data {
            let renderer = ImageRenderer(
                content: view.environment(ThemeStore()).font(.system(size: 16)).frame(width: 360).padding(8))
            #if os(iOS)
                return try XCTUnwrap(renderer.uiImage?.pngData())
            #else
                return try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
            #endif
        }
        let actual = try rendered(ComponentAlertMessage(text: evidence, literal: true))
        let expected = try rendered(Text(verbatim: evidence).fixedSize(horizontal: false, vertical: true))
        XCTAssertEqual(actual, expected)
        XCTAssertNotEqual(actual, try rendered(ComponentAlertMessage(text: evidence, literal: false)))
    }

    private func model() -> AppModel {
        let suite = "AppWorkSurface088Tests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(
            conversationResumeStore: ConversationResumeStore(defaults: defaults),
            tokenStore: InMemoryTokenStore(), defaults: defaults)
        model.signedIn = true
        model.connected = true
        model.bindConversationAccount(ConversationAccount(issuer: "https://iam.example.test", subject: "owner")!)
        model.screen = .surface
        model.pendingSurfaceKey = "work"
        model.pendingSurfaceParams = .object(["mode": .string("list")])
        return model
    }

    private func frame(_ generation: JSONValue) -> InboundFrame {
        InboundFrame(
            name: "chrome_surface",
            payload: .object([
                "type": .string("chrome_surface"), "surface_key": .string("work"), "region": .string("modal"),
                "title": .string("Server title"), "mode": .string("replace"), "admin_only": .bool(false),
                "request_generation": generation,
                "components": .array([
                    .object([
                        "type": .string("text"), "content": .string("Exact **excerpt**"), "variant": .string("body"),
                    ])
                ]),
            ]))
    }

    private func begin(_ model: AppModel, _ generation: String) {
        let request = WorkReadRequest(
            payload: .object(["surface": .string("work"), "params": model.pendingSurfaceParams]))!
        XCTAssertTrue(model.workReadState.begin(request, generation: generation))
    }

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites.removeAll()
        super.tearDown()
    }

    func testOnlyCurrentWorkResponsePaintsWithoutCanvasOrFallbackBanner() {
        let model = model()
        model.canvas = [AstralComponent(type: "text", raw: .object(["content": .string("Original canvas")]))]
        let canvas = model.canvas
        begin(model, first)
        model.handleFrame(frame(.string(second)))
        model.handleFrame(frame(.null))
        XCTAssertNil(model.pendingSurface)
        XCTAssertNil(model.errorBanner)
        model.handleFrame(frame(.string(first)))
        XCTAssertEqual(model.pendingSurface?.title, "Server title")
        XCTAssertEqual(model.canvas, canvas)
        begin(model, second)
        model.pendingSurface = nil
        model.handleFrame(frame(.string(first)))
        XCTAssertNil(model.pendingSurface)
        model.closeSurface()
        model.handleFrame(frame(.string(second)))
        XCTAssertEqual(model.screen, .chat)
        XCTAssertNil(model.pendingSurface)
        XCTAssertNil(model.errorBanner)
    }

    func testDisconnectedAndChangedOwnerInvalidatesPendingWorkWithoutReplaying() async {
        for ownerChange in [false, true] {
            let model = model()
            begin(model, first)
            if ownerChange {
                model.bindConversationAccount(
                    ConversationAccount(issuer: "https://iam.example.test", subject: "other")!)
            } else {
                await model.handle(.disconnected(reason: "synthetic"))
            }
            XCTAssertNil(model.workReadState.generation)
            model.handleFrame(frame(.string(first)))
            XCTAssertNil(model.pendingSurface)
            XCTAssertTrue(model.localOperationSubmissions.isEmpty)
        }
    }

    func testDuplicateWorkResponseCannotReplaceOrCloseAcceptedContent() {
        let model = model()
        begin(model, first)
        model.handleFrame(frame(.string(first)))
        XCTAssertNil(model.workReadState.generation)
        var duplicate = frame(.string(first))
        var payload = duplicate.payload.objectValue!
        payload["title"] = .string("Late replacement")
        duplicate = InboundFrame(name: "chrome_surface", payload: .object(payload))
        model.handleFrame(duplicate)
        XCTAssertEqual(model.pendingSurface?.title, "Server title")
        payload["components"] = .array([])
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(payload)))
        XCTAssertEqual(model.screen, .surface)
        XCTAssertEqual(model.pendingSurface?.title, "Server title")
    }

    func testLegacyFramesCannotOverwritePendingOrDisplayedWorkUntilExplicitNavigation() {
        let legacy = [
            #"{"type":"chrome_surface","surface_key":"","components":[],"mode":"replace"}"#,
            #"{"type":"chrome_surface","surface_key":"llm","title":"Setup","components":[{"type":"text","content":"Configure"}],"mode":"mandatory"}"#,
            #"{"type":"chrome_surface","surface_key":"theme","title":"Late theme","components":[{"type":"text","content":"Notice"}],"mode":"replace"}"#,
        ]
        for displayed in [false, true] {
            for raw in legacy {
                let model = model()
                begin(model, first)
                if displayed { model.handleFrame(frame(.string(first))) }
                model.handleFrame(InboundFrame.parse(raw)!)
                XCTAssertEqual(model.screen, .surface)
                XCTAssertEqual(model.pendingSurfaceKey, "work")
                XCTAssertFalse(model.mandatorySurface)
                XCTAssertNil(model.errorBanner)
                XCTAssertEqual(model.pendingSurface?.title, displayed ? "Server title" : nil)
                model.openSurface("llm")
                model.handleFrame(InboundFrame.parse(legacy[1])!)
                XCTAssertTrue(model.mandatorySurface)
                XCTAssertEqual(model.pendingSurfaceKey, "llm")
            }
        }
    }

    func testAdmissionRefusalRetiresWorkTicketWithoutQueueing() {
        let model = model()
        model.connected = false
        model.retryPendingSurface()
        XCTAssertTrue(model.workReadFailed)
        XCTAssertNil(model.workReadState.generation)
        XCTAssertTrue(model.localOperationSubmissions.isEmpty)
    }
    func testTimeoutOrSendFailureRetiresOnlyCurrentTicketAndKeepsRetrySelection() {
        let model = model()
        begin(model, first)
        model.failWorkRead(generation: second)
        XCTAssertEqual(model.workReadState.generation, first)
        model.failWorkRead(generation: first)
        XCTAssertNil(model.workReadState.generation)
        XCTAssertTrue(model.workReadFailed)
        model.handleFrame(frame(.string(first)))
        XCTAssertNil(model.pendingSurface)
        model.handleFrame(
            InboundFrame.parse(
                #"{"type":"chrome_surface","surface_key":"llm","title":"Late","components":[],"mode":"mandatory"}"#)!)
        XCTAssertNil(model.pendingSurface)
        XCTAssertTrue(model.workReadFailed)
    }

    func testMatchingAdmissionRefusalRetiresPrivateReadBeforeGenericErrorHandling() {
        let model = model()
        begin(model, first)
        let request = model.workReadState.request!
        let text = request.frameText(requestGeneration: first)
        XCTAssertTrue(model.workReadState.bindSubmission(frameText: text))
        let submission = model.workReadState.submissionId!
        let refusal = InboundFrame.parse(
            """
            {"type":"error","submission_id":"\(submission)","accepted":false,
             "code":"capacity_exceeded","message":"Try later","retryable":true,"retry_after_ms":null}
            """)!
        model.handleFrame(refusal)
        XCTAssertNil(model.workReadState.generation)
        XCTAssertTrue(model.workReadFailed)
        XCTAssertNil(model.errorBanner)
        model.handleFrame(frame(.string(first)))
        XCTAssertNil(model.pendingSurface)
    }
}

// Tests for the watch guidance surface: home-control ordering and clearing on owner/connection change,
// isolation from conversation speech, disabled-button validity, admission-refusal ticket retirement, and
// reconnect retry retention.

import AstralCore
import XCTest

@testable import AstralWatch

@MainActor
final class WatchGuidanceSurface088Tests: XCTestCase {
    private let generation = "33333333-3333-4333-8333-333333333333"
    private let other = "44444444-4444-4444-8444-444444444444"

    private func frame(_ request: JSONValue) -> InboundFrame {
        InboundFrame(
            name: "chrome_surface",
            payload: .object([
                "type": .string("chrome_surface"), "surface_key": .string("guidance"), "region": .string("modal"),
                "title": .string("Server title"), "mode": .string("replace"), "admin_only": .bool(false),
                "request_generation": request,
                "components": .array([
                    .object([
                        "type": .string("text"), "content": .string("Exact **excerpt**"), "variant": .string("body"),
                    ])
                ]),
            ]))
    }

    private func model() -> WatchModel {
        let model = WatchModel()
        model.bindConversationAccount(ConversationAccount(issuer: "https://iam.example.test", subject: "owner")!)
        model.connected = true
        model.guidanceVisible = true
        let request = GuidanceRequest(
            action: "chrome_open",
            payload: .object(["surface": .string("guidance"), "params": .object(["mode": .string("list")])]))!
        model.guidanceState.begin(request, generation: generation)
        return model
    }

    func testSupportedHomeControlsPreserveServerOrderAndClearAtOwnerOrConnectionChange() async {
        let model = model()
        let work: JSONValue = .object([
            "key": .string("work"), "kind": .string("action"), "label": .string("Work"),
            "action": .object(["surface": .string("work"), "params": .object(["mode": .string("list")])]),
        ])
        let notes: JSONValue = .object([
            "key": .string("guidance"), "kind": .string("action"), "label": .string("Private notes"),
            "action": .object(["surface": .string("guidance"), "params": .object(["mode": .string("list")])]),
        ])
        let other: JSONValue = .object(["key": .string("other"), "kind": .string("menu")])
        for controls in [[work, other, notes], [notes, work, other]] {
            model.handleFrame(
                InboundFrame(
                    name: "chrome_menu",
                    payload: .object([
                        "model": .object(["version": .number(2), "topbar": .array(controls), "menu": .array([])])
                    ])))
            XCTAssertEqual(
                model.ownerSurfaceControls.map(\.key),
                controls.compactMap { $0["key"]?.stringValue }.filter { $0 != "other" })
            XCTAssertEqual(model.workControls.count, 1)
            XCTAssertEqual(model.guidanceControls.count, 1)
        }
        model.bindConversationAccount(ConversationAccount(issuer: "https://iam.example.test", subject: "new-owner")!)
        XCTAssertTrue(model.ownerSurfaceControls.isEmpty)
        await model.handle(.disconnected(reason: "synthetic"))
        XCTAssertTrue(model.ownerSurfaceControls.isEmpty)
    }

    func testGuidanceIsSeparateFromConversationAndCannotSpeakOrPaintStaleResponse() {
        let model = model()
        model.canvas = [AstralComponent(type: "text", raw: .object(["content": .string("Original canvas")]))]
        model.pendingDictation = "Draft"
        let canvas = model.canvas
        model.handleFrame(frame(.string(other)))
        model.handleFrame(frame(.null))
        XCTAssertNil(model.guidanceUpdate)
        model.handleFrame(frame(.string(generation)))
        XCTAssertEqual(model.guidanceUpdate?.title, "Server title")
        XCTAssertEqual(model.canvas, canvas)
        XCTAssertEqual(model.pendingDictation, "Draft")
        XCTAssertFalse(model.speaker.isSpeaking)
        model.closeGuidance()
        model.handleFrame(frame(.string(generation)))
        XCTAssertFalse(model.guidanceVisible)
        XCTAssertNil(model.guidanceUpdate)
    }

    func testDisabledCanonicalButtonRemainsValidButNeverPermitsARequest() throws {
        var payload = frame(.string(generation)).payload.objectValue!
        let request = GuidanceRequest.list
        var button: [String: JSONValue] = [
            "type": .string("button"), "label": .string("Refresh **literal**"),
            "action": .string(request.action), "payload": request.payload,
            "variant": .string("secondary"), "disabled": .bool(true), "local": .bool(false),
        ]
        payload["components"] = .array([.object(button)])
        let disabled = try XCTUnwrap(
            GuidanceSurfaceUpdate(frame: InboundFrame(name: "chrome_surface", payload: .object(payload))))
        XCTAssertFalse(disabled.permits(request))
        button["disabled"] = .bool(false)
        payload["components"] = .array([.object(button)])
        let enabled = try XCTUnwrap(
            GuidanceSurfaceUpdate(frame: InboundFrame(name: "chrome_surface", payload: .object(payload))))
        XCTAssertTrue(enabled.permits(request))
    }

    func testOwnerAndConnectionChangesClearPrivateGuidanceAndNeverQueueARead() async {
        for ownerChange in [true, false] {
            let model = model()
            model.handleFrame(frame(.string(generation)))
            if ownerChange {
                model.bindConversationAccount(
                    ConversationAccount(issuer: "https://iam.example.test", subject: "other")!)
            } else {
                await model.handle(.disconnected(reason: "synthetic"))
            }
            XCTAssertNil(model.guidanceState.generation)
            XCTAssertNil(model.guidanceUpdate)
            model.handleFrame(frame(.string(generation)))
            XCTAssertNil(model.guidanceUpdate)
            XCTAssertTrue(model.localOperationSubmissions.isEmpty)
        }
    }

    func testUnrelatedChromeAndMissingServerDescriptorRemainNoninteractive() {
        let model = model()
        model.handleFrame(
            InboundFrame.parse(
                #"{"type":"chrome_menu","model":{"version":2,"topbar":[{"key":"settings","kind":"menu"},{"key":"pulse","kind":"action","label":"Pulse","action":{"surface":"pulse"}}],"menu":[]}}"#
            )!)
        XCTAssertTrue(model.guidanceControls.isEmpty)
        XCTAssertFalse(model.guidanceVisible)
        model.handleFrame(
            InboundFrame.parse(
                #"{"type":"chrome_surface","surface_key":"llm","title":"Setup","components":[],"mode":"mandatory"}"#)!)
        XCTAssertNil(model.guidanceUpdate)
        XCTAssertFalse(model.guidanceVisible)
        XCTAssertTrue(model.canvas.isEmpty)
    }
    func testDuplicateGuidanceResponseCannotReplaceOrCloseAcceptedContent() {
        let model = model()
        model.handleFrame(frame(.string(generation)))
        XCTAssertNil(model.guidanceState.generation)
        var payload = frame(.string(generation)).payload.objectValue!
        payload["title"] = .string("Late replacement")
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(payload)))
        XCTAssertEqual(model.guidanceUpdate?.title, "Server title")
        payload["components"] = .array([])
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(payload)))
        XCTAssertTrue(model.guidanceVisible)
        XCTAssertEqual(model.guidanceUpdate?.title, "Server title")
    }

    func testAdmissionRefusalRetiresGuidanceTicketWithoutQueueing() {
        let model = model()
        model.handleFrame(
            InboundFrame.parse(
                #"{"type":"chrome_menu","model":{"version":2,"topbar":[{"key":"guidance","kind":"action","label":"Work","action":{"surface":"guidance","params":{"mode":"list"}}}],"menu":[]}}"#
            )!)
        let control = model.guidanceControls.first!
        model.connected = false
        model.openGuidance(control)
        XCTAssertTrue(model.guidanceFailed)
        XCTAssertNil(model.guidanceState.generation)
        XCTAssertTrue(model.localOperationSubmissions.isEmpty)
    }
    func testTimeoutOrSendFailureRetiresOnlyCurrentTicketAndKeepsRetrySelection() {
        let model = model()
        model.failGuidanceRequest(generation: other)
        XCTAssertEqual(model.guidanceState.generation, generation)
        model.failGuidanceRequest(generation: generation)
        XCTAssertNil(model.guidanceState.generation)
        XCTAssertTrue(model.guidanceFailed)
        model.handleFrame(frame(.string(generation)))
        XCTAssertNil(model.guidanceUpdate)
        model.handleFrame(
            InboundFrame.parse(
                #"{"type":"chrome_surface","surface_key":"llm","title":"Late","components":[],"mode":"mandatory"}"#)!)
        XCTAssertNil(model.guidanceUpdate)
        XCTAssertTrue(model.guidanceFailed)
    }

    func testMatchingAdmissionRefusalRetiresPrivateReadBeforeGenericErrorHandling() {
        let model = model()
        let request = GuidanceRequest.list
        let text = request.frameText(requestGeneration: generation)
        XCTAssertTrue(model.guidanceState.bindSubmission(text))
        let submission = model.guidanceState.submissionId!
        let refusal = InboundFrame.parse(
            """
            {"type":"error","submission_id":"\(submission)","accepted":false,
             "code":"capacity_exceeded","message":"Try later","retryable":true,"retry_after_ms":null}
            """)!
        model.handleFrame(refusal)
        XCTAssertNil(model.guidanceState.generation)
        XCTAssertTrue(model.guidanceFailed)
        XCTAssertNil(model.errorBanner)
        model.handleFrame(frame(.string(generation)))
        XCTAssertNil(model.guidanceUpdate)
    }
    func testReconnectKeepsSelectedRetiredGuidanceUnavailableUntilExplicitRead() async {
        let model = model()
        await model.handle(.disconnected(reason: "synthetic"))
        XCTAssertTrue(model.guidanceVisible)
        XCTAssertTrue(model.guidanceFailed)
        await model.handle(.connected)
        XCTAssertTrue(model.connected)
        XCTAssertTrue(model.guidanceFailed)
        XCTAssertNil(model.guidanceState.generation)
        XCTAssertNil(model.guidanceUpdate)
        XCTAssertTrue(model.localOperationSubmissions.isEmpty)
    }
}

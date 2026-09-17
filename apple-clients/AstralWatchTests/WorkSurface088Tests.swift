import AstralCore
import XCTest

@testable import AstralWatch

@MainActor
final class WatchWorkSurface088Tests: XCTestCase {
    private let generation = "33333333-3333-4333-8333-333333333333"
    private let other = "44444444-4444-4444-8444-444444444444"

    private func frame(_ request: JSONValue) -> InboundFrame {
        InboundFrame(
            name: "chrome_surface",
            payload: .object([
                "type": .string("chrome_surface"), "surface_key": .string("work"), "region": .string("modal"),
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
        model.workVisible = true
        let request = WorkReadRequest(
            payload: .object(["surface": .string("work"), "params": .object(["mode": .string("list")])]))!
        model.workReadState.begin(request, generation: generation)
        return model
    }

    func testWorkIsSeparateFromConversationAndCannotSpeakOrPaintStaleResponse() {
        let model = model()
        model.canvas = [AstralComponent(type: "text", raw: .object(["content": .string("Original canvas")]))]
        model.pendingDictation = "Draft"
        let canvas = model.canvas
        model.handleFrame(frame(.string(other)))
        model.handleFrame(frame(.null))
        XCTAssertNil(model.workUpdate)
        model.handleFrame(frame(.string(generation)))
        XCTAssertEqual(model.workUpdate?.title, "Server title")
        XCTAssertEqual(model.canvas, canvas)
        XCTAssertEqual(model.pendingDictation, "Draft")
        XCTAssertFalse(model.speaker.isSpeaking)
        model.closeWorkRead()
        model.handleFrame(frame(.string(generation)))
        XCTAssertFalse(model.workVisible)
        XCTAssertNil(model.workUpdate)
    }

    func testOwnerAndConnectionChangesClearPrivateWorkAndNeverQueueARead() async {
        for ownerChange in [true, false] {
            let model = model()
            model.handleFrame(frame(.string(generation)))
            if ownerChange {
                model.bindConversationAccount(
                    ConversationAccount(issuer: "https://iam.example.test", subject: "other")!)
            } else {
                await model.handle(.disconnected(reason: "synthetic"))
            }
            XCTAssertNil(model.workReadState.generation)
            XCTAssertNil(model.workUpdate)
            model.handleFrame(frame(.string(generation)))
            XCTAssertNil(model.workUpdate)
            XCTAssertTrue(model.localOperationSubmissions.isEmpty)
        }
    }

    func testUnrelatedChromeAndMissingServerDescriptorRemainNoninteractive() {
        let model = model()
        model.handleFrame(
            InboundFrame.parse(
                #"{"type":"chrome_menu","model":{"version":2,"topbar":[{"key":"settings","kind":"menu"},{"key":"pulse","kind":"action","label":"Pulse","action":{"surface":"pulse"}}],"menu":[]}}"#
            )!)
        XCTAssertTrue(model.workControls.isEmpty)
        XCTAssertFalse(model.workVisible)
        model.handleFrame(
            InboundFrame.parse(
                #"{"type":"chrome_surface","surface_key":"llm","title":"Setup","components":[],"mode":"mandatory"}"#)!)
        XCTAssertNil(model.workUpdate)
        XCTAssertFalse(model.workVisible)
        XCTAssertTrue(model.canvas.isEmpty)
    }
    func testDuplicateWorkResponseCannotReplaceOrCloseAcceptedContent() {
        let model = model()
        model.handleFrame(frame(.string(generation)))
        XCTAssertNil(model.workReadState.generation)
        var payload = frame(.string(generation)).payload.objectValue!
        payload["title"] = .string("Late replacement")
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(payload)))
        XCTAssertEqual(model.workUpdate?.title, "Server title")
        payload["components"] = .array([])
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(payload)))
        XCTAssertTrue(model.workVisible)
        XCTAssertEqual(model.workUpdate?.title, "Server title")
    }

    func testAdmissionRefusalRetiresWorkTicketWithoutQueueing() {
        let model = model()
        model.handleFrame(
            InboundFrame.parse(
                #"{"type":"chrome_menu","model":{"version":2,"topbar":[{"key":"work","kind":"action","label":"Work","action":{"surface":"work","params":{"mode":"list"}}}],"menu":[]}}"#
            )!)
        let control = model.workControls.first!
        model.connected = false
        model.openWork(control)
        XCTAssertTrue(model.workReadFailed)
        XCTAssertNil(model.workReadState.generation)
        XCTAssertTrue(model.localOperationSubmissions.isEmpty)
    }
    func testTimeoutOrSendFailureRetiresOnlyCurrentTicketAndKeepsRetrySelection() {
        let model = model()
        model.failWorkRead(generation: other)
        XCTAssertEqual(model.workReadState.generation, generation)
        model.failWorkRead(generation: generation)
        XCTAssertNil(model.workReadState.generation)
        XCTAssertTrue(model.workReadFailed)
        model.handleFrame(frame(.string(generation)))
        XCTAssertNil(model.workUpdate)
        model.handleFrame(
            InboundFrame.parse(
                #"{"type":"chrome_surface","surface_key":"llm","title":"Late","components":[],"mode":"mandatory"}"#)!)
        XCTAssertNil(model.workUpdate)
        XCTAssertTrue(model.workReadFailed)
    }

    func testMatchingAdmissionRefusalRetiresPrivateReadBeforeGenericErrorHandling() {
        let model = model()
        let request = model.workReadState.request!
        let text = request.frameText(requestGeneration: generation)
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
        model.handleFrame(frame(.string(generation)))
        XCTAssertNil(model.workUpdate)
    }
    func testReconnectKeepsSelectedRetiredWorkUnavailableUntilExplicitRead() async {
        let model = model()
        await model.handle(.disconnected(reason: "synthetic"))
        XCTAssertTrue(model.workVisible)
        XCTAssertTrue(model.workReadFailed)
        await model.handle(.connected)
        XCTAssertTrue(model.connected)
        XCTAssertTrue(model.workReadFailed)
        XCTAssertNil(model.workReadState.generation)
        XCTAssertNil(model.workUpdate)
        XCTAssertTrue(model.localOperationSubmissions.isEmpty)
    }
}

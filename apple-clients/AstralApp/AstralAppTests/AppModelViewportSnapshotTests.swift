// Verifies scoped layout refresh preserves native presentation and rejects stale, failed, or busy hydration.

import AstralCore
@testable import AstralDeep
import XCTest

@MainActor
final class AppModelViewportSnapshotTests: XCTestCase {
    private let chat = "11111111-1111-4111-8111-111111111111"
    private let connection = "22222222-2222-4222-8222-222222222222"
    private let generation = "33333333-3333-4333-8333-333333333333"

    private final class Frames { var values: [JSONValue] = [] }

    private func frame(_ json: JSONValue) -> InboundFrame {
        InboundFrame.parse(String(data: try! json.encoded(), encoding: .utf8)!)!
    }

    private func snapshot(request: String? = nil, columns: Int = 3) -> InboundFrame {
        InboundFrame.parse(
            """
            {"type":"conversation_snapshot","schema_version":1,
            "snapshot_id":"\(UUID().uuidString.lowercased())","chat_id":"\(chat)",
            "connection_generation":"\(connection)","request_generation":"\(request ?? generation)",
            "snapshot_purpose":"hydration","render_revision":4,"committed_at":"2026-09-25T18:41:00Z",
            "transcript":[{"message_id":"m1","role":"assistant","created_at":"2026-09-25T18:40:00Z",
            "parts":[{"type":"text","text":"Six dice"},{"type":"components","components":[{"type":"grid","columns":\(columns),"component_id":"dice","children":[{"type":"text","content":"16"}]}]}],"attachments":[]}],
            "canvas":{"target":"canvas","components":[{"type":"grid","columns":\(columns),"component_id":"dice","children":[{"type":"text","content":"16"}]}]}}
            """)!
    }

    private func model() -> (AppModel, Frames) {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.bindConversationAccount(ConversationAccount(issuer: "https://test.invalid", subject: "viewport-owner")!)
        model.signedIn = true
        model.connected = true
        _ = model.beginConversationConnection(connection)
        _ = model.openConversationRequest(chatId: chat, requestGeneration: generation, purpose: .hydration)
        model.handleFrame(snapshot())

        model.handleFrame(InboundFrame.parse("{\"type\":\"rote_config\",\"viewport_snapshot_supported\":true}")!)
        model.viewportRefreshInterval = 60_000_000_000
        let frames = Frames()
        model.viewportSendOverride = { text in
            frames.values.append(try! JSONValue.parse(Data(text.utf8)))
            return true
        }
        return (model, frames)
    }

    private func resize(_ model: AppModel, width: Int) {
        model.viewportChanged(width: width, height: 800)
    }

    private func finish(_ model: AppModel, _ frames: Frames, columns: Int = 1) {
        model.handleFrame(snapshot(request: frames.values.last!["request_generation"]!.stringValue!, columns: columns))
    }

    private func configuration(request: String? = nil, columns: Int = 3) -> InboundFrame {
        let insets: JSONValue = .object([
            "top": .number(8), "right": .number(8), "bottom": .number(8), "left": .number(8),
        ])
        let console: JSONValue = .object([
            "version": .number(2), "navigation_mode": .string("sidebar"), "sidebar_width": .number(280),
            "content_padding": insets, "composer_padding": insets, "scenario_columns": .number(Double(columns)),
            "settings_presentation": .string("dialog"), "settings_navigation_axis": .string("vertical"),
            "settings_width": .number(700), "dialog_width": .number(600), "settings_max_height": .number(700),
            "settings_navigation_width": .number(200), "result_preview_max_height": .number(500),
            "result_body_max_height": .number(600), "fullscreen_inset": .number(10),
            "minimum_control_height": .number(44),
        ])
        var root: [String: JSONValue] = [
            "type": .string("rote_config"), "viewport_snapshot_supported": .bool(true),
            "device_profile": .object(["console": console]),
        ]
        if let request {
            root["chat_id"] = .string(chat)
            root["connection_generation"] = .string(connection)
            root["request_generation"] = .string(request)
        }
        return frame(.object(root))
    }

    func testScopedConfigurationWaitsForMatchingSnapshotAndIgnoresRetiredRequest() async {
        let (model, frames) = model()
        model.handleFrame(configuration())
        resize(model, width: 400)
        await model.flushViewportRefresh()
        let request = frames.values.last!["request_generation"]!.stringValue!
        model.handleFrame(configuration(request: request, columns: 1))
        XCTAssertEqual(model.consolePresentation?.scenarioColumns, 3)
        model.handleFrame(configuration(request: generation, columns: 2))
        XCTAssertEqual(model.consolePresentation?.scenarioColumns, 3)
        finish(model, frames)
        XCTAssertEqual(model.consolePresentation?.scenarioColumns, 1)
        model.handleFrame(configuration(request: request, columns: 2))
        XCTAssertEqual(model.consolePresentation?.scenarioColumns, 1)
    }

    func testDebouncedPumpSendsLatestThenRetiresOnDisconnect() async {
        let (model, frames) = model()
        let sent = expectation(description: "debounced viewport send")
        model.viewportRefreshInterval = 1_000_000
        model.viewportSendOverride = { text in
            frames.values.append(try! JSONValue.parse(Data(text.utf8)))
            sent.fulfill()
            return true
        }
        resize(model, width: 400)
        resize(model, width: 420)
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(frames.values.count, 1)
        XCTAssertEqual(frames.values.last?["payload"]?["device"]?["viewport_width"]?.numberValue, 420)
        model.connected = false
        await model.handle(.disconnected(reason: "test"))
        _ = model.beginConversationConnection(UUID().uuidString.lowercased())
        finish(model, frames)
        XCTAssertEqual(model.canvas.first?.raw["columns"]?.numberValue, 3)
    }

    func testRetryableFailureHasBoundedRetriesAndRetainsCanvas() async {
        let (model, frames) = model()
        resize(model, width: 400)
        for count in 1...3 {
            await model.flushViewportRefresh()
            XCTAssertEqual(frames.values.count, count)
            let request = frames.values.last!["request_generation"]!.stringValue!
            model.handleFrame(
                frame(
                    .object([
                        "type": .string("error"), "code": .string("viewport_snapshot_retryable"),
                        "chat_id": .string(chat), "connection_generation": .string(connection),
                        "request_generation": .string(request), "retryable": .bool(true),
                    ])))
        }
        await model.flushViewportRefresh()
        XCTAssertEqual(frames.values.count, 3)
        XCTAssertEqual(model.canvas.first?.raw["columns"]?.numberValue, 3)
    }

    func testOwnOperationProgressDoesNotBlockSnapshotAndAdmissionFailureRestores() async {
        let (model, frames) = model()
        resize(model, width: 400)
        await model.flushViewportRefresh()
        let request = frames.values.last!["request_generation"]!.stringValue!
        func status(_ state: String) -> InboundFrame {
            InboundFrame.parse(
                """
                {"type":"operation_status","operation_id":"44444444-4444-4444-8444-444444444444",
                "action":"update_device","surface":"operation","chat_id":"\(chat)",
                "connection_generation":"\(connection)","request_generation":"\(request)",
                "sequence":0,"state":"\(state)","phase":"\(state)","label":"Updating device",
                "terminal":\(state == "failed"),"retryable":false,
                "error":\(state == "failed" ? #"{"code":"operation_failed","message":"Unavailable"}"# : "null"),"retry_after_ms":null,
                "updated_at":"2026-09-26T01:00:00Z"}
                """)!
        }
        model.handleFrame(status("accepted"))
        XCTAssertNil(model.statusText)
        model.handleFrame(status("running"))
        await model.flushViewportRefresh()
        XCTAssertEqual(frames.values.count, 1)
        model.handleFrame(status("failed"))
        finish(model, frames)
        XCTAssertEqual(model.canvas.first?.raw["columns"]?.numberValue, 3)
        resize(model, width: 410)
        await model.flushViewportRefresh()
        let submission = frames.values.last!["submission_id"]!.stringValue!
        model.handleFrame(
            InboundFrame.parse(
                """
                {"type":"error","submission_id":"\(submission)","accepted":false,
                "code":"capacity_exceeded","message":"Try later","retryable":true,"retry_after_ms":null}
                """)!)
        finish(model, frames)
        XCTAssertEqual(model.canvas.first?.raw["columns"]?.numberValue, 3)
        resize(model, width: 420)
        await model.flushViewportRefresh()
        finish(model, frames)
        XCTAssertEqual(model.canvas.first?.raw["columns"]?.numberValue, 1)
    }

    func testDisconnectAndAuthenticationBoundaryImmediatelyRejectLateHydration() async {
        for auth in [false, true] {
            let (model, frames) = model()
            resize(model, width: 400)
            await model.flushViewportRefresh()
            if auth {
                model.handleFrame(InboundFrame.parse(#"{"type":"auth_required"}"#)!)
            } else {
                await model.handle(.disconnected(reason: "test"))
            }
            finish(model, frames)
            XCTAssertEqual(model.canvas.first?.raw["columns"]?.numberValue, 3)
            await model.flushViewportRefresh()
            XCTAssertEqual(frames.values.count, 1)
            XCTAssertFalse(model.viewportRefreshFailed)
        }
    }

    func testRetiredAdmissionAndOperationFailureCannotEraseNewerOperation() async {
        let (model, frames) = model()
        resize(model, width: 400)
        await model.flushViewportRefresh()
        let request = frames.values.last!["request_generation"]!.stringValue!
        let submission = frames.values.last!["submission_id"]!.stringValue!
        XCTAssertTrue(
            model.openConversationRequest(
                chatId: chat, requestGeneration: UUID().uuidString.lowercased(), purpose: .commit))
        model.errorBanner = "Newer notice"
        model.transientCanvas = [
            AstralComponent(type: "text", raw: .object(["type": .string("text"), "content": .string("Newer result")]))
        ]
        let refusal = InboundFrame.parse(
            """
            {"type":"error","submission_id":"\(submission)","accepted":false,
            "code":"capacity_exceeded","message":"Old refusal","retryable":true,"retry_after_ms":null}
            """)!
        model.handleFrame(refusal)
        model.handleFrame(
            InboundFrame.parse(
                """
                {"type":"operation_status","operation_id":"44444444-4444-4444-8444-444444444444",
                "action":"update_device","surface":"operation","chat_id":"\(chat)",
                "connection_generation":"\(connection)","request_generation":"\(request)",
                "sequence":3,"state":"failed","phase":"failed","label":"Old failure",
                "terminal":true,"retryable":false,"error":{"code":"operation_failed","message":"Old failure"},
                "retry_after_ms":null,"updated_at":"2026-09-26T01:00:00Z"}
                """)!)
        XCTAssertEqual(model.errorBanner, "Newer notice")
        XCTAssertEqual(model.transientCanvas?.first?.fallbackText, "Newer result")
        model.handleFrame(InboundFrame.parse(#"{"type":"auth_required"}"#)!)
        model.handleFrame(refusal)
        XCTAssertEqual(model.errorBanner, "Newer notice")
        XCTAssertEqual(model.transientCanvas?.first?.fallbackText, "Newer result")
    }

    func testLatestViewportCoalescesAndSnapshotPreservesPresentation() async {
        let (model, frames) = model()
        model.composerDraft = "Unsent words"
        model.staged = [
            .init(uid: 7, filename: "draft.txt", category: "document", attachmentId: "attachment", state: "ready")
        ]
        model.consoleFullscreen = true
        model.consoleResultCollapsed = true
        model.canvasHistory = [.init(label: "Prior result", components: model.canvas)]
        let before = model.turns
        resize(model, width: 1000)
        resize(model, width: 600)
        resize(model, width: 390)
        await model.flushViewportRefresh()
        XCTAssertEqual(frames.values.count, 1)
        XCTAssertEqual(frames.values[0]["payload"]?["device"]?["viewport_width"]?.numberValue, 390)
        XCTAssertEqual(frames.values[0]["payload"]?["base_render_revision"]?.numberValue, 4)
        XCTAssertEqual(frames.values[0]["connection_generation"]?.stringValue, connection)
        finish(model, frames)
        XCTAssertEqual(model.canvas.first?.raw["columns"]?.numberValue, 1)
        XCTAssertEqual(model.lastCommittedRenderRevision, 4)
        XCTAssertEqual(model.composerDraft, "Unsent words")
        XCTAssertEqual(model.staged.first?.filename, "draft.txt")
        XCTAssertEqual(model.turns.map(\.id), before.map(\.id))
        XCTAssertEqual(model.turns.map(\.text), before.map(\.text))
        XCTAssertTrue(model.consoleFullscreen)
        XCTAssertTrue(model.consoleResultCollapsed)
        XCTAssertEqual(model.canvasHistory.count, 1)
        await model.flushViewportRefresh()
        XCTAssertEqual(frames.values.count, 1)
    }

    func testBusyRefreshDefersAndKeepsLatestViewport() async {
        let (model, frames) = model()
        let editor = UUID()
        model.setDirectEditing(editor, active: true)
        resize(model, width: 400)
        await model.flushViewportRefresh()
        resize(model, width: 420)
        await model.flushViewportRefresh()
        XCTAssertTrue(frames.values.isEmpty)
        model.setDirectEditing(editor, active: false)
        await model.flushViewportRefresh()
        XCTAssertEqual(frames.values.count, 1)
        XCTAssertEqual(frames.values[0]["payload"]?["device"]?["viewport_width"]?.numberValue, 420)
        finish(model, frames)
    }

    func testEditingOrNavigationDuringFlightRetiresOnlyLayoutHydration() async {
        let (model, frames) = model()
        resize(model, width: 400)
        await model.flushViewportRefresh()
        let editor = UUID()
        model.setDirectEditing(editor, active: true)
        finish(model, frames)
        XCTAssertEqual(model.canvas.first?.raw["columns"]?.numberValue, 3)
        model.setDirectEditing(editor, active: false)
        await model.flushViewportRefresh()
        XCTAssertEqual(frames.values.count, 2)
        XCTAssertNotEqual(frames.values[0]["request_generation"], frames.values[1]["request_generation"])
        finish(model, frames)
        XCTAssertEqual(model.canvas.first?.raw["columns"]?.numberValue, 1)
    }

    func testCorrelatedFailureAndTimeoutRestorePriorSettledCanvas() async {
        let (model, frames) = model()
        resize(model, width: 400)
        await model.flushViewportRefresh()
        let request = frames.values[0]["request_generation"]!.stringValue!
        let error: [String: JSONValue] = [
            "type": .string("error"), "code": .string("viewport_snapshot_rejected"),
            "chat_id": .string(chat), "connection_generation": .string(connection),
            "request_generation": .string(request), "retryable": .bool(false), "message": .string("Unavailable"),
        ]
        var stale = error
        stale["request_generation"] = .string(generation)
        model.handleFrame(frame(.object(stale)))
        await model.flushViewportRefresh()
        XCTAssertEqual(frames.values.count, 1)
        model.handleFrame(frame(.object(error)))
        model.handleFrame(snapshot(request: request, columns: 1))
        XCTAssertEqual(model.canvas.first?.raw["columns"]?.numberValue, 3)
        resize(model, width: 410)
        model.viewportRefreshTimeout = -1
        await model.flushViewportRefresh()
        XCTAssertEqual(frames.values.count, 2)
        await model.flushViewportRefresh()
        finish(model, frames)
        XCTAssertEqual(model.canvas.first?.raw["columns"]?.numberValue, 3)
        XCTAssertTrue(model.viewportRefreshFailed)
        model.viewportRefreshTimeout = 10
        model.retryViewportRefresh()
        XCTAssertFalse(model.viewportRefreshFailed)
        await model.flushViewportRefresh()
        XCTAssertEqual(frames.values.count, 3)
        finish(model, frames)
        XCTAssertEqual(model.canvas.first?.raw["columns"]?.numberValue, 1)
    }

    func testNewerConversationRequestCannotBeReplacedByLateViewportSnapshot() async {
        let (model, frames) = model()
        resize(model, width: 400)
        await model.flushViewportRefresh()
        let next = UUID().uuidString.lowercased()
        XCTAssertTrue(model.openConversationRequest(chatId: chat, requestGeneration: next, purpose: .hydration))
        finish(model, frames)
        XCTAssertEqual(model.canvas.first?.raw["columns"]?.numberValue, 3)
        model.handleFrame(snapshot(request: next, columns: 2))
        XCTAssertEqual(model.canvas.first?.raw["columns"]?.numberValue, 2)
    }

    func testFailedLiveSendDoesNotQueueOrEraseResult() async {
        let (model, frames) = model()
        model.viewportSendOverride = { _ in false }
        resize(model, width: 400)
        await model.flushViewportRefresh()
        XCTAssertTrue(frames.values.isEmpty)
        XCTAssertTrue(model.viewportRefreshFailed)
        XCTAssertEqual(model.canvas.first?.raw["columns"]?.numberValue, 3)
        model.viewportSendOverride = { text in
            frames.values.append(try! JSONValue.parse(Data(text.utf8)))
            return true
        }
        resize(model, width: 410)
        await model.flushViewportRefresh()
        XCTAssertEqual(frames.values.count, 1)
        finish(model, frames)
        XCTAssertEqual(model.canvas.first?.raw["columns"]?.numberValue, 1)
    }
}

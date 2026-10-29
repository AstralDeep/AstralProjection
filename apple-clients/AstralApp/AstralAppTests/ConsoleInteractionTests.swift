// Verifies console actions retain authenticated dispatch and exact current-surface ownership.
// Shared fixtures exercise catalog loading, confirmed selections, capability changes, account cleanup, turn
// cancellation and the per-chat tool activity model built from status, step and component frames.

import AstralCore
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import AstralDeep

enum ActivityFrames {
    static func step(
        _ id: String, chat: String = "c1", name: String = "click", status: String, arguments: String? = nil,
        result: String? = nil, error: String? = nil
    ) -> InboundFrame {
        var step: [String: JSONValue] = [
            "id": .string(id), "chat_id": .string(chat), "kind": .string("tool_call"), "name": .string(name),
            "status": .string(status),
        ]
        if let arguments { step["args_truncated"] = .string(arguments) }
        if let result { step["result_summary"] = .string(result) }
        if let error { step["error_message"] = .string(error) }
        return InboundFrame(
            name: "chat_step",
            payload: .object(["type": .string("chat_step"), "chat_id": .string(chat), "step": .object(step)]))
    }

    static func status(_ status: String, message: String? = nil) -> InboundFrame {
        var payload: [String: JSONValue] = ["type": .string("chat_status"), "status": .string(status)]
        if let message { payload["message"] = .string(message) }
        return InboundFrame(name: "chat_status", payload: .object(payload))
    }

    static func approvalCard(_ request: String, image: String? = nil) -> AstralComponent {
        var content: [JSONValue] = [
            .object(["type": .string("text"), "content": .string("Tool: click · Agent: computer-use-1")]),
            .object(["type": .string("text"), "content": .string("Click in TextEdit")]),
        ]
        if let image { content.append(.object(["type": .string("image"), "url": .string(image)])) }
        for decision in ["approve", "grant_task", "decline"] {
            content.append(
                .object([
                    "type": .string("button"), "label": .string(decision), "action": .string("authorize_action"),
                    "payload": .object(["hitl_request_id": .string(request), "decision": .string(decision)]),
                ]))
        }
        return AstralComponent(
            type: "card",
            raw: .object([
                "type": .string("card"), "id": .string("hitl_\(request)"), "title": .string("Review action"),
                "content": .array(content),
            ]))
    }

    static func pngDataURL() throws -> String {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 16, height: 12, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.4, green: 0.2, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return "data:image/png;base64," + (data as Data).base64EncodedString()
    }
}

@MainActor
final class ConsoleInteractionTests: XCTestCase {
    private var suites: [String] = []
    private let generation = "33333333-3333-4333-8333-333333333333"
    private let otherGeneration = "44444444-4444-4444-8444-444444444444"

    private func fixture() throws -> JSONValue {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "chrome-console", withExtension: "json"))
        return try JSONValue.parse(Data(contentsOf: url))
    }

    private func model() throws -> AppModel {
        let suite = "ConsoleInteractionTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(
            conversationResumeStore: ConversationResumeStore(defaults: defaults),
            tokenStore: InMemoryTokenStore(), defaults: defaults)
        model.signedIn = true
        model.connected = true
        model.bindConversationAccount(ConversationAccount(issuer: "https://iam.example.test", subject: "owner")!)
        model.chromeMenu = try XCTUnwrap(ChromeMenuModel.fromJSON(fixture()))
        return model
    }

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites.removeAll()
        super.tearDown()
    }

    private func intro(_ model: AppModel, payload: JSONValue, action: String = "compose_prompt") {
        model.screen = .surface
        model.pendingSurfaceKey = "agent_intro"
        model.pendingSurface = .init(
            surfaceKey: "agent_intro", title: "Dice Roller",
            components: [
                AstralComponent(
                    type: "container",
                    raw: .object([
                        "type": .string("container"),
                        "children": .array([
                            .object([
                                "type": .string("button"), "label": .string("Load prompt"),
                                "action": .string(action), "payload": payload,
                            ])
                        ]),
                    ]))
            ])
    }

    private var selectionJSON: JSONValue {
        .object([
            "version": .number(1), "agent": .null, "skills": .array([]),
            "notes": .array([.object(["note_id": .string(generation), "revision": .number(2)])]),
        ])
    }

    private func selectionFrame(_ selection: JSONValue, generation: String) -> InboundFrame {
        InboundFrame(
            name: "chrome_surface",
            payload: .object([
                "type": .string("chrome_surface"), "surface_key": .string("guidance"), "region": .string("modal"),
                "title": .string("Selection saved"), "mode": .string("replace"), "admin_only": .bool(false),
                "request_generation": .string(generation), "components": .array([]), "selection": selection,
            ]))
    }

    func testConsoleLandingDoesNotDisplayLegacyWelcomeAsAResult() throws {
        let model = try model()
        let welcome = AstralComponent(
            type: "hero",
            raw: .object([
                "type": .string("hero"), "data-welcome": .string("intro"),
                "heading": .string("How can I help?"),
            ]))
        model.canvas = [welcome]
        XCTAssertFalse(model.workspaceStarted)
        XCTAssertTrue(model.workspaceCanvas.isEmpty)
        model.newChat()
        model.canvas = [welcome]
        XCTAssertTrue(model.workspaceCanvas.isEmpty)
        let result = AstralComponent(
            type: "text",
            raw: .object([
                "type": .string("text"), "content": .string("Dice total: 21"),
            ]))
        model.canvas = [welcome, result]
        XCTAssertEqual(model.workspaceCanvas, [result])
    }

    func testCatalogLoadPreservesCanvasAndRunUsesOrdinaryChat() throws {
        let model = try model()
        let scenario = try XCTUnwrap(model.console?.catalog.scenarios.first)
        let canvas = [AstralComponent(type: "text", raw: .object(["content": .string("Current result")]))]
        model.canvas = canvas
        var frames: [JSONValue] = []
        model.outboundTap = { frames.append(try! JSONValue.parse(Data($0.utf8))) }
        model.useConsoleScenario(scenario, run: false)
        XCTAssertEqual(model.composerDraft, scenario.prompt)
        XCTAssertEqual(model.canvas, canvas)
        XCTAssertTrue(frames.isEmpty)
        model.useConsoleScenario(scenario, run: true)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?["action"], .string("chat_message"))
        XCTAssertEqual(frames.first?["payload"]?["message"], .string(scenario.prompt))
        XCTAssertTrue(model.composerDraft.isEmpty)
        XCTAssertFalse(model.consoleDashboardVisible)
        XCTAssertTrue(model.workspaceStarted)
    }

    func testCatalogCannotRunWhileUnavailableOrAfterCatalogReplacement() throws {
        for state in ["signed_out", "disconnected", "mandatory", "read_only", "stale"] {
            let model = try model()
            let scenario = try XCTUnwrap(model.console?.catalog.scenarios.first)
            model.composerDraft = "Keep this draft"
            if state == "signed_out" { model.signedIn = false }
            if state == "disconnected" { model.connected = false }
            if state == "mandatory" { model.mandatorySurface = true }
            if state == "read_only" { model.timelineReadOnly = true }
            if state == "stale" { model.chromeMenu = nil }
            var sent = 0
            model.outboundTap = { _ in sent += 1 }
            for run in [false, true] { model.useConsoleScenario(scenario, run: run) }
            XCTAssertEqual(sent, 0, state)
            XCTAssertEqual(model.composerDraft, "Keep this draft", state)
        }
    }

    func testIntroLoadRequiresExactCurrentPayloadAndNeverDispatches() throws {
        let model = try model()
        let payload: JSONValue = .object(["message": .string("Roll six dice")])
        intro(model, payload: payload)
        var sent = 0
        model.outboundTap = { _ in sent += 1 }
        model.sendEvent("compose_prompt", .object(["message": .string("Different prompt")]))
        XCTAssertTrue(model.composerDraft.isEmpty)
        XCTAssertEqual(model.screen, .surface)
        model.sendEvent("compose_prompt", payload)
        XCTAssertEqual(model.composerDraft, "Roll six dice")
        XCTAssertEqual(model.screen, .chat)
        XCTAssertNil(model.pendingSurface)
        XCTAssertEqual(sent, 0)
        model.composerDraft = "New draft"
        model.sendEvent("compose_prompt", payload)
        XCTAssertEqual(model.composerDraft, "New draft")
    }

    func testIntroLoadRejectsUnavailableAndMalformedActions() throws {
        for state in [
            "signed_out", "disconnected", "hidden", "mandatory", "read_only", "wrong_surface", "missing_surface",
            "empty", "oversized", "extra",
        ] {
            let model = try model()
            var payload: JSONValue = .object(["message": .string("Roll six dice")])
            if state == "empty" { payload = .object(["message": .string("")]) }
            if state == "oversized" { payload = .object(["message": .string(String(repeating: "x", count: 8001))]) }
            if state == "extra" {
                payload = .object(["message": .string("Roll six dice"), "authority": .string("forged")])
            }
            intro(model, payload: payload)
            if state == "signed_out" { model.signedIn = false }
            if state == "disconnected" { model.connected = false }
            if state == "hidden" { model.screen = .chat }
            if state == "mandatory" { model.mandatorySurface = true }
            if state == "read_only" { model.timelineReadOnly = true }
            if state == "wrong_surface" { model.pendingSurfaceKey = "theme" }
            if state == "missing_surface" { model.pendingSurface = nil }
            model.composerDraft = "Keep"
            var sent = 0
            model.outboundTap = { _ in sent += 1 }
            model.sendEvent("compose_prompt", payload)
            XCTAssertEqual(model.composerDraft, "Keep", state)
            XCTAssertEqual(sent, 0, state)
        }
    }

    func testIntroRunUsesReadyAttachmentsAndClosesTheSurface() throws {
        let model = try model()
        let payload: JSONValue = .object(["message": .string("Roll six dice")])
        intro(model, payload: payload, action: "chat_message")
        model.composerDraft = "Previous draft"
        model.staged = [
            .init(uid: 1, filename: "example.csv", category: "data", attachmentId: generation, state: "ready")
        ]
        var frames: [JSONValue] = []
        model.outboundTap = { frames.append(try! JSONValue.parse(Data($0.utf8))) }
        model.sendEvent("chat_message", .object(["message": .string("Forged prompt")]))
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(model.screen, .surface)
        model.sendEvent("chat_message", payload)
        XCTAssertEqual(model.screen, .chat)
        XCTAssertNil(model.pendingSurface)
        XCTAssertTrue(model.composerDraft.isEmpty)
        XCTAssertTrue(model.staged.isEmpty)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?["action"], .string("chat_message"))
        XCTAssertEqual(frames.first?["payload"]?["message"], payload["message"])
        XCTAssertEqual(
            frames.first?["payload"]?["attachments"]?.arrayValue?.first?["attachment_id"], .string(generation))
        XCTAssertEqual(model.turns.first?.role, "user")
        XCTAssertTrue(model.turns.first?.text.contains("example.csv") == true)
    }

    func testOnlyCurrentSelectionConfirmationAffectsSubsequentChat() throws {
        let model = try model()
        model.screen = .surface
        model.pendingSurfaceKey = "guidance"
        XCTAssertTrue(model.guidanceState.begin(.selection, generation: generation))
        model.handleFrame(selectionFrame(selectionJSON, generation: generation))
        XCTAssertNil(model.turnSelection)
        let request = try XCTUnwrap(
            GuidanceRequest(action: "chrome_turn_selection_set", payload: selectionJSON))
        XCTAssertTrue(model.guidanceState.begin(request, generation: generation))
        model.handleFrame(selectionFrame(selectionJSON, generation: otherGeneration))
        XCTAssertNil(model.turnSelection)
        model.handleFrame(selectionFrame(selectionJSON, generation: generation))
        XCTAssertEqual(model.turnSelection?.json, selectionJSON)
        XCTAssertEqual(model.screen, .chat)
        var frames: [JSONValue] = []
        model.outboundTap = { frames.append(try! JSONValue.parse(Data($0.utf8))) }
        model.sendChat("Use my selected note")
        XCTAssertEqual(frames.last?["payload"]?["selection"], selectionJSON)
        model.sendEvent("chat_message", .object(["message": .string("Continue")]))
        XCTAssertEqual(frames.last?["payload"]?["selection"], selectionJSON)
        model.newChat()
        XCTAssertNil(model.turnSelection)
        model.sendChat("New context")
        XCTAssertNil(frames.last?["payload"]?["selection"])
    }

    func testConfirmedClearAndChatChangeRemoveSelection() throws {
        let model = try model()
        model.turnSelection = TurnSelection(json: selectionJSON)
        model.screen = .surface
        model.pendingSurfaceKey = "guidance"
        let empty = TurnSelection.empty.json
        let request = try XCTUnwrap(
            GuidanceRequest(action: "chrome_turn_selection_set", payload: empty))
        XCTAssertTrue(model.guidanceState.begin(request, generation: generation))
        model.handleFrame(selectionFrame(empty, generation: generation))
        XCTAssertNil(model.turnSelection)
        model.turnSelection = TurnSelection(json: selectionJSON)
        model.openChat(otherGeneration)
        XCTAssertNil(model.turnSelection)
    }

    func testCapabilitiesReevaluateWithoutViewportChangeAndRejectInvalidDimensions() throws {
        let model = try model()
        var frames: [JSONValue] = []
        model.outboundTap = { frames.append(try! JSONValue.parse(Data($0.utf8))) }
        model.viewportChanged(width: 390, height: 844, pixelRatio: 3)
        XCTAssertEqual(frames.count, 1)
        let first = frames[0]["payload"]?["device"]
        XCTAssertEqual(first?["pixel_ratio"], .number(3))
        model.viewportChanged(width: 390, height: 844, pixelRatio: 3)
        XCTAssertEqual(frames.count, 1)
        model.networkCapabilitiesChanged("cellular")
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.last?["payload"]?["device"]?["connection_type"], .string("cellular"))
        model.viewportChanged(width: 0, height: 844, pixelRatio: 4)
        model.viewportChanged(width: 390, height: 844, pixelRatio: .infinity)
        XCTAssertEqual(frames.count, 2)
        model.viewportChanged(width: 390, height: 844, pixelRatio: 2)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.last?["payload"]?["device"]?["pixel_ratio"], .number(2))
        model.networkCapabilitiesChanged("unrecognized")
        XCTAssertEqual(frames.last?["payload"]?["device"]?["connection_type"], .string("unknown"))
    }

    func testDashboardPreservesWorkAndAccountRemovalClearsPrivateSurfaces() throws {
        let model = try model()
        let payload: JSONValue = .object(["message": .string("Private prompt")])
        intro(model, payload: payload)
        model.activeChatId = generation
        model.canvas = [AstralComponent(type: "text", raw: .object(["content": .string("Current result")]))]
        model.composerDraft = "Draft"
        model.turnSelection = TurnSelection(json: selectionJSON)
        let canvas = model.canvas
        model.showConsoleDashboard()
        XCTAssertTrue(model.consoleDashboardVisible)
        XCTAssertEqual(model.canvas, canvas)
        XCTAssertEqual(model.composerDraft, "Draft")
        XCTAssertEqual(model.activeChatId, generation)
        intro(model, payload: payload)
        model.mandatorySurface = true
        model.clearConversationForAccountRemoval()
        XCTAssertNil(model.chromeMenu)
        XCTAssertNil(model.pendingSurface)
        XCTAssertTrue(model.pendingSurfaceKey.isEmpty)
        XCTAssertEqual(model.pendingSurfaceParams, .object([:]))
        XCTAssertNil(model.turnSelection)
        XCTAssertTrue(model.canvas.isEmpty)
        XCTAssertTrue(model.composerDraft.isEmpty)
        XCTAssertFalse(model.mandatorySurface)
        XCTAssertEqual(model.screen, .chat)
    }

    func testCancelCurrentTurnSendsCancelTaskOnlyDuringAConnectedTurnAndRecordsTheCancellation() throws {
        let model = try model()
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        model.activeChatId = "c1"
        XCTAssertFalse(model.canCancelTurn)
        XCTAssertFalse(model.cancelCurrentTurn())
        model.turnActive = true
        model.connected = false
        XCTAssertFalse(model.cancelCurrentTurn())
        XCTAssertTrue(sent.isEmpty)
        model.connected = true
        model.handleFrame(ActivityFrames.step("s1", status: "in_progress", arguments: #"{"x":10,"y":20,"hwnd":5}"#))
        XCTAssertTrue(model.canCancelTurn)
        XCTAssertTrue(model.cancelCurrentTurn())
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["type"], .string("ui_event"))
        XCTAssertEqual(sent.first?["action"], .string("cancel_task"))
        XCTAssertEqual(sent.first?["session_id"], .string("c1"))
        XCTAssertEqual(sent.first?["payload"]?["submission_id"], sent.first?["submission_id"])
        XCTAssertEqual(model.activity.map(\.state), [.cancelled])
        model.handleFrame(ActivityFrames.step("s1", status: "cancelled"))
        model.handleFrame(ActivityFrames.status("done", message: "Cancelled"))
        model.handleFrame(ActivityFrames.status("done", message: "Cancelled"))
        XCTAssertFalse(model.turnActive)
        XCTAssertFalse(model.cancelCurrentTurn())
        XCTAssertEqual(model.activity.map(\.action), ["click", "Turn cancelled"])
        XCTAssertEqual(model.activity.last?.accessibilityValue, "Cancelled")
        XCTAssertEqual(sent.count, 1)
    }

    func testActivityRowsFollowToolStepsDecisionsAndServerRedispatch() throws {
        let model = try model()
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        XCTAssertTrue(model.beginConversationConnection(generation))
        model.currentApprovalDecisionSendOverride = { _, sentConnection in sentConnection == self.generation }
        let chat = "11111111-1111-4111-8111-111111111111"
        model.activeChatId = chat
        model.turns = [.init(id: "u1", role: "user", text: "Type a sentence")]
        let arguments = #"{"x":10,"y":20,"hwnd":5}"#
        model.handleFrame(ActivityFrames.step("s1", chat: chat, status: "in_progress", arguments: arguments))
        var row = try XCTUnwrap(model.activity.first)
        XCTAssertEqual([row.action, row.target], ["click", "at 10, 20"])
        XCTAssertEqual(row.state, .running)
        XCTAssertEqual(row.position, 1)
        XCTAssertEqual(row.accessibilityValue, "Running")
        model.handleFrame(
            ActivityFrames.step(
                "s1", chat: chat, status: "completed",
                result: #"{"_data":{"status":"confirmation_required","message":"An approval card is available."}}"#))
        row = try XCTUnwrap(model.activity.first)
        XCTAssertEqual(row.approval, .waiting)
        XCTAssertEqual(row.state, .running)
        XCTAssertEqual(row.accessibilityValue, "Approval waiting, Running")
        model.canvas = [ActivityFrames.approvalCard("r1")]
        XCTAssertEqual(AppModel.pendingComputerApprovals(in: model.canvas).map(\.requestId), ["r1"])
        XCTAssertEqual(AppModel.pendingComputerApprovals(in: model.canvas).first?.summary, "Click in TextEdit")
        XCTAssertEqual(model.activity.count, 1)
        model.sendEvent(
            "authorize_action", .object(["hitl_request_id": .string("r1"), "decision": .string("grant_task")]))
        XCTAssertEqual(sent.last?["action"], .string("authorize_action"))
        #if os(macOS)
            XCTAssertEqual(model.activity.first?.approval, .uncertain)
            XCTAssertTrue(model.canCancelTurn)
        #else
            XCTAssertEqual(model.activity.first?.approval, .granted)
        #endif
        model.handleFrame(ActivityFrames.step("s2", chat: chat, status: "in_progress", arguments: arguments))
        XCTAssertEqual(model.activity.count, 1)
        XCTAssertEqual(model.activity.first?.state, .running)
        model.handleFrame(
            ActivityFrames.step(
                "s2", chat: chat, status: "completed", result: #"{"_data":{"attempted":true,"message":"Clicked"}}"#))
        row = try XCTUnwrap(model.activity.first)
        XCTAssertEqual(row.state, .completed)
        XCTAssertEqual(row.result, "Clicked")
        XCTAssertEqual(row.accessibilityLabel, "click, at 10, 20")
        #if os(macOS)
            XCTAssertEqual(row.accessibilityValue, "Outcome uncertain, Clicked")
        #else
            XCTAssertEqual(row.accessibilityValue, "Allowed for this task, Clicked")
        #endif
        model.handleFrame(
            ActivityFrames.step(
                "s3", chat: chat, name: "run_command", status: "in_progress",
                arguments: #"{"command":"wc -l notes.txt","cwd":"/Users/owner/Notes"}"#))
        model.handleFrame(
            ActivityFrames.step("s3", chat: chat, name: "run_command", status: "errored", error: "Folder\nnot shared"))
        XCTAssertEqual(model.activity[1].action, "run command")
        XCTAssertEqual(model.activity[1].target, "wc -l notes.txt")
        XCTAssertEqual(model.activity[1].state, .failed)
        XCTAssertEqual(model.activity[1].result, "Folder not shared")
        model.handleFrame(
            InboundFrame(
                name: "tool_progress",
                payload: .object([
                    "type": .string("tool_progress"), "tool_name": .string("summarize"),
                    "message": .string("Reading"), "percentage": .number(40),
                ])))
        XCTAssertEqual(model.activity.last?.result, "Reading (40%)")
        XCTAssertEqual(model.activity.last?.state, .running)
        model.handleFrame(ActivityFrames.status("idle"))
        XCTAssertEqual(model.activity.last?.state, .completed)
        model.activeChatId = "22222222-2222-4222-8222-222222222222"
        XCTAssertTrue(model.activity.isEmpty)
        model.activeChatId = chat
        XCTAssertEqual(model.activity.count, 3)
    }

    func testDeclinedApprovalAndOtherChatsStayInTheirOwnRows() throws {
        let model = try model()
        model.outboundTap = { _ in }
        model.activeChatId = "c1"
        model.canvas = [ActivityFrames.approvalCard("r9")]
        let row = try XCTUnwrap(model.activity.first)
        XCTAssertEqual(row.id, "approval-r9")
        XCTAssertEqual([row.action, row.target], ["click", "Click in TextEdit"])
        XCTAssertEqual(row.approval, .waiting)
        model.sendEvent(
            "authorize_action", .object(["hitl_request_id": .string("r9"), "decision": .string("decline")]))
        #if os(macOS)
            XCTAssertEqual(model.activity.first?.approval, .uncertain)
            XCTAssertTrue(model.canCancelTurn)
            model.handleFrame(ActivityFrames.status("done"))
            XCTAssertEqual(model.activity.first?.state, .completed)
            XCTAssertFalse(model.canCancelTurn)
        #else
            XCTAssertEqual(model.activity.first?.approval, .denied)
            XCTAssertEqual(model.activity.first?.state, .cancelled)
        #endif
        model.canvas = [ActivityFrames.approvalCard("r9")]
        XCTAssertEqual(model.activity.count, 1)
        model.handleFrame(ActivityFrames.step("other", chat: "c2", status: "in_progress", arguments: "{}"))
        XCTAssertEqual(model.activity.count, 1)
        model.activeChatId = "c2"
        XCTAssertEqual(model.activity.map(\.id), ["other"])
        XCTAssertEqual(model.activity.first?.position, Int.max)
        model.clearConversationForAccountRemoval()
        XCTAssertTrue(model.activityLog.isEmpty)
    }

    func testActivityKeepsTheLatestTwoHundredRowsPerChatAndAdoptsANewChat() throws {
        let model = try model()
        model.activeChatId = nil
        model.handleFrame(ActivityFrames.step("first", chat: "", status: "completed", result: "{}"))
        XCTAssertEqual(model.activityLog[""]?.count, 1)
        model.handleFrame(
            InboundFrame(
                name: "chat_created",
                payload: .object(["type": .string("chat_created"), "payload": .object(["chat_id": .string("c1")])])))
        XCTAssertEqual(model.activeChatId, "c1")
        XCTAssertNil(model.activityLog[""])
        XCTAssertEqual(model.activity.map(\.id), ["first"])
        for index in 0..<205 {
            model.handleFrame(ActivityFrames.step("bulk-\(index)", status: "completed", result: #"{"exit_code":0}"#))
        }
        XCTAssertEqual(model.activity.count, AppModel.maximumActivityRows)
        XCTAssertEqual(model.activity.first?.id, "bulk-5")
        XCTAssertEqual(model.activity.last?.result, "Exit 0")
    }

    func testActivitySummariesStayShortAndReadable() {
        XCTAssertEqual(AppModel.activityTarget(#"{"x1":1,"y1":2,"x2":30,"y2":40}"#), "from 1, 2 to 30, 40")
        XCTAssertEqual(AppModel.activityTarget(#"{"keys":["cmd","s"],"hwnd":3}"#), "cmd+s")
        XCTAssertEqual(AppModel.activityTarget(#"{"hwnd":3,"_token":"x"}"#), "hwnd 3")
        XCTAssertEqual(AppModel.activityTarget(#"{"text":"truncated"#), "")
        XCTAssertEqual(AppModel.activityTarget("plain words"), "plain words")
        XCTAssertEqual(AppModel.activityTarget(""), "")
        XCTAssertEqual(AppModel.activityLine(String(repeating: "a", count: 200)).count, 120)
        XCTAssertEqual(AppModel.activityResult(#"{"_data":{"status":"confirmation_req"#).waiting, false)
        XCTAssertTrue(AppModel.activityResult(#"{"_data":{"status":"confirmation_required","x":"#).waiting)
        XCTAssertEqual(AppModel.activityResult(#"{"exit_code":1,"timed_out":true}"#).text, "Timed out")
        XCTAssertEqual(AppModel.activityResult(#"{"error":{"message":"No access"}}"#).text, "No access")
        XCTAssertEqual(AppModel.activityResult(#"{"_data":{"status":"opened_app"}}"#).text, "opened app")
        XCTAssertEqual(AppModel.activityResult(#"["a","b"]"#).text, "a, b")
        XCTAssertEqual(AppModel.activityResult("Finished").text, "Finished")
        XCTAssertEqual(AppModel.activityResult(nil).text, "")
        XCTAssertNil(AppModel.activityThumbnail("data:image/png;base64,not-an-image"))
        XCTAssertNil(AppModel.activityThumbnail("https://example.test/image.png"))
        let declined = AstralComponent(
            type: "card",
            raw: .object([
                "type": .string("card"), "id": .string("hitl_r1"), "title": .string("Declined"),
                "content": .array([.object(["type": .string("text"), "content": .string("Declined")])]),
            ]))
        XCTAssertTrue(AppModel.pendingComputerApprovals(in: [declined]).isEmpty)
        let other = AstralComponent(
            type: "card",
            raw: .object([
                "type": .string("card"), "id": .string("hitl_r2"),
                "content": .array([
                    .object(["type": .string("text"), "content": .string("Tool: search · Agent: research-1")]),
                    .object([
                        "type": .string("button"), "action": .string("authorize_action"),
                        "payload": .object(["hitl_request_id": .string("r2"), "decision": .string("approve")]),
                    ]),
                ]),
            ]))
        XCTAssertTrue(AppModel.pendingComputerApprovals(in: [other]).isEmpty)
        let remote = AstralComponent(
            type: "card",
            raw: .object([
                "type": .string("card"), "id": .string("au_approval_abc"), "title": .string("Confirm an action on Mac"),
                "content": .array([
                    .object(["type": .string("text"), "content": .string("Run wc -l notes.txt")]),
                    .object([
                        "type": .string("button"), "action": .string("remote_op_decision"),
                        "payload": .object(["proposal_id": .string("abc"), "decision": .string("approve")]),
                    ]),
                ]),
            ]))
        let container = AstralComponent(
            type: "container", raw: .object(["type": .string("container"), "children": .array([remote.raw])]))
        XCTAssertEqual(
            AppModel.pendingComputerApprovals(in: [container]),
            [AppModel.PendingApproval(requestId: "abc", tool: "", summary: "Run wc -l notes.txt", image: nil)])
    }

    func testActivityThumbnailComesFromTheLatestScreenImageAndApprovalCrop() async throws {
        let model = try model()
        model.outboundTap = { _ in }
        model.activeChatId = "c1"
        let image = try ActivityFrames.pngDataURL()
        model.handleFrame(ActivityFrames.step("s1", status: "completed", result: "{}"))
        model.canvas = [
            AstralComponent(
                type: "image",
                raw: .object([
                    "type": .string("image"), "id": .string("au_cuview_session"), "url": .string(image),
                ]))
        ]
        model.canvas = model.canvas + [AstralComponent(type: "text", raw: .object(["content": .string("Later")]))]
        model.canvas = [ActivityFrames.approvalCard("r1", image: image)] + model.canvas
        let deadline = Date().addingTimeInterval(10)
        while model.activity.contains(where: { $0.thumbnail == nil }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.activity.map(\.id), ["s1", "approval-r1"])
        for row in model.activity {
            let data = try XCTUnwrap(row.thumbnail)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        }
        XCTAssertTrue(model.activity[0].accessibilityValue.hasSuffix("Screenshot"))
    }

    #if os(macOS)
        func testComputerApprovalCardTellsTheHostWhileItWaitsAndStopEndsTheTurnAndSession() async throws {
            let fixture = try MacComputerLifecycleFixture()
            defer { fixture.close() }
            try fixture.enableAndStart()
            let suite = "ConsoleInteractionTests.\(UUID().uuidString)"
            suites.append(suite)
            let defaults = UserDefaults(suiteName: suite)!
            let model = AppModel(
                conversationResumeStore: ConversationResumeStore(defaults: defaults),
                tokenStore: InMemoryTokenStore(), defaults: defaults, computerHost: fixture.host)
            XCTAssertTrue(model.macComputerHost === fixture.host)
            XCTAssertTrue(fixture.host.browser === model.macBrowser)
            model.signedIn = true
            model.connected = true
            model.activeChatId = "c1"
            var sent: [JSONValue] = []
            model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
            XCTAssertFalse(fixture.host.awaitingApproval)
            model.canvas = [ActivityFrames.approvalCard("r1")]
            XCTAssertTrue(fixture.host.awaitingApproval)
            model.sendEvent(
                "authorize_action", .object(["hitl_request_id": .string("r1"), "decision": .string("approve")]))
            XCTAssertFalse(fixture.host.awaitingApproval)
            XCTAssertEqual(model.activity.first?.approval, .uncertain)
            XCTAssertTrue(model.canCancelTurn)
            model.canvas = [ActivityFrames.approvalCard("r2")]
            XCTAssertTrue(fixture.host.awaitingApproval)
            model.canvas = []
            XCTAssertFalse(fixture.host.awaitingApproval)
            model.turnActive = true
            XCTAssertTrue(fixture.host.taskActive)
            model.stopComputerTask()
            XCTAssertNil(fixture.host.session)
            XCTAssertEqual(sent.last?["action"], .string("cancel_task"))
            let deadline = Date().addingTimeInterval(5)
            while !fixture.channel.events.contains("stopped"), Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(fixture.channel.events.contains("stopped"))
            model.turnActive = false
            model.stopComputerTask()
            XCTAssertEqual(sent.filter { $0["action"] == .string("cancel_task") }.count, 1)
        }
    #endif
}

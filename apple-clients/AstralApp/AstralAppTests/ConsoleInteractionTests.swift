// Verifies console actions retain authenticated dispatch and exact current-surface ownership.
// Shared fixtures exercise catalog loading, confirmed selections, capability changes, and account cleanup.

import AstralCore
import XCTest

@testable import AstralDeep

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
}

// Tests for AppModel's chrome_surface reduce logic: the mandatory first-run gate pins navigation on an
// unsolicited surface, a blank close lifts it, and every entry point but sign-out stays suppressed while
// pinned.

import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
final class AppModelChromeSurfaceTests: XCTestCase {
    private var suites: [String] = []

    private let mandatoryLLM =
        #"{"type":"chrome_surface","surface_key":"llm","title":"Set up your AI provider","components":[{"type":"text","content":"Pick a provider"}],"mode":"mandatory"}"#
    private let blankClose = #"{"type":"chrome_surface","surface_key":"","components":[],"mode":"replace"}"#
    private let unsolicitedTheme =
        #"{"type":"chrome_surface","surface_key":"theme","title":"Appearance","components":[{"type":"text","content":"Pick a theme"}]}"#

    private func signedInModel() -> AppModel {
        let suite = "AppModelChromeSurfaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        suites.append(suite)
        let model = AppModel(
            conversationResumeStore: ConversationResumeStore(defaults: defaults),
            tokenStore: InMemoryTokenStore(), defaults: defaults)
        model.signedIn = true
        return model
    }

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites.removeAll()
        super.tearDown()
    }

    private func reduce(_ model: AppModel, _ json: String) {
        model.handleFrame(InboundFrame.parse(json)!)
    }

    func testMandatoryUnsolicitedSurfaceIsAcceptedAndPinned() {
        let model = signedInModel()
        reduce(model, mandatoryLLM)
        XCTAssertEqual(model.screen, .surface)
        XCTAssertEqual(model.pendingSurfaceKey, "llm")
        XCTAssertEqual(model.pendingSurface?.title, "Set up your AI provider")
        XCTAssertEqual(model.pendingSurface?.components.count, 1)
        XCTAssertTrue(model.mandatorySurface)
        XCTAssertNil(model.errorBanner)
    }

    func testBlankCloseClearsTheMandatoryPin() {
        let model = signedInModel()
        reduce(model, mandatoryLLM)
        reduce(model, blankClose)
        XCTAssertFalse(model.mandatorySurface)
        XCTAssertEqual(model.screen, .chat)
        XCTAssertNil(model.pendingSurface)
        XCTAssertEqual(model.pendingSurfaceKey, "")
    }

    func testNonMandatoryUnsolicitedSurfaceStillDemotesToBanner() {
        let model = signedInModel()
        reduce(model, unsolicitedTheme)
        XCTAssertEqual(model.screen, .chat)
        XCTAssertFalse(model.mandatorySurface)
        XCTAssertNil(model.pendingSurface)
        XCTAssertEqual(model.errorBanner, "Appearance: Pick a theme")
        XCTAssertTrue(model.bannerIsError)
    }

    func testNavigationSuppressedWhileMandatoryAndRestoredAfterClose() {
        let model = signedInModel()
        model.turns = [.init(id: "u0", role: "user", text: "hello")]
        reduce(model, mandatoryLLM)

        model.goTo(.history)
        XCTAssertEqual(model.screen, .surface)
        XCTAssertFalse(model.historyLoading)
        model.toggleHistory()
        model.closeSurface()
        XCTAssertEqual(model.screen, .surface)
        XCTAssertEqual(model.pendingSurface?.title, "Set up your AI provider")

        model.newChat()
        XCTAssertEqual(model.screen, .surface)
        XCTAssertEqual(model.turns.count, 1)

        model.openSurface("theme")
        XCTAssertEqual(model.pendingSurfaceKey, "llm")

        reduce(model, blankClose)
        model.goTo(.history)
        XCTAssertEqual(model.screen, .history)
    }

    func testHistoryToggleClosesWithoutRequestingHistoryOrHydratingAgain() {
        let model = signedInModel()
        model.activeChatId = "current-chat"
        model.composerDraft = "Draft to keep"
        model.canvas = [AstralComponent(type: "text", raw: .object(["content": .string("Current result")]))]
        model.turns = [.init(id: "current-turn", role: "assistant", text: "Current conversation")]
        let canvas = model.canvas
        let turns = model.turns
        var actions: [String] = []
        model.outboundTap = { raw in
            if let action = (try? JSONValue.parse(Data(raw.utf8)))?["action"]?.stringValue {
                actions.append(action)
            }
        }
        model.toggleHistory()
        XCTAssertEqual(model.screen, .history)
        XCTAssertEqual(actions, ["get_history"])
        model.toggleHistory()
        XCTAssertEqual(model.screen, .chat)
        XCTAssertEqual(actions, ["get_history"])
        XCTAssertEqual(model.activeChatId, "current-chat")
        XCTAssertEqual(model.composerDraft, "Draft to keep")
        XCTAssertEqual(model.canvas, canvas)
        XCTAssertEqual(model.turns, turns)
        model.toggleHistory()
        XCTAssertEqual(actions, ["get_history", "get_history"])
    }

    func testCloseLoadedAndPendingSurfacesPreservesWorkspaceAndNeverDispatches() {
        let model = signedInModel()
        model.activeChatId = "current-chat"
        model.composerDraft = "Draft to keep"
        model.canvas = [AstralComponent(type: "text", raw: .object(["content": .string("Current result")]))]
        let canvas = model.canvas
        var sent = 0
        model.outboundTap = { _ in sent += 1 }
        for loaded in [false, true] {
            model.openSurface("theme")
            if loaded { reduce(model, unsolicitedTheme) }
            let beforeClose = sent
            model.closeSurface()
            XCTAssertEqual(model.screen, .chat)
            XCTAssertNil(model.pendingSurface)
            XCTAssertEqual(model.pendingSurfaceKey, "")
            XCTAssertEqual(model.activeChatId, "current-chat")
            XCTAssertEqual(model.composerDraft, "Draft to keep")
            XCTAssertEqual(model.canvas, canvas)
            XCTAssertEqual(sent, beforeClose)
        }
    }

    func testExplicitSurfaceRetryKeepsParametersAndCannotResendAfterClose() {
        let model = signedInModel()
        var payloads: [JSONValue] = []
        model.outboundTap = { raw in
            if let payload = (try? JSONValue.parse(Data(raw.utf8)))?["payload"] {
                payloads.append(payload)
            }
        }
        let parameters: JSONValue = .object(["section": .string("colors")])
        model.openSurface("theme", params: parameters)
        model.retryPendingSurface()
        XCTAssertEqual(payloads.count, 2)
        for payload in payloads {
            XCTAssertEqual(payload["surface"], .string("theme"))
            XCTAssertEqual(payload["params"], parameters)
        }
        model.closeSurface()
        model.retryPendingSurface()
        XCTAssertEqual(payloads.count, 2)
    }

    func testSignOutStaysAvailableWhileMandatory() async {
        let model = signedInModel()
        reduce(model, mandatoryLLM)
        await model.signOut(revokeRemote: false)
        XCTAssertFalse(model.signedIn)
        XCTAssertFalse(model.mandatorySurface)
    }
}

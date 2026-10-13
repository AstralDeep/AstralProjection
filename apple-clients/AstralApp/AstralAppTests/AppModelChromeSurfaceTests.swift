// Tests for AppModel's chrome_surface reduce logic: the mandatory first-run gate pins navigation on an
// unsolicited surface, a blank close lifts it, and every entry point but sign-out stays suppressed while
// pinned.

import AstralCore
import SwiftUI
import XCTest

@testable import AstralDeep

#if canImport(UIKit)
    import UIKit
#endif

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
        model.connected = true
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

    private func evidenceFixture() throws -> JSONValue {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let file = root.appendingPathComponent("contracts/fixtures/evidence/inspection_surface.json")
            if FileManager.default.fileExists(atPath: file.path) { return try JSONValue.parse(Data(contentsOf: file)) }
            root.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func pendingEvidence(_ model: AppModel) throws -> InboundFrame {
        XCTAssertTrue(model.beginConversationConnection("22222222-2222-4222-8222-222222222222"))
        let fixture = try evidenceFixture()
        var sent: JSONValue?
        model.outboundTap = { sent = try! JSONValue.parse(Data($0.utf8)) }
        model.openSurface("evidence", params: fixture["request"]!["payload"]!["params"]!)
        var fields = try XCTUnwrap(fixture["native_frame"]?.objectValue)
        fields["request_generation"] = try XCTUnwrap(sent?["request_generation"])
        return InboundFrame(name: "chrome_surface", payload: .object(fields))
    }

    func testEvidenceGoldenReleasesOneCurrentLiteralModalAtFullPageLimit() throws {
        let model = signedInModel()
        let frame = try pendingEvidence(model)
        let canvas = model.canvas
        let turns = model.turns
        model.handleFrame(frame)
        let displayed = try XCTUnwrap(model.pendingSurface)
        let source = try XCTUnwrap(evidenceFixture()["source_text"]?.stringValue)
        XCTAssertEqual(displayed.components.first { $0.type == "keyvalue" }?.keyValuePairs.first?.1, source)
        XCTAssertEqual(model.canvas, canvas)
        XCTAssertEqual(model.turns, turns)
        var duplicate = frame.payload.objectValue!
        duplicate["title"] = .string("Duplicate")
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(duplicate)))
        XCTAssertEqual(model.pendingSurface, displayed)
        var retried: JSONValue?
        model.outboundTap = { retried = try! JSONValue.parse(Data($0.utf8)) }
        model.retryPendingSurface()
        let generation = try XCTUnwrap(retried?["request_generation"]?.stringValue)
        let page = String(repeating: "🙂", count: 4096)
        duplicate["request_generation"] = .string(generation)
        duplicate["components"] = .array([
            .object([
                "type": .string("keyvalue"),
                "items": .array([.object(["key": .string("Permitted text"), "value": .string(page)])]),
            ])
        ])
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(duplicate)))
        XCTAssertEqual(model.pendingSurface?.components.first?.keyValuePairs.first?.1, page)
    }

    func testEvidenceRejectsUncorrelatedMalformedAndUnsolicitedReplies() throws {
        let invalid: [(String, JSONValue?)] = [
            ("request_generation", nil), ("request_generation", .null),
            ("request_generation", .string("bad")),
            ("request_generation", .string("33333333-3333-4333-8333-333333333333")),
            ("request_generation", .string("F384F57F-2362-4545-92E8-61B1CE0C112E")),
            ("request_generation", .string("f384f57f-2362-5545-92e8-61b1ce0c112e")),
            ("region", .string("canvas")), ("mode", .string("mandatory")), ("title", .number(7)),
            ("surface_key", .number(7)), ("surface_key", .null),
            ("admin_only", .bool(true)), ("components", .object([:])),
            ("components", .array([.string("untrusted")])), ("extra", .string("untrusted")),
        ]
        for (key, value) in invalid {
            let model = signedInModel()
            let frame = try pendingEvidence(model)
            var fields = frame.payload.objectValue!
            fields[key] = value
            model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(fields)))
            XCTAssertNil(model.pendingSurface, key)
            model.handleFrame(frame)
            XCTAssertNotNil(model.pendingSurface, key)
        }
        let model = signedInModel()
        let fixture = try evidenceFixture()
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: fixture["native_frame"]!))
        XCTAssertNil(model.pendingSurface)
        XCTAssertNil(model.errorBanner)
    }

    func testEvidenceNavigationPayloadStaysUnscopedAndExactCloseIsLocal() throws {
        let model = signedInModel()
        let first = try pendingEvidence(model)
        model.handleFrame(first)
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        let params: JSONValue = .object(["view_id": .string("view_" + String(repeating: "a", count: 43))])
        model.emit("chrome_open", payload: ["surface": .string("evidence"), "params": params])
        let next = try XCTUnwrap(sent.last)
        XCTAssertEqual(next["session_id"], .null)
        XCTAssertEqual(
            Set(next["payload"]!.objectValue!.keys), ["surface", "params", "submission_id", "request_generation"])
        XCTAssertEqual(next["payload"]?["params"], params)
        XCTAssertNotEqual(next["request_generation"], first.payload["request_generation"])
        XCTAssertNil(model.pendingSurface)
        model.handleFrame(first)
        XCTAssertNil(model.pendingSurface)
        model.sendEvent("chrome_close", .object(["surface": .string("evidence")]))
        XCTAssertEqual(sent.count, 1)
        XCTAssertNil(model.pendingSurface)
        XCTAssertEqual(model.screen, .chat)
        model.handleFrame(first)
        XCTAssertNil(model.pendingSurface)
    }

    func testEvidenceCurrentCorrelatedCloseConsumesOnceAndChangedChatRejectsReply() throws {
        let model = signedInModel()
        let frame = try pendingEvidence(model)
        model.activeChatId = "44444444-4444-4444-8444-444444444444"
        model.handleFrame(frame)
        XCTAssertNil(model.pendingSurface)
        model.activeChatId = nil
        var fields = frame.payload.objectValue!
        fields["surface_key"] = .string("")
        fields["title"] = .string("")
        fields["components"] = .array([])
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(fields)))
        XCTAssertEqual(model.screen, .chat)
        XCTAssertNil(model.pendingSurface)
        model.handleFrame(frame)
        XCTAssertNil(model.pendingSurface)
    }

    func testEvidenceTimeoutRetiresOnlyCurrentRequestAndRetryCannotReplayIt() throws {
        let model = signedInModel()
        let first = try pendingEvidence(model)
        let firstGeneration = try XCTUnwrap(model.evidenceReadGeneration)
        var wire: String?
        model.outboundTap = { wire = $0 }
        model.retryPendingSurface()
        let current = try XCTUnwrap(model.evidenceReadGeneration)
        XCTAssertNotEqual(firstGeneration, current)
        model.failEvidenceRead(generation: firstGeneration)
        XCTAssertEqual(model.evidenceReadGeneration, current)
        model.failEvidenceRead(generation: current)
        XCTAssertNil(model.evidenceReadGeneration)
        XCTAssertNil(model.pendingSurface)
        XCTAssertNotNil(model.surfaceFailureMessage)
        model.handleFrame(first)
        XCTAssertNil(model.pendingSurface)
        let queued = try XCTUnwrap(QueuedOperationReplay(frameText: try XCTUnwrap(wire)))
        XCTAssertFalse(model.replayQueuedOperation(queued))
        model.retryPendingSurface()
        XCTAssertNotEqual(model.evidenceReadGeneration, current)
        XCTAssertNil(model.surfaceFailureMessage)
    }

    func testEvidenceFullPageRendererPreservesTheFinalUnicodePageCharacters() throws {
        let model = signedInModel()
        let frame = try pendingEvidence(model)
        let page = String(repeating: "🙂", count: 4095) + "TAIL"
        XCTAssertEqual(page.utf8.count, 16_384)
        var fields = frame.payload.objectValue!
        fields["components"] = .array([
            .object([
                "type": .string("keyvalue"),
                "items": .array([
                    .object(["key": .string("Permitted text"), "value": .string(page)])
                ]),
            ])
        ])
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(fields)))
        let component = try XCTUnwrap(model.pendingSurface?.components.first)
        XCTAssertEqual(component.keyValuePairs.first?.1, page)
        func rendered(_ component: AstralComponent) throws -> (Data, CGFloat) {
            let renderer = ImageRenderer(
                content: ComponentView(component: component).environment(model).environment(model.themeStore)
                    .environment(\.astralWorkReadSurface, true)
                    .frame(width: 1024).fixedSize(horizontal: false, vertical: true))
            #if os(iOS)
                let image = try XCTUnwrap(renderer.uiImage)
                return (try XCTUnwrap(image.pngData()), image.size.height)
            #else
                let image = try XCTUnwrap(renderer.nsImage)
                return (try XCTUnwrap(image.tiffRepresentation), image.size.height)
            #endif
        }
        func replacingPage(_ text: String) throws -> AstralComponent {
            var raw = try XCTUnwrap(component.raw.objectValue)
            raw["items"] = .array([
                .object(["key": .string("Permitted text"), "value": .string(text)])
            ])
            return try XCTUnwrap(AstralComponent(json: .object(raw)))
        }
        let full = try rendered(component)
        let shortened = try rendered(replacingPage(String(page.prefix(2048))))
        let changedTail = try rendered(replacingPage(String(page.dropLast()) + "X"))
        XCTAssertGreaterThan(full.1, shortened.1)
        XCTAssertNotEqual(full.0, shortened.0)
        XCTAssertNotEqual(full.0, changedTail.0)
    }

    func testEvidenceHostedSurfaceRetiresItsActualTimerAndRejectsLateReplay() async throws {
        #if canImport(UIKit)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let model = signedInModel()
            let frame = try pendingEvidence(model)
            let source = try XCTUnwrap(evidenceFixture()["source_text"]?.stringValue)
            let page = String(repeating: "🙂", count: 4096)
            var fields = frame.payload.objectValue!
            fields["components"] = .array([
                .object(["type": .string("alert"), "message": .string(source)]),
                .object([
                    "type": .string("keyvalue"),
                    "items": .array([
                        .object(["key": .string("Permitted text"), "value": .string(page)])
                    ]),
                ]),
            ])
            model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(fields)))
            let controller = UIHostingController(
                rootView: SurfaceView(embedded: true).environment(model).environment(model.themeStore))
            let window = UIWindow(windowScene: scene)
            let prior = scene.windows.first { $0.isKeyWindow }
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                prior?.makeKeyAndVisible()
            }
            controller.view.layoutIfNeeded()
            XCTAssertNotNil(controller.view.window)
            XCTAssertEqual(model.pendingSurface?.components.last?.keyValuePairs.first?.1, page)
            let currentFrame = try pendingEvidence(model)
            let current = try XCTUnwrap(model.evidenceReadGeneration)
            let retired = expectation(description: "evidence generation retired by actual SurfaceView timer")
            let wait = Task {
                while !Task.isCancelled {
                    if model.evidenceReadGeneration == nil, model.surfaceFailureMessage != nil {
                        retired.fulfill()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            }
            await fulfillment(of: [retired], timeout: 30)
            wait.cancel()
            XCTAssertNil(model.evidenceReadGeneration)
            XCTAssertNil(model.pendingSurface)
            model.handleFrame(currentFrame)
            XCTAssertNil(model.pendingSurface)
            model.retryPendingSurface()
            XCTAssertNotEqual(model.evidenceReadGeneration, current)
        #else
            throw XCTSkip("Hosted SwiftUI evidence coverage uses the isolated iOS test destination")
        #endif
    }

    func testEvidenceRetirementErasesTextAndLateRepliesAcrossConversationAndConnection() async throws {
        for retirement in ["new", "open", "send", "close", "disconnect", "registration", "owner"] {
            for loaded in [false, true] {
                let model = signedInModel()
                let frame = try pendingEvidence(model)
                if loaded { model.handleFrame(frame) }
                switch retirement {
                case "new": model.newChat()
                case "open": model.openChat("44444444-4444-4444-8444-444444444444")
                case "send": model.sendChat("New question")
                case "close": model.closeSurface()
                case "disconnect": await model.handle(.disconnected(reason: "Synthetic disconnect"))
                case "registration":
                    XCTAssertTrue(model.beginConversationConnection("33333333-3333-4333-8333-333333333333"))
                default:
                    model.bindConversationAccount(
                        ConversationAccount(issuer: "https://iam.example.test", subject: "other")!)
                }
                model.handleFrame(frame)
                XCTAssertNil(model.pendingSurface, retirement)
            }
        }
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

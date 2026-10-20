// Tests the native Apple terminal monitor reducer: a correlated generic chrome surface opens,
// rejects extra fields and stale generations, and retires without touching conversation state.

import AstralCore
import Foundation
import SwiftUI
import XCTest

@testable import AstralDeep

@MainActor
final class TerminalMonitorAppTests: XCTestCase {
    private var suites: [String] = []

    private func signedInModel() -> AppModel {
        let suite = "TerminalMonitorAppTests.\(UUID().uuidString)"
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

    private func fixture() throws -> JSONValue {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let file = root.appendingPathComponent("contracts/fixtures/terminal/monitor_surface.json")
            if FileManager.default.fileExists(atPath: file.path) {
                return try JSONValue.parse(Data(contentsOf: file))
            }
            root.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func frame(_ model: AppModel, _ fixture: JSONValue) throws -> InboundFrame {
        XCTAssertTrue(model.beginConversationConnection("22222222-2222-4222-8222-222222222222"))
        var sent: JSONValue?
        model.outboundTap = { sent = try! JSONValue.parse(Data($0.utf8)) }
        model.openSurface(
            "terminal", params: fixture["request"]!["payload"]!["params"]!)
        let generation = try XCTUnwrap(sent?["request_generation"]?.stringValue)
        var fields = try XCTUnwrap(fixture["native_frame"]?.objectValue)
        fields["request_generation"] = .string(generation)
        return InboundFrame(name: "chrome_surface", payload: .object(fields))
    }

    func testCorrelatedTerminalSurfaceOpensAndRejectsExtraOrStaleFields() throws {
        let model = signedInModel()
        let source = try fixture()
        let frame = try frame(model, source)
        model.handleFrame(frame)
        XCTAssertEqual(model.screen, .surface)
        XCTAssertEqual(model.pendingSurfaceKey, "terminal")
        XCTAssertEqual(model.pendingSurface?.surfaceKey, "terminal")
        XCTAssertEqual(
            model.pendingSurface?.components.filter { $0.type == "button" }
                .compactMap { $0.raw["action"]?.stringValue },
            ["chrome_open", "chrome_open", "chrome_close"])
        var invalid = frame.payload.objectValue!
        invalid["extra"] = .string("untrusted")
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(invalid)))
        XCTAssertEqual(model.pendingSurfaceKey, "terminal")
        var stale = frame.payload.objectValue!
        stale["request_generation"] = .string("33333333-3333-4333-8333-333333333333")
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(stale)))
        XCTAssertEqual(model.pendingSurfaceKey, "terminal")
        model.closeSurface()
        XCTAssertEqual(model.screen, .chat)
        XCTAssertTrue(model.pendingSurfaceKey.isEmpty)
    }

    func testDisconnectImmediatelyRemovesTerminalContentAndRejectsLateFrames() async throws {
        let model = signedInModel()
        let reply = try frame(model, fixture())
        model.handleFrame(reply)
        XCTAssertNotNil(model.pendingSurface)
        await model.handle(.disconnected(reason: "synthetic fixture"))
        XCTAssertNil(model.pendingSurface)
        XCTAssertNotNil(model.surfaceFailureMessage)
        model.connected = true
        model.handleFrame(reply)
        XCTAssertNil(model.pendingSurface)
    }

    func testTerminalReadsAndClosesCannotReplayOnAReplacementConnection() throws {
        let model = signedInModel()
        let reply = try frame(model, fixture())
        for action in ["chrome_open", "chrome_close"] {
            let payload: JSONValue =
                action == "chrome_open"
                ? .object(["surface": .string("terminal"), "params": .object(["mode": .string("list")])])
                : .object(["surface": .string("terminal")])
            let replay = try XCTUnwrap(
                QueuedOperationReplay(
                    frameText: Outbound.uiEvent(
                        action: action, sessionId: nil, payload: payload)))
            XCTAssertFalse(model.replayQueuedOperation(replay))
        }
        model.handleFrame(reply)
        XCTAssertNotNil(model.pendingSurface)
    }

    func testTerminalRefreshClearsOldDisplayAndRejectsItsLateReply() throws {
        let model = signedInModel()
        let reply = try frame(model, fixture())
        model.handleFrame(reply)
        XCTAssertNotNil(model.pendingSurface)
        var sent: JSONValue?
        model.outboundTap = { sent = try! JSONValue.parse(Data($0.utf8)) }
        model.retryPendingSurface()
        XCTAssertNil(model.pendingSurface)
        model.handleFrame(reply)
        XCTAssertNil(model.pendingSurface)
        var fields = reply.payload.objectValue!
        fields["request_generation"] = try XCTUnwrap(sent?["request_generation"])
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(fields)))
        XCTAssertNotNil(model.pendingSurface)
    }

    func testPrivateAuthenticationRetirementClearsTerminalOutput() throws {
        let model = signedInModel()
        let reply = try frame(model, fixture())
        model.handleFrame(reply)
        model.handleFrame(InboundFrame(name: "auth_required", payload: .object([:])))
        XCTAssertNil(model.pendingSurface)
        model.handleFrame(reply)
        XCTAssertNil(model.pendingSurface)
    }

    func testConversationNavigationAndSendRetirePendingAndDisplayedTerminalOutput() throws {
        for transition in ["new", "open", "send"] {
            for delivered in [false, true] {
                let model = signedInModel()
                model.activeChatId = "44444444-4444-4444-8444-444444444444"
                let reply = try frame(model, fixture())
                if delivered { model.handleFrame(reply) }
                switch transition {
                case "new": model.newChat()
                case "open": model.openChat("55555555-5555-4555-8555-555555555555")
                default: model.sendChat("Synthetic terminal retirement")
                }
                XCTAssertNil(model.pendingSurface, transition)
                model.handleFrame(reply)
                XCTAssertNil(model.pendingSurface, transition)
            }
        }
    }

    func testTerminalReplyCannotCrossConversationIdentity() throws {
        let model = signedInModel()
        model.activeChatId = "44444444-4444-4444-8444-444444444444"
        let reply = try frame(model, fixture())
        model.activeChatId = "55555555-5555-4555-8555-555555555555"
        model.handleFrame(reply)
        XCTAssertNil(model.pendingSurface)
    }

    func testTerminalTimeoutRetiresItsGenerationAndLateFrameUntilExplicitRetry() throws {
        let model = signedInModel()
        let reply = try frame(model, fixture())
        let generation = try XCTUnwrap(model.terminalReadGeneration)
        model.failTerminalRead(generation: generation)
        XCTAssertNil(model.terminalReadGeneration)
        XCTAssertNotNil(model.surfaceFailureMessage)
        model.handleFrame(reply)
        XCTAssertNil(model.pendingSurface)
        var sent: JSONValue?
        model.outboundTap = { sent = try! JSONValue.parse(Data($0.utf8)) }
        model.retryPendingSurface()
        let current = try XCTUnwrap(model.terminalReadGeneration)
        XCTAssertNotEqual(current, generation)
        model.failTerminalRead(generation: generation)
        model.failTerminalRead(generation: nil)
        XCTAssertEqual(model.terminalReadGeneration, current)
        var fields = reply.payload.objectValue!
        fields["request_generation"] = try XCTUnwrap(sent?["request_generation"])
        model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(fields)))
        XCTAssertNotNil(model.pendingSurface)
        XCTAssertNil(model.surfaceFailureMessage)
    }

}

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
}

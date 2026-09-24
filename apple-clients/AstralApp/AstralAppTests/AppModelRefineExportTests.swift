// Tests for AppModel's refine/export send paths: the Refine sheet posts a trimmed component_refine ui_event,
// refine/restore are blocked while the timeline is read-only, and export URLs are chat-scoped or nil without
// an active chat.

import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
final class AppModelRefineExportTests: XCTestCase {

    private final class FrameLog {
        var frames: [JSONValue] = []
    }

    private func record(_ model: AppModel) -> FrameLog {
        let log = FrameLog()
        model.outboundTap = { text in
            if let json = try? JSONValue.parse(Data(text.utf8)) { log.frames.append(json) }
        }
        return log
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "serverBase")
        super.tearDown()
    }

    func testRefineSendsComponentRefineUiEvent() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.activeChatId = "chat-1"
        let log = record(model)
        model.refineComponent("wc_budget", instruction: "  make it monthly  ")
        XCTAssertEqual(log.frames.count, 1)
        let frame = log.frames[0]
        XCTAssertEqual(frame["type"]?.stringValue, "ui_event")
        XCTAssertEqual(frame["action"]?.stringValue, "component_refine")
        XCTAssertEqual(frame["session_id"]?.stringValue, "chat-1")
        XCTAssertEqual(frame["payload"]?["component_id"]?.stringValue, "wc_budget")
        XCTAssertEqual(frame["payload"]?["instruction"]?.stringValue, "make it monthly")
    }

    func testRefineEmptyInstructionNeverSends() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        let log = record(model)
        model.refineComponent("wc_budget", instruction: "   \n ")
        XCTAssertTrue(log.frames.isEmpty)
    }

    func testRefineEmptyComponentIdNeverSends() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        let log = record(model)
        model.refineComponent("", instruction: "sort it")
        XCTAssertTrue(log.frames.isEmpty)
    }

    func testRefineAndRestoreBlockedWhileTimelineReadOnly() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.handleFrame(InboundFrame.parse(#"{"type":"workspace_timeline_mode","active":true}"#)!)
        let log = record(model)
        model.refineComponent("wc_budget", instruction: "sort it")
        model.sendEvent(
            "component_restore",
            .object([
                "component_id": .string("wc_budget"), "version_no": .number(2),
            ]))
        XCTAssertTrue(log.frames.isEmpty)
        model.handleFrame(InboundFrame.parse(#"{"type":"workspace_timeline_mode","active":false}"#)!)
        model.refineComponent("wc_budget", instruction: "sort it")
        XCTAssertEqual(log.frames.count, 1)
    }

    func testExportComponentURLIsChatScoped() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.serverBaseText = "https://astral.example"
        model.activeChatId = "chat-9"
        XCTAssertEqual(
            model.exportComponentURL("wc_tbl")?.absoluteString,
            "https://astral.example/api/export/component/wc_tbl.csv?chat_id=chat-9")
    }

    func testExportCanvasURL() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.serverBaseText = "https://astral.example"
        model.activeChatId = "chat-9"
        XCTAssertEqual(
            model.exportCanvasURL()?.absoluteString,
            "https://astral.example/api/export/canvas/chat-9.html")
    }

    func testExportURLsNilWithoutActiveChat() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.serverBaseText = "https://astral.example"
        model.activeChatId = nil
        XCTAssertNil(model.exportComponentURL("wc_tbl"))
        XCTAssertNil(model.exportCanvasURL())
    }
}

// Tests for AppModel's background-task reduce logic: task_completed/notification frames for the open chat
// reload it, frames for other chats banner instead, and reconnect reissues load_chat for the active chat.

import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
final class AppModelBackgroundContinuityTests: XCTestCase {

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

    private func reduce(_ model: AppModel, _ json: String) {
        model.handleFrame(InboundFrame.parse(json)!)
    }

    private func loadChats(_ log: FrameLog) -> [String] {
        log.frames
            .filter { $0["action"]?.stringValue == "load_chat" }
            .compactMap { $0["payload"]?["chat_id"]?.stringValue }
    }

    func testTaskCompletedForOpenChatReloadsIt() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.activeChatId = "c1"
        let log = record(model)
        reduce(model, #"{"type":"task_completed","payload":{"task_id":"t1","chat_id":"c1","status":"completed"}}"#)
        XCTAssertEqual(loadChats(log), ["c1"])
        XCTAssertEqual(model.errorBanner, "Background task finished")
        XCTAssertFalse(model.bannerIsError)
    }

    func testTaskCompletedForOtherChatBannersWithoutReload() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.activeChatId = "c1"
        let log = record(model)
        reduce(model, #"{"type":"task_completed","payload":{"task_id":"t1","chat_id":"c2","status":"completed"}}"#)
        XCTAssertTrue(loadChats(log).isEmpty)
        XCTAssertEqual(model.errorBanner, "Background task finished in another chat")
        XCTAssertFalse(model.bannerIsError)
    }

    func testTaskCompletedWithoutChatIdKeepsIssuingSocketBehavior() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.activeChatId = "c1"
        let log = record(model)
        reduce(model, #"{"type":"task_completed","payload":{"task_id":"t1","status":"completed"}}"#)
        XCTAssertEqual(loadChats(log), ["c1"])
        XCTAssertEqual(model.errorBanner, "Background task finished")
    }

    func testTaskStartedForOpenChatSetsStatusLine() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.activeChatId = "c1"
        reduce(model, #"{"type":"task_started","payload":{"task_id":"t1","chat_id":"c1","status":"queued"}}"#)
        XCTAssertEqual(model.statusText, "Working in the background…")
        XCTAssertTrue(model.asyncDetached)
        XCTAssertNil(model.errorBanner)
    }

    func testTaskStartedForOtherChatBannersInstead() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.activeChatId = "c1"
        reduce(model, #"{"type":"task_started","payload":{"task_id":"t1","chat_id":"c2","status":"queued"}}"#)
        XCTAssertNil(model.statusText)
        XCTAssertFalse(model.asyncDetached)
        XCTAssertEqual(model.errorBanner, "Background task started in another chat")
        XCTAssertFalse(model.bannerIsError)
    }

    func testNotificationForOpenChatBannersAndReloads() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.activeChatId = "c1"
        let log = record(model)
        reduce(
            model, #"{"type":"notification","level":"info","chat_id":"c1","title":"Job done","body":"Digest ready"}"#)
        XCTAssertEqual(model.errorBanner, "Job done: Digest ready")
        XCTAssertFalse(model.bannerIsError)
        XCTAssertEqual(loadChats(log), ["c1"])
    }

    func testNotificationForOtherChatBannersWithoutReload() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.activeChatId = "c1"
        let log = record(model)
        reduce(model, #"{"type":"notification","level":"error","chat_id":"c2","title":"Job failed","body":"boom"}"#)
        XCTAssertEqual(model.errorBanner, "Job failed: boom")
        XCTAssertTrue(model.bannerIsError)
        XCTAssertTrue(loadChats(log).isEmpty)
    }

    func testChatAgnosticNotificationNeverReloads() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.activeChatId = "c1"
        let log = record(model)
        reduce(model, #"{"type":"notification","level":"info","title":"Reader live","body":"Ask again"}"#)
        XCTAssertEqual(model.errorBanner, "Reader live: Ask again")
        XCTAssertTrue(loadChats(log).isEmpty)
    }

    func testReconnectReissuesLoadChatForActiveChat() async {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.activeChatId = "c1"
        let log = record(model)
        await model.handle(.connected)
        XCTAssertEqual(loadChats(log), ["c1"])
    }

    func testFirstConnectWithoutActiveChatSendsNothing() async {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        let log = record(model)
        await model.handle(.connected)
        XCTAssertTrue(log.frames.isEmpty)
    }
}

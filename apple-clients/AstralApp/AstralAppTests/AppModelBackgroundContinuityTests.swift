// Tests for AppModel's background-task reduce logic: task_completed/notification frames for the open chat
// reload it, task frames for other chats stay quiet, and reconnect reissues load_chat for the active chat.

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

    private let liveChat = "11111111-1111-4111-8111-111111111111"

    private func taskFrame(_ type: String, status: String, summary: String? = nil) -> String {
        let field = summary.map { #","summary":"\#($0)""# } ?? ""
        let task = #"{"task_id":"t1","chat_id":"\#(liveChat)","status":"\#(status)"\#(field)}"#
        return #"{"type":"\#(type)","payload":\#(task)}"#
    }

    private func connectedModel() -> AppModel {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.bindConversationAccount(ConversationAccount(issuer: "https://test.invalid", subject: "background-owner")!)
        model.signedIn = true
        model.connected = true
        XCTAssertTrue(model.beginConversationConnection(UUID().uuidString.lowercased()))
        XCTAssertTrue(
            model.openConversationRequest(
                chatId: liveChat, requestGeneration: UUID().uuidString.lowercased(), purpose: .hydration))
        model.activeChatId = liveChat
        return model
    }

    func testTaskCompletedOnALiveConnectionReloadsTheOpenChat() {
        let model = connectedModel()
        let log = record(model)
        reduce(model, taskFrame("task_started", status: "running"))
        XCTAssertTrue(model.asyncDetached)
        reduce(model, taskFrame("task_completed", status: "completed"))
        XCTAssertEqual(loadChats(log), [liveChat])
        XCTAssertFalse(model.asyncDetached)
        XCTAssertEqual(model.errorBanner, "Background task finished")
        XCTAssertFalse(model.bannerIsError)
    }

    func testAFailedBackgroundTaskShowsItsSummaryAsAnError() {
        let model = connectedModel()
        reduce(model, taskFrame("task_completed", status: "failed", summary: "The model was unavailable."))
        XCTAssertEqual(model.errorBanner, "The model was unavailable.")
        XCTAssertTrue(model.bannerIsError)
    }

    func testAFailedBackgroundTaskWithoutASummaryNeverSaysFinished() {
        let model = connectedModel()
        reduce(model, taskFrame("task_completed", status: "retryable"))
        XCTAssertEqual(model.errorBanner, "The background task did not finish.")
        XCTAssertTrue(model.bannerIsError)
    }

    func testAnEmptyOrBlankSummaryFallsBackToTheFailureMessage() {
        for summary in ["", "   "] {
            let model = connectedModel()
            reduce(model, taskFrame("task_completed", status: "failed", summary: summary))
            XCTAssertEqual(model.errorBanner, "The background task did not finish.")
            XCTAssertTrue(model.bannerIsError)
        }
    }

    func testATaskEndingDuringALiveTurnKeepsThatTurnAndItsPreview() {
        let model = connectedModel()
        let log = record(model)
        reduce(model, taskFrame("task_started", status: "running"))
        model.sendChat("And the budget table?")
        let preview = model.transientTurns
        XCTAssertTrue(model.turnActive)
        XCTAssertFalse(preview.isEmpty)
        reduce(model, taskFrame("task_completed", status: "completed"))
        XCTAssertEqual(loadChats(log), [])
        XCTAssertTrue(model.turnActive)
        XCTAssertEqual(model.transientTurns, preview)
        XCTAssertEqual(model.errorBanner, "Background task finished")
    }

    func testEachSignOfALiveTurnSkipsTheReload() {
        let signs: [(String, (AppModel) -> Void)] = [
            ("turn active", { $0.turnActive = true }),
            (
                "live preview",
                { $0.transientTurns = [AppModel.ChatTurn(id: "pending-user-1", role: "user", text: "Next")] }
            ),
            (
                "pending commit",
                { model in
                    model.activeChatId = nil
                    model.sendChat("Start a new chat")
                    model.turnActive = false
                    model.transientTurns = []
                    model.activeChatId = self.liveChat
                }
            ),
        ]
        for (name, apply) in signs {
            let model = connectedModel()
            apply(model)
            let log = record(model)
            let turnActive = model.turnActive
            reduce(model, taskFrame("task_completed", status: "completed"))
            XCTAssertEqual(loadChats(log), [], name)
            XCTAssertEqual(model.turnActive, turnActive, name)
            XCTAssertEqual(model.errorBanner, "Background task finished", name)
        }
    }

    func testACancelledBackgroundTaskIsNotAnError() {
        let model = connectedModel()
        reduce(model, taskFrame("task_completed", status: "cancelled"))
        XCTAssertEqual(model.errorBanner, "Background task cancelled")
        XCTAssertFalse(model.bannerIsError)
    }

    func testTaskCompletedForOtherChatStaysQuietWithoutReload() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.activeChatId = "c1"
        let log = record(model)
        reduce(model, #"{"type":"task_completed","payload":{"task_id":"t1","chat_id":"c2","status":"completed"}}"#)
        XCTAssertTrue(loadChats(log).isEmpty)
        XCTAssertNil(model.errorBanner)
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

    func testTaskStartedForOtherChatStaysQuiet() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.activeChatId = "c1"
        reduce(model, #"{"type":"task_started","payload":{"task_id":"t1","chat_id":"c2","status":"queued"}}"#)
        XCTAssertNil(model.statusText)
        XCTAssertFalse(model.asyncDetached)
        XCTAssertNil(model.errorBanner)
    }

    func testAttachingAnExistingFileStagesItWithoutABannerSentence() {
        let model = AppModel(tokenStore: InMemoryTokenStore())
        model.signedIn = true
        model.connected = true
        model.screen = .surface
        model.emit(
            "attach_existing",
            payload: [
                "attachment_id": .string("att-1"), "filename": .string("notes.pdf"), "category": .string("document"),
            ])
        XCTAssertEqual(model.staged.map(\.attachmentId), ["att-1"])
        XCTAssertEqual(model.screen, .chat)
        XCTAssertNil(model.errorBanner)
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
        XCTAssertEqual(model.errorBanner, "Job failed: boom — open it from History")
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

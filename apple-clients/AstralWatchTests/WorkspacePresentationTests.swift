import AstralCore
import XCTest

@testable import AstralWatch

@MainActor
final class WorkspacePresentationTests: XCTestCase {
    private let example = AstralComponent(
        json: .object([
            "type": .string("button"), "component_id": .string("wel_ex_research"),
            "data-welcome": .string("example"), "action": .string("chat_message"),
            "payload": .object(["message": .string("Research a topic")]),
        ]))!

    func testWelcomeExampleUsesOrdinaryChatAndPreservesDraft() throws {
        let model = WatchModel()
        var sent: JSONValue?
        model.outboundTap = { sent = try! JSONValue.parse(Data($0.utf8)) }
        model.pendingDictation = "Unsent draft"
        XCTAssertTrue(model.sendWelcomeExample(example))
        XCTAssertTrue(model.workspaceStarted)
        XCTAssertEqual(model.pendingDictation, "Unsent draft")
        XCTAssertEqual(sent?["action"], .string("chat_message"))
        XCTAssertEqual(sent?["payload"]?["message"], .string("Research a topic"))
        model.newConversation()
        XCTAssertFalse(model.workspaceStarted)
        XCTAssertEqual(model.pendingDictation, "")
    }

    func testUnrelatedActionsNeverDispatchFromWelcomeRenderer() {
        let model = WatchModel()
        var sent = 0
        model.outboundTap = { _ in sent += 1 }
        let invalid = AstralComponent(
            type: "button",
            raw: .object([
                "data-welcome": .string("example"), "action": .string("effect_approve"),
                "payload": .object(["message": .string("Do not dispatch")]),
            ]))
        XCTAssertFalse(model.sendWelcomeExample(invalid))
        XCTAssertEqual(sent, 0)
        XCTAssertFalse(model.workspaceStarted)
    }

    func testOwnerChangeClearsDraftWhileReconnectPreservesIt() async {
        let model = WatchModel()
        let first = ConversationAccount(issuer: "https://iam.example.test", subject: "first")!
        let second = ConversationAccount(issuer: "https://iam.example.test", subject: "second")!
        model.bindConversationAccount(first)
        model.pendingDictation = "Private pending text"
        model.bindConversationAccount(first)
        await model.handle(.disconnected(reason: "test disconnect"))
        XCTAssertEqual(model.pendingDictation, "Private pending text")
        model.bindConversationAccount(second)
        XCTAssertEqual(model.pendingDictation, "")
    }

    func testLateWelcomeDoesNotReplaceResultOrResetWorkMode() {
        let model = WatchModel()
        let result = AstralComponent(type: "text", raw: .object(["content": .string("Result")]))
        model.canvas = [result]
        model.handleFrame(
            InboundFrame.parse(
                #"{"type":"ui_render","target":"canvas","components":[{"type":"text","data-welcome":"intro","component_id":"wel_intro","content":"Welcome"}]}"#
            )!)
        XCTAssertEqual(model.workspaceCanvas, [result])
        model.canvas = []
        XCTAssertTrue(model.workspaceStarted)
    }
}

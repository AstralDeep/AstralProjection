import AstralCore
import XCTest

@testable import AstralWatch

@MainActor
final class WorkspacePresentationTests: XCTestCase {
    private func deliverDetachedResult(
        _ model: WatchModel, requestGeneration: String = "99999999-9999-4999-8999-999999999999"
    ) {
        model.handleFrame(
            InboundFrame.parse(
                """
                {"type":"conversation_commit_ready","schema_version":1,"chat_id":"\(chat)",
                 "connection_generation":"\(connection)","request_generation":"\(requestGeneration)","render_revision":1}
                """)!)
        model.handleFrame(
            InboundFrame.parse(
                """
                {"type":"conversation_snapshot","schema_version":1,
                 "snapshot_id":"55555555-5555-4555-8555-555555555555","chat_id":"\(chat)",
                 "connection_generation":"\(connection)","request_generation":"\(requestGeneration)",
                 "snapshot_purpose":"commit","render_revision":1,"committed_at":"2026-07-15T18:41:00Z",
                 "transcript":[],"canvas":{"target":"canvas","components":[{"type":"text","content":"Detached result"}]}}
                """)!)
    }

    func testOnlyCorrelatedDefinitiveTerminalOutcomesReleaseCommitFence() {
        for (state, statusConnection, statusRequest, released) in [
            ("failed", connection, request, true), ("cancelled", connection, request, true),
            ("retryable", connection, request, true), ("completed", connection, request, false),
            ("failed", "88888888-8888-4888-8888-888888888888", request, false),
            ("failed", connection, "88888888-8888-4888-8888-888888888888", false),
        ] {
            let model = WatchModel()
            XCTAssertTrue(model.beginConversationConnection(connection))
            XCTAssertTrue(model.openConversationRequest(chatId: chat, requestGeneration: request, purpose: .commit))
            let error = state == "completed" ? "null" : #"{"code":"operation_failed","message":"Attempt ended"}"#
            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"operation_status","operation_id":"44444444-4444-4444-8444-444444444444",
                     "action":"chat_message","surface":"chat","chat_id":"\(chat)",
                     "connection_generation":"\(statusConnection)","request_generation":"\(statusRequest)",
                     "sequence":1,"state":"\(state)","phase":"\(state)","label":"Attempt ended",
                     "terminal":true,"retryable":\(state == "retryable" ? "true" : "false"),"error":\(error),
                     "retry_after_ms":null,"updated_at":"2026-07-16T12:00:01Z"}
                    """)!)
            deliverDetachedResult(model)
            XCTAssertEqual(model.lastCommittedRenderRevision, released ? 1 : 0, state)
            XCTAssertEqual(model.canvas.map(\.fallbackText), released ? ["Detached result"] : [], state)
        }
    }

    func testAdmissionRefusalReleasesOnlyItsOwnPendingCommit() throws {
        let model = WatchModel()
        XCTAssertTrue(model.beginConversationConnection(connection))
        XCTAssertTrue(model.openConversationRequest(chatId: chat, requestGeneration: request, purpose: .hydration))
        var sent: JSONValue?
        model.outboundTap = { sent = try! JSONValue.parse(Data($0.utf8)) }
        model.pendingDictation = "Current attempt"
        model.sendPending()
        let submission = try XCTUnwrap(sent?["submission_id"]?.stringValue)
        for (identity, released) in [("88888888-8888-4888-8888-888888888888", false), (submission, true)] {
            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"error","submission_id":"\(identity)","accepted":false,
                     "code":"capacity_exceeded","message":"Try again shortly.","retryable":true,"retry_after_ms":1000}
                    """)!)
            deliverDetachedResult(model)
            XCTAssertEqual(model.lastCommittedRenderRevision, released ? 1 : 0)
        }
    }

    func testNewChatKeepsUsedRequestGenerationReplayProtection() {
        let model = WatchModel()
        XCTAssertTrue(model.beginConversationConnection(connection))
        XCTAssertTrue(model.openConversationRequest(chatId: chat, requestGeneration: request, purpose: .commit))
        model.newConversation()
        XCTAssertTrue(
            model.openConversationRequest(
                chatId: chat, requestGeneration: "88888888-8888-4888-8888-888888888888", purpose: .hydration))
        deliverDetachedResult(model, requestGeneration: request)
        XCTAssertEqual(model.lastCommittedRenderRevision, 0)
        XCTAssertTrue(model.visibleCanvas.isEmpty)
    }

    private let connection = "22222222-2222-4222-8222-222222222222"
    private let chat = "11111111-1111-4111-8111-111111111111"
    private let request = "33333333-3333-4333-8333-333333333333"
    private var welcomeFrame: InboundFrame {
        InboundFrame.parse(
            #"{"type":"ui_render","target":"canvas","components":[{"type":"hero","data-welcome":"intro","component_id":"wel_intro","title":"How can I help?"},{"type":"grid","data-welcome":"examples","component_id":"wel_examples","children":[]}]}"#
        )!
    }

    func testRegisteredConnectionAndNewChatAcceptOnlyEphemeralWelcome() {
        let model = WatchModel()
        XCTAssertTrue(model.beginConversationConnection(connection))
        model.handleFrame(welcomeFrame)
        XCTAssertEqual(model.visibleCanvas, welcomeFrame.renderComponents)
        XCTAssertFalse(model.workspaceStarted)
        XCTAssertNil(model.activeChatId)
        XCTAssertEqual(model.lastCommittedRenderRevision, 0)

        XCTAssertTrue(model.openConversationRequest(chatId: chat, requestGeneration: request, purpose: .hydration))
        model.newConversation()
        model.handleFrame(welcomeFrame)
        XCTAssertEqual(model.visibleCanvas, welcomeFrame.renderComponents)
        XCTAssertFalse(model.workspaceStarted)
        // chat_created binds the fresh locator; it must not turn welcome into
        // a committed preview or prevent a subsequent welcome re-adaptation.
        model.handleFrame(InboundFrame.parse("{\"type\":\"chat_created\",\"payload\":{\"chat_id\":\"\(chat)\"}}")!)
        var updated = welcomeFrame.payload.objectValue!
        updated["type"] = .string("ui_update")
        model.handleFrame(InboundFrame(name: "ui_update", payload: .object(updated)))
        XCTAssertEqual(model.visibleCanvas, welcomeFrame.renderComponents)
        XCTAssertFalse(model.workspaceStarted)
        XCTAssertEqual(model.activeChatId, chat)
    }

    func testWelcomeCannotBypassHydrationOrTransientScopeValidation() {
        let model = WatchModel()
        XCTAssertTrue(model.beginConversationConnection(connection))
        for scopeKey in [
            "chat_id", "connection_generation", "request_generation", "base_render_revision", "frame_sequence",
        ] {
            var scoped = welcomeFrame.payload.objectValue!
            scoped[scopeKey] = .null
            model.handleFrame(InboundFrame(name: "ui_render", payload: .object(scoped)))
            XCTAssertTrue(model.visibleCanvas.isEmpty)
        }
        var mixed = welcomeFrame.payload.objectValue!
        mixed["components"] = .array(
            welcomeFrame.payload["components"]!.arrayValue! + [
                .object(["type": .string("text"), "content": .string("Unscoped work must not be admitted")])
            ])
        model.handleFrame(InboundFrame(name: "ui_render", payload: .object(mixed)))
        XCTAssertTrue(model.visibleCanvas.isEmpty)
        XCTAssertFalse(model.workspaceStarted)
        XCTAssertTrue(model.openConversationRequest(chatId: chat, requestGeneration: request, purpose: .hydration))
        model.handleFrame(welcomeFrame)
        XCTAssertTrue(model.visibleCanvas.isEmpty)
        XCTAssertTrue(model.workspaceStarted)
        XCTAssertEqual(model.activeChatId, chat)
    }

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

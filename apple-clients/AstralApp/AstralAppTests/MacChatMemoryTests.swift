// Covers the Mac per-chat memory contract end to end on AppModel: capability advertisement and
// negotiation, exact chat_memory_* intents with single-tap idempotence, chip settlement from server
// replies, conflict and failure handling that keeps menu state, and the personalization link.

#if os(macOS)
    import AstralCore
    import Foundation
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class MacChatMemoryTests: XCTestCase {
        private let chat = "11111111-1111-4111-8111-111111111111"
        private let other = "33333333-3333-4333-8333-333333333333"
        private let connection = "22222222-2222-4222-8222-222222222222"
        private let message = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        private let change = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        private var suites: [String] = []

        override func tearDown() {
            for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
            suites.removeAll()
            super.tearDown()
        }

        private func makeModel(signedIn: Bool = true, connected: Bool = true) throws -> (
            AppModel, () -> [JSONValue]
        ) {
            let suite = "MacChatMemoryTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            suites.append(suite)
            let model = AppModel(
                conversationResumeStore: ConversationResumeStore(defaults: defaults),
                tokenStore: InMemoryTokenStore(), defaults: defaults)
            model.signedIn = signedIn
            model.connected = connected
            if connected {
                XCTAssertTrue(model.beginConversationConnection(connection))
            }
            model.activeChatId = chat
            var sent: [JSONValue] = []
            model.outboundTap = { text in
                if let frame = try? JSONValue.parse(Data(text.utf8)) { sent.append(frame) }
            }
            return (model, { sent })
        }

        private func negotiate(_ model: AppModel, version: Int = 1) {
            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"rote_config","device_profile":{"console":
                        {"chat_memory":{"version":\(version)}}}}
                    """)!)
        }

        private func applyMemoryState(_ model: AppModel, chatId: String, use: Bool, learn: Bool, pending: Int) {
            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"chat_memory_state","chat_id":"\(chatId)","use":\(use),"learn":\(learn),"pending":\(pending)}
                    """)!)
        }

        private func hydrateTurnWithChange(_ model: AppModel) throws {
            let generation = UUID().uuidString.lowercased()
            XCTAssertTrue(
                model.openConversationRequest(chatId: chat, requestGeneration: generation, purpose: .hydration))
            model.handleFrame(
                InboundFrame(
                    name: "conversation_snapshot",
                    payload: parse(
                        """
                        {"type":"conversation_snapshot","schema_version":1,
                         "snapshot_id":"55555555-5555-4555-8555-555555555555","chat_id":"\(chat)",
                         "connection_generation":"\(connection)","request_generation":"\(generation)",
                         "snapshot_purpose":"hydration","render_revision":4,
                         "committed_at":"2026-11-03T10:01:00Z",
                         "transcript":[
                           {"message_id":"\(message)","role":"assistant","created_at":"2026-11-03T10:00:00Z",
                            "parts":[{"type":"text","text":"Saved that for you"}],"attachments":[],
                            "memory_change":{"change_id":"\(change)","state":"applied","summary":"Remembered a workflow","revision":3}}
                         ],
                         "canvas":{"target":"canvas","components":[]}}
                        """)!))
        }

        private func parse(_ text: String) -> JSONValue? {
            try? JSONValue.parse(Data(text.utf8))
        }

        private func actions(_ frames: [JSONValue]) -> [String] {
            frames.compactMap { $0["action"]?.stringValue }
        }

        private func refusal(code: String) -> InboundFrame {
            InboundFrame(
                name: "memory_change_refused",
                payload: .object([
                    "type": .string("memory_change_refused"),
                    "chat_id": .string(chat),
                    "change_id": .string(change),
                    "code": .string(code),
                    "message": .string("The change moved on"),
                ]))
        }

        func testRegistrationAdvertisesChatMemoryOnMacOS() throws {
            let (model, _) = try makeModel()
            let registration = try JSONValue.parse(Data(model.registrationFrame(token: "token", resumed: false).utf8))
            let capabilities = Set(try XCTUnwrap(registration["capabilities"]?.arrayValue).compactMap(\.stringValue))
            XCTAssertEqual(registration["device"]?["chat_memory_v1"], .bool(true))
            XCTAssertTrue(capabilities.contains("chat_memory_v1"))
        }

        func testControlsRequireNegotiationSignInAndConnection() throws {
            let (model, _) = try makeModel()
            XCTAssertFalse(model.chatMemoryNegotiated)
            XCTAssertFalse(model.chatMemoryControlsAvailable)
            negotiate(model)
            XCTAssertTrue(model.chatMemoryNegotiated)
            XCTAssertTrue(model.chatMemoryControlsAvailable)

            let (signedOut, _) = try makeModel(signedIn: false)
            negotiate(signedOut)
            XCTAssertFalse(signedOut.chatMemoryControlsAvailable)

            let (offline, _) = try makeModel(connected: false)
            negotiate(offline)
            XCTAssertFalse(offline.chatMemoryControlsAvailable)
        }

        func testUnnegotiatedServerKeepsEveryMemoryControlSilent() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            model.handleFrame(
                InboundFrame.parse(#"{"type":"rote_config","device_profile":{"console":{}}}"#)!)
            XCTAssertFalse(model.chatMemoryNegotiated)
            model.setChatMemoryUse(chat, enabled: false)
            model.setChatMemoryLearn(chat, enabled: false)
            model.openPersonalization()
            XCTAssertEqual(sent.count, 0)
        }

        func testUseToggleSendsOneIntentAndIgnoresASecondTap() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            applyMemoryState(model, chatId: chat, use: true, learn: true, pending: 0)

            model.setChatMemoryUse(chat, enabled: false)
            XCTAssertEqual(actions(sent()), ["chat_memory_use"])
            XCTAssertEqual(sent().first?["payload"]?["chat_id"], .string(chat))
            XCTAssertEqual(sent().first?["payload"]?["enabled"], .bool(false))

            model.setChatMemoryUse(chat, enabled: false)
            XCTAssertEqual(sent().count, 1)

            applyMemoryState(model, chatId: chat, use: false, learn: true, pending: 0)
            XCTAssertEqual(model.chatMemorySnapshot(for: chat)?.useMemory, false)
            model.setChatMemoryUse(chat, enabled: true)
            XCTAssertEqual(sent().count, 2)
            XCTAssertEqual(sent().last?["payload"]?["enabled"], .bool(true))
        }

        func testLearnToggleSendsOneIntentPerAcceptedChange() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            applyMemoryState(model, chatId: chat, use: true, learn: true, pending: 0)

            model.setChatMemoryLearn(chat, enabled: false)
            XCTAssertEqual(actions(sent()), ["chat_memory_learn"])
            model.setChatMemoryLearn(chat, enabled: false)
            XCTAssertEqual(sent().count, 1)
            applyMemoryState(model, chatId: chat, use: true, learn: false, pending: 0)
            model.setChatMemoryLearn(other, enabled: false)
            XCTAssertEqual(sent().count, 2)
            XCTAssertEqual(sent().last?["payload"]?["chat_id"], .string(other))
        }

        func testForgetRequiresConfirmationThenSendsOneForgetIntent() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            let summary = try XCTUnwrap(
                ChatSummary(json: .object(["id": .string(chat), "title": .string("Research notes")])))

            model.requestChatMemoryForget(summary)
            XCTAssertEqual(sent.count, 0)
            XCTAssertEqual(model.chatMemoryForgetRequest?.chat.id, chat)

            model.cancelChatMemoryForget()
            XCTAssertNil(model.chatMemoryForgetRequest)
            XCTAssertEqual(sent.count, 0)

            model.requestChatMemoryForget(summary)
            model.confirmChatMemoryForget()
            XCTAssertEqual(actions(sent()), ["chat_memory_forget"])
            XCTAssertEqual(sent().first?["payload"]?["chat_id"], .string(chat))
            XCTAssertNil(model.chatMemoryForgetRequest)

            model.confirmChatMemoryForget()
            XCTAssertEqual(sent().count, 1)
        }

        func testForgetFailureShowsAnErrorAndKeepsTheMenuState() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            applyMemoryState(model, chatId: chat, use: true, learn: true, pending: 1)
            let summary = try XCTUnwrap(ChatSummary(json: .object(["id": .string(chat)])))

            model.requestChatMemoryForget(summary)
            model.confirmChatMemoryForget()
            let forgetFrame = try XCTUnwrap(sent().last)
            let submission = try XCTUnwrap(forgetFrame["submission_id"]?.stringValue)

            model.handleFrame(
                InboundFrame(
                    name: "error",
                    payload: .object([
                        "type": .string("error"),
                        "submission_id": .string(submission),
                        "accepted": .bool(false),
                        "code": .string("operation_failed"),
                        "message": .string("Memory is not available right now."),
                        "retryable": .bool(false),
                        "retry_after_ms": .null,
                    ])))
            XCTAssertTrue(model.bannerIsError)
            XCTAssertEqual(model.errorBanner, "Memory is not available right now. (operation_failed)")
            XCTAssertEqual(model.chatMemorySnapshot(for: chat)?.useMemory, true)
            XCTAssertEqual(model.chatMemorySnapshot(for: chat)?.learnFromChat, true)
            XCTAssertEqual(model.chatMemorySnapshot(for: chat)?.pending, 1)

            model.confirmChatMemoryForget()
            XCTAssertEqual(actions(sent()), ["chat_memory_forget"])
        }

        func testUndoSendsOneIntentAndTheChipSettlesFromTheServerReply() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            try hydrateTurnWithChange(model)
            let turn = try XCTUnwrap(model.turns.first)
            XCTAssertEqual(turn.memoryChange?.changeId, change)
            XCTAssertEqual(model.memoryChipDisplay(try XCTUnwrap(turn.memoryChange)), .idle)

            model.undoMemoryChange(try XCTUnwrap(turn.memoryChange))
            XCTAssertEqual(actions(sent()), ["chat_memory_undo"])
            XCTAssertEqual(sent().first?["payload"]?["change_id"], .string(change))
            XCTAssertEqual(sent().first?["payload"]?["expected_revision"], .number(3))
            XCTAssertEqual(
                model.memoryChipDisplay(try XCTUnwrap(model.turns.first?.memoryChange)), .pending)

            model.undoMemoryChange(try XCTUnwrap(model.turns.first?.memoryChange))
            XCTAssertEqual(sent().count, 1)

            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"memory_change_recorded","chat_id":"\(chat)","message_id":"\(message)",
                     "change":{"change_id":"\(change)","state":"applied","summary":"Undone","revision":4}}
                    """)!)
            let settled = try XCTUnwrap(model.turns.first?.memoryChange)
            XCTAssertEqual(settled.revision, 4)
            XCTAssertEqual(settled.summary, "Undone")
            XCTAssertEqual(model.memoryChipDisplay(settled), .idle)

            model.undoMemoryChange(settled)
            XCTAssertEqual(sent().count, 2)
            XCTAssertEqual(sent().last?["payload"]?["expected_revision"], .number(4))
        }

        func testStaleRevisionRefusalShowsTheConflictAndRefreshRehydrates() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            try hydrateTurnWithChange(model)
            let changeValue = try XCTUnwrap(model.turns.first?.memoryChange)

            model.undoMemoryChange(changeValue)
            XCTAssertEqual(sent().count, 1)
            model.handleFrame(refusal(code: "stale_revision"))
            XCTAssertEqual(model.memoryChipDisplay(changeValue), .conflict)

            let refreshesBefore = sent().count
            model.refreshChatMemory()
            XCTAssertEqual(actions(Array(sent().dropFirst(refreshesBefore))), ["load_chat"])
            XCTAssertEqual(sent().last?["payload"]?["chat_id"], .string(chat))
        }

        func testApproveAndRejectEachSendOneDecideIntent() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            try hydrateTurnWithChange(model)
            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"memory_change_recorded","chat_id":"\(chat)","message_id":"\(message)",
                     "change":{"change_id":"\(change)","state":"staged","summary":"Proposed a goal","revision":2}}
                    """)!)
            let staged = try XCTUnwrap(model.turns.first?.memoryChange)
            XCTAssertEqual(staged.state, .staged)

            model.decideMemoryChange(staged, approve: true)
            XCTAssertEqual(actions(sent()), ["chat_memory_decide"])
            XCTAssertEqual(sent().first?["payload"]?["decision"], .string("approve"))
            model.decideMemoryChange(staged, approve: true)
            model.decideMemoryChange(staged, approve: false)
            XCTAssertEqual(sent().count, 1)

            model.handleFrame(
                InboundFrame.parse(
                    """
                    {"type":"memory_change_recorded","chat_id":"\(chat)","message_id":"\(message)",
                     "change":{"change_id":"\(change)","state":"applied","summary":"Approved","revision":3}}
                    """)!)
            XCTAssertEqual(model.memoryChipDisplay(try XCTUnwrap(model.turns.first?.memoryChange)), .idle)
            model.decideMemoryChange(try XCTUnwrap(model.turns.first?.memoryChange), approve: false)
            XCTAssertEqual(sent().count, 2)
        }

        func testRefusalOtherThanStaleRevisionKeepsTheChipIdleWithTheBanner() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            try hydrateTurnWithChange(model)
            let changeValue = try XCTUnwrap(model.turns.first?.memoryChange)

            model.undoMemoryChange(changeValue)
            model.handleFrame(refusal(code: "unavailable"))
            XCTAssertEqual(model.memoryChipDisplay(changeValue), .idle)
            XCTAssertTrue(model.bannerIsError)
            XCTAssertEqual(sent().count, 1)
        }

        func testPendingCountLinksToTheServerRenderedPersonalizationSurface() throws {
            let (model, sent) = try makeModel()
            negotiate(model)
            applyMemoryState(model, chatId: chat, use: true, learn: true, pending: 2)

            model.openPersonalization()
            XCTAssertEqual(actions(sent()), ["chrome_open"])
            XCTAssertEqual(sent().first?["payload"]?["surface"], .string("personalization"))
        }

        func testRelaunchStateArrivesThroughTheServerStatePush() throws {
            let (model, _) = try makeModel()
            negotiate(model)
            XCTAssertNil(model.chatMemorySnapshot(for: chat))
            applyMemoryState(model, chatId: chat, use: false, learn: true, pending: 3)
            let snapshot = try XCTUnwrap(model.chatMemorySnapshot(for: chat))
            XCTAssertEqual(snapshot.useMemory, false)
            XCTAssertEqual(snapshot.learnFromChat, true)
            XCTAssertEqual(snapshot.pending, 3)
            applyMemoryState(model, chatId: other, use: true, learn: false, pending: 0)
            XCTAssertNotNil(model.chatMemorySnapshot(for: other))
        }
    }
#endif

// Tests that a sent chat message survives quitting the app mid-turn: AppModel keeps it in an injected
// UnsentMessageStore until it settles, restores it once into its own chat on the next launch for the same server
// and account, and clears it on settlement, sign-out, account removal and account change.

import AstralCore
@testable import AstralDeep
import XCTest

@MainActor
final class AppModelUnsentMessageTests: XCTestCase {
    private let chat = "11111111-1111-4111-8111-111111111111"
    private let otherChat = "33333333-3333-4333-8333-333333333333"
    private let connection = "22222222-2222-4222-8222-222222222222"
    private let relaunchConnection = "66666666-6666-4666-8666-666666666666"
    private let account = ConversationAccount(issuer: "https://test.invalid", subject: "owner-1")!
    private let notice =
        "Your last message may not have reached AstralDeep before it closed, so it is back in the composer."

    private var defaults: UserDefaults!
    private var store: InMemoryUnsentMessageStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let suite = "AppModelUnsentMessageTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        store = InMemoryUnsentMessageStore()
    }

    private func launch(as account: ConversationAccount? = nil) -> AppModel {
        let model = AppModel(
            conversationResumeStore: ConversationResumeStore(defaults: defaults),
            unsentMessageStore: store,
            tokenStore: InMemoryTokenStore(), defaults: defaults)
        model.bindConversationAccount(account ?? self.account)
        model.signedIn = true
        model.connected = true
        return model
    }

    private func scope(_ model: AppModel, _ account: ConversationAccount? = nil) -> UnsentMessageScope {
        UnsentMessageScope(server: model.serverBase, account: account ?? self.account)
    }

    private func captureRequests(_ model: AppModel, action: String) -> () -> String? {
        var request: String?
        model.outboundTap = { text in
            if let frame = try? JSONValue.parse(Data(text.utf8)), frame["action"]?.stringValue == action {
                request = frame["request_generation"]?.stringValue
            }
        }
        return { request }
    }

    private func sendMidTurn(_ model: AppModel, in chatId: String? = nil) -> String? {
        XCTAssertTrue(model.beginConversationConnection(connection))
        let target = chatId ?? chat
        model.activeChatId = target
        XCTAssertTrue(ConversationResumeStore(defaults: defaults).save(chatId: target, for: account))
        let request = captureRequests(model, action: "chat_message")
        model.sendChat("Draft the grant summary")
        return request()
    }

    private func snapshot(chat: String, connection: String, request: String, purpose: String) -> InboundFrame {
        InboundFrame.parse(
            """
            {"type":"conversation_snapshot","schema_version":1,
             "snapshot_id":"\(UUID().uuidString.lowercased())","chat_id":"\(chat)",
             "connection_generation":"\(connection)","request_generation":"\(request)",
             "snapshot_purpose":"\(purpose)","render_revision":1,"committed_at":"2026-11-07T20:00:00Z",
             "transcript":[{"message_id":"u1","role":"user","created_at":"2026-11-07T20:00:00Z",
               "parts":[{"type":"text","text":"Earlier question"}],"attachments":[]}],
             "canvas":{"target":"canvas","components":[]}}
            """)!
    }

    func testAMessageSentBeforeQuittingReturnsToItsChatOnRelaunch() throws {
        let first = launch()
        let request = try XCTUnwrap(sendMidTurn(first))
        let saved = try XCTUnwrap(store.load(scope(first)))
        XCTAssertEqual(
            saved, UnsentChatMessage(chatId: chat, requestGeneration: request, text: "Draft the grant summary"))

        let relaunched = launch()
        XCTAssertEqual(relaunched.activeChatId, chat)
        XCTAssertEqual(relaunched.composerDraft, "Draft the grant summary")
        XCTAssertEqual(relaunched.errorBanner, notice)
        XCTAssertFalse(relaunched.bannerIsError)
        XCTAssertNil(store.load(scope(relaunched)))
    }

    func testRebindingDuringTheTurnNeitherRestoresNorDropsTheMessage() throws {
        let model = launch()
        let request = try XCTUnwrap(sendMidTurn(model))
        model.bindConversationAccount(account)
        XCTAssertEqual(model.composerDraft, "")
        XCTAssertNotEqual(model.errorBanner, notice)
        XCTAssertEqual(store.load(scope(model))?.requestGeneration, request)
    }

    func testTheMessageIsRestoredOnlyOnceAndOnlyIntoItsOwnChat() throws {
        _ = try XCTUnwrap(sendMidTurn(launch()))
        XCTAssertTrue(ConversationResumeStore(defaults: defaults).save(chatId: otherChat, for: account))

        let relaunched = launch()
        XCTAssertEqual(relaunched.activeChatId, otherChat)
        XCTAssertEqual(relaunched.composerDraft, "")
        XCTAssertNotNil(store.load(scope(relaunched)))

        XCTAssertTrue(relaunched.beginConversationConnection(relaunchConnection))
        let otherLoad = captureRequests(relaunched, action: "load_chat")
        relaunched.openChat(otherChat)
        relaunched.handleFrame(
            snapshot(
                chat: otherChat, connection: relaunchConnection, request: try XCTUnwrap(otherLoad()),
                purpose: "hydration"))
        XCTAssertEqual(relaunched.composerDraft, "")

        let ownLoad = captureRequests(relaunched, action: "load_chat")
        relaunched.openChat(chat)
        relaunched.handleFrame(
            snapshot(
                chat: chat, connection: relaunchConnection, request: try XCTUnwrap(ownLoad()), purpose: "hydration"))
        XCTAssertEqual(relaunched.activeChatId, chat)
        XCTAssertEqual(relaunched.composerDraft, "Draft the grant summary")
        XCTAssertEqual(relaunched.errorBanner, notice)
        XCTAssertNil(store.load(scope(relaunched)))

        relaunched.composerDraft = ""
        relaunched.bindConversationAccount(account)
        XCTAssertEqual(relaunched.composerDraft, "")
    }

    func testAMessageIsNotRestoredOverADraftAndStaysSaved() throws {
        _ = try XCTUnwrap(sendMidTurn(launch()))
        XCTAssertTrue(ConversationResumeStore(defaults: defaults).save(chatId: otherChat, for: account))
        let relaunched = launch()
        relaunched.composerDraft = "Something newer"
        XCTAssertTrue(relaunched.beginConversationConnection(relaunchConnection))
        let load = captureRequests(relaunched, action: "load_chat")
        relaunched.openChat(chat)
        relaunched.handleFrame(
            snapshot(chat: chat, connection: relaunchConnection, request: try XCTUnwrap(load()), purpose: "hydration"))
        XCTAssertEqual(relaunched.activeChatId, chat)
        XCTAssertEqual(relaunched.composerDraft, "Something newer")
        XCTAssertNotEqual(relaunched.errorBanner, notice)
        XCTAssertNotNil(store.load(scope(relaunched)))
    }

    func testANewChatMessageKeepsTheChatTheServerGivesIt() throws {
        let model = launch()
        XCTAssertTrue(model.beginConversationConnection(connection))
        XCTAssertNil(model.activeChatId)
        let request = captureRequests(model, action: "chat_message")
        model.sendChat("Draft the grant summary")
        let generation = try XCTUnwrap(request())
        XCTAssertEqual(store.load(scope(model))?.chatId, nil)

        model.handleFrame(
            InboundFrame.parse(
                """
                {"type":"chat_created","schema_version":"1","connection_generation":"\(connection)",
                 "request_generation":"\(generation)",
                 "payload":{"schema_version":"1","chat_id":"\(chat)","connection_generation":"\(connection)",
                   "request_generation":"\(generation)"}}
                """)!)
        XCTAssertEqual(model.activeChatId, chat)
        XCTAssertEqual(store.load(scope(model))?.chatId, chat)
        XCTAssertEqual(store.load(scope(model))?.requestGeneration, generation)

        XCTAssertEqual(launch().composerDraft, "Draft the grant summary")
    }

    func testAnotherAccountNeverSeesTheMessageAndItsSignInClearsIt() throws {
        let first = launch()
        _ = try XCTUnwrap(sendMidTurn(first))
        let other = ConversationAccount(issuer: account.issuer, subject: "owner-2")!
        let otherModel = launch(as: other)
        XCTAssertEqual(otherModel.composerDraft, "")
        XCTAssertNil(store.load(scope(otherModel, account)))
        XCTAssertNil(store.load(scope(otherModel, other)))
        XCTAssertEqual(launch().composerDraft, "")
    }

    func testChangingAccountInTheSameLaunchClearsTheMessage() throws {
        let model = launch()
        _ = try XCTUnwrap(sendMidTurn(model))
        model.bindConversationAccount(ConversationAccount(issuer: account.issuer, subject: "owner-2")!)
        XCTAssertNil(store.load(scope(model)))
        XCTAssertEqual(launch().composerDraft, "")
    }

    func testACommittedMessageIsNotRestored() throws {
        let model = launch()
        let request = try XCTUnwrap(sendMidTurn(model))
        model.handleFrame(snapshot(chat: chat, connection: connection, request: request, purpose: "commit"))
        XCTAssertNil(store.load(scope(model)))
        XCTAssertEqual(launch().composerDraft, "")
    }

    func testAFinishedMessageIsNotRestoredEvenAfterSwitchingChats() throws {
        let model = launch()
        let request = try XCTUnwrap(sendMidTurn(model))
        model.activeChatId = otherChat
        model.handleFrame(
            InboundFrame.parse(
                """
                {"type":"operation_status","operation_id":"44444444-4444-4444-8444-444444444444",
                 "action":"chat_message","surface":"chat","chat_id":"\(chat)",
                 "connection_generation":"\(connection)","request_generation":"\(request)",
                 "sequence":1,"state":"completed","phase":"completed","label":"Done","terminal":true,
                 "retryable":false,"error":null,"retry_after_ms":null,"updated_at":"2026-11-07T20:00:01Z"}
                """)!)
        XCTAssertNil(store.load(scope(model)))
    }

    func testSignOutClearsTheMessage() async throws {
        let model = launch()
        _ = try XCTUnwrap(sendMidTurn(model))
        let saved = scope(model)
        await model.signOut(revokeRemote: false)
        XCTAssertNil(store.load(saved))
        XCTAssertEqual(launch().composerDraft, "")
    }

    func testAccountRemovalClearsTheMessage() throws {
        let model = launch()
        _ = try XCTUnwrap(sendMidTurn(model))
        model.clearConversationForAccountRemoval()
        XCTAssertNil(store.load(scope(model)))
        XCTAssertEqual(launch().composerDraft, "")
    }

    func testAnEarlierPlaintextCopyIsDeletedAtLaunch() {
        defaults.set(
            ["issuer": account.issuer, "subject": account.subject, "request": "r", "text": "Draft the grant summary"],
            forKey: "astral.unsentChatMessage.v1")
        let model = launch()
        XCTAssertNil(defaults.object(forKey: "astral.unsentChatMessage.v1"))
        XCTAssertEqual(model.composerDraft, "")
    }

    func testScopesSeparateServersAndAccountsWithoutNamingThem() throws {
        let server = try XCTUnwrap(URL(string: "https://astral.test.invalid"))
        let other = try XCTUnwrap(URL(string: "https://other.test.invalid"))
        let first = UnsentMessageScope(server: server, account: account)
        XCTAssertEqual(first, UnsentMessageScope(server: server, account: account))
        XCTAssertNotEqual(first, UnsentMessageScope(server: other, account: account))
        XCTAssertNotEqual(
            first,
            UnsentMessageScope(
                server: server, account: ConversationAccount(issuer: account.issuer, subject: "owner-2")!))
        XCTAssertNotEqual(
            first,
            UnsentMessageScope(
                server: server, account: ConversationAccount(issuer: "https://b.invalid", subject: "owner-1")!))
        XCTAssertFalse(first.storageKey.contains(account.subject))
        XCTAssertEqual(first.storageKey.count, 64)

        let memory = InMemoryUnsentMessageStore()
        let message = UnsentChatMessage(chatId: chat, requestGeneration: "r", text: "t")
        memory.save(message, for: first)
        memory.save(message, for: UnsentMessageScope(server: other, account: account))
        memory.retainOnly(first)
        XCTAssertEqual(memory.load(first), message)
        XCTAssertNil(memory.load(UnsentMessageScope(server: other, account: account)))
        memory.retainOnly(nil)
        XCTAssertNil(memory.load(first))
    }

    func testStoredMessagesDecodeOnlyWhenComplete() throws {
        let message = UnsentChatMessage(chatId: nil, requestGeneration: "r", text: "Draft")
        XCTAssertEqual(UnsentChatMessage(data: try JSONEncoder().encode(message)), message)
        for invalid in [
            #"{"requestGeneration":"r","text":"   "}"#,
            #"{"requestGeneration":"","text":"Draft"}"#,
            #"{"chatId":"","requestGeneration":"r","text":"Draft"}"#,
            #"{"text":"Draft"}"#,
            "not json",
        ] {
            XCTAssertNil(UnsentChatMessage(data: Data(invalid.utf8)), invalid)
        }
    }
}

// Tests that a sent chat message survives quitting the app mid-turn: it is kept on disk until it
// settles, restored to the composer on the next launch for the same account, and never shown to another.

import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
final class AppModelUnsentMessageTests: XCTestCase {
    private let chat = "11111111-1111-4111-8111-111111111111"
    private let connection = "22222222-2222-4222-8222-222222222222"
    private let account = ConversationAccount(issuer: "https://test.invalid", subject: "owner-1")!

    private func defaults() throws -> UserDefaults {
        let suite = "AppModelUnsentMessageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    private func launch(_ defaults: UserDefaults, as account: ConversationAccount) -> AppModel {
        let model = AppModel(
            conversationResumeStore: ConversationResumeStore(defaults: defaults),
            tokenStore: InMemoryTokenStore(), defaults: defaults)
        model.bindConversationAccount(account)
        model.signedIn = true
        model.connected = true
        return model
    }

    private func sendMidTurn(_ model: AppModel) -> String? {
        XCTAssertTrue(model.beginConversationConnection(connection))
        model.activeChatId = chat
        var request: String?
        model.outboundTap = { text in
            if let frame = try? JSONValue.parse(Data(text.utf8)), frame["action"]?.stringValue == "chat_message" {
                request = frame["request_generation"]?.stringValue
            }
        }
        model.sendChat("Draft the grant summary")
        return request
    }

    func testAMessageSentBeforeQuittingReturnsToTheComposerOnRelaunch() throws {
        let store = try defaults()
        _ = sendMidTurn(launch(store, as: account))
        let relaunched = launch(store, as: account)
        XCTAssertEqual(relaunched.composerDraft, "Draft the grant summary")
        XCTAssertFalse(relaunched.bannerIsError)
        XCTAssertNil(store.dictionary(forKey: AppModel.unsentMessageKey))
    }

    func testAnotherAccountNeverSeesTheMessage() throws {
        let store = try defaults()
        _ = sendMidTurn(launch(store, as: account))
        let other = ConversationAccount(issuer: account.issuer, subject: "owner-2")!
        XCTAssertEqual(launch(store, as: other).composerDraft, "")
    }

    func testACommittedMessageIsNotRestored() throws {
        let store = try defaults()
        let model = launch(store, as: account)
        let request = try XCTUnwrap(sendMidTurn(model))
        model.handleFrame(
            InboundFrame.parse(
                """
                {"type":"conversation_snapshot","schema_version":1,
                 "snapshot_id":"55555555-5555-4555-8555-555555555555","chat_id":"\(chat)",
                 "connection_generation":"\(connection)","request_generation":"\(request)",
                 "snapshot_purpose":"commit","render_revision":1,"committed_at":"2026-11-07T20:00:00Z",
                 "transcript":[{"message_id":"u1","role":"user","created_at":"2026-11-07T20:00:00Z",
                   "parts":[{"type":"text","text":"Draft the grant summary"}],"attachments":[]}],
                 "canvas":{"target":"canvas","components":[]}}
                """)!)
        XCTAssertNil(store.dictionary(forKey: AppModel.unsentMessageKey))
        XCTAssertEqual(launch(store, as: account).composerDraft, "")
    }
}

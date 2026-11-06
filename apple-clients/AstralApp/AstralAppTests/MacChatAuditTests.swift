// Verifies that the Mac opens a chat's audit timeline through the single server-rendered audit surface:
// the chat audit entry sends chrome_open carrying the conversation filter, switching chats updates that
// filter, and unusable chat identities never reach the wire.

import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
final class MacChatAuditTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites.removeAll()
        super.tearDown()
    }

    private func fixture() throws -> AppModel {
        let suite = "MacChatAuditTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(
            conversationResumeStore: ConversationResumeStore(defaults: defaults), tokenStore: InMemoryTokenStore(),
            defaults: defaults)
        model.signedIn = true
        model.connected = true
        return model
    }

    func testChatAuditOpensTheServerAuditSurfaceFilteredToTheConversation() throws {
        let model = try fixture()
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        model.openChatAudit("11111111-1111-4111-8111-111111111111")
        let frame = try XCTUnwrap(sent.first)
        XCTAssertEqual(frame["type"], .string("ui_event"))
        XCTAssertEqual(frame["action"], .string("chrome_open"))
        XCTAssertEqual(frame["payload"]?["surface"], .string("audit"))
        XCTAssertEqual(
            frame["payload"]?["params"]?["conversation_id"],
            .string("11111111-1111-4111-8111-111111111111"))
        XCTAssertEqual(model.pendingSurfaceKey, "audit")
    }

    func testSwitchingChatsUpdatesTheConversationFilter() throws {
        let model = try fixture()
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        model.openChatAudit("chat-a")
        model.openChatAudit("chat-b")
        XCTAssertEqual(sent.count, 2, "\(sent)")
        XCTAssertEqual(sent[0]["payload"]?["params"]?["conversation_id"], .string("chat-a"))
        XCTAssertEqual(sent[1]["payload"]?["params"]?["conversation_id"], .string("chat-b"))
        XCTAssertEqual(model.pendingSurfaceParams["conversation_id"], .string("chat-b"))
    }

    func testUnusableChatIdentitiesNeverReachTheWire() throws {
        let model = try fixture()
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        model.openChatAudit("")
        model.openChatAudit(String(repeating: "a", count: 257))
        XCTAssertTrue(sent.isEmpty, "\(sent)")
        XCTAssertEqual(model.screen, .chat)
    }
}

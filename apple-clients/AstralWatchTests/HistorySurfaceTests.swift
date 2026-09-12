import AstralCore
import XCTest

@testable import AstralWatch

@MainActor
final class HistorySurfaceTests: XCTestCase {
    private let connection = "22222222-2222-4222-8222-222222222222"
    private let chat = "11111111-1111-4111-8111-111111111111"
    private let request = "33333333-3333-4333-8333-333333333333"

    private func history(items: [JSONValue]? = nil) -> InboundFrame {
        InboundFrame(
            name: "ui_render",
            payload: .object([
                "type": .string("ui_render"), "target": .string("history"),
                "speech": .object(["text": .string("History must never be spoken"), "ssml": .string("")]),
                "components": .array([
                    .object([
                        "type": .string("chat_history"), "title": .string("Your recent chats"),
                        "items": .array(items ?? (1...4).map { item($0) }),
                    ])
                ]),
            ]))
    }

    private func item(_ index: Int) -> JSONValue {
        .object([
            "chat_id": .string("watch-chat-\(index)"), "title": .string("  **Topic**\n\(index)  "),
            "icon": .string("🔎"), "time": .string("3m"), "saved": .bool(index == 1),
        ])
    }

    private var loading: InboundFrame {
        InboundFrame.parse(
            #"{"type":"ui_render","target":"history","components":[{"type":"skeleton","variant":"chat-history","count":4}]}"#
        )!
    }

    func testHistoryPopulatesServerAdaptedRowsWithoutStartingOrReplacingWorkspaceOrSpeaking() {
        for active in [false, true] {
            let model = WatchModel()
            defer { model.speaker.stop() }
            if active {
                XCTAssertTrue(model.beginConversationConnection(connection))
                XCTAssertTrue(model.openConversationRequest(chatId: chat, requestGeneration: request, purpose: .commit))
                model.entries = [.user(id: "user", text: "Existing turn", attachments: [])]
                model.canvas = [AstralComponent(type: "text", raw: .object(["content": .string("Saved result")]))]
                model.transientCanvas = [
                    AstralComponent(type: "text", raw: .object(["content": .string("Pending result")]))
                ]
            }
            model.statusText = "Working"
            model.statusShowsActivity = true
            model.pendingDictation = "Private draft"
            model.voiceMessage = "Voice status"
            let entries = model.entries
            let canvas = model.canvas
            let transient = model.transientCanvas
            model.handleFrame(loading)
            XCTAssertTrue(model.recentsLoading)
            model.handleFrame(history())
            XCTAssertEqual(model.recents.count, 4)
            XCTAssertEqual(model.recentsTitle, "Your recent chats")
            XCTAssertFalse(model.recentsLoading)
            XCTAssertEqual(model.recents.first?.displayTitle, "**Topic** 1")
            XCTAssertEqual(model.recents.first?.icon, "🔎")
            XCTAssertEqual(model.recents.first?.relativeTime(), "3m")
            XCTAssertEqual(model.recents.first?.hasSavedComponents, true)
            XCTAssertTrue(model.recents.allSatisfy { $0.preview.isEmpty })
            XCTAssertEqual(model.workspaceStarted, active)
            XCTAssertEqual(model.activeChatId, active ? chat : nil)
            XCTAssertEqual(model.entries, entries)
            XCTAssertEqual(model.canvas, canvas)
            XCTAssertEqual(model.transientCanvas, transient)
            XCTAssertEqual(model.statusText, "Working")
            XCTAssertTrue(model.statusShowsActivity)
            XCTAssertEqual(model.pendingDictation, "Private draft")
            XCTAssertEqual(model.voiceMessage, "Voice status")
            XCTAssertFalse(model.speaker.isSpeaking)
        }
    }

    func testScopedHistoryIncludingNullAndAliasNeverChangesAnySurface() {
        let model = WatchModel()
        model.handleFrame(history())
        for key in [
            "chat_id", "chatId", "connection_generation", "request_generation",
            "base_render_revision", "frame_sequence",
        ] {
            for value: JSONValue in [.null, .string(chat), .number(0), .object([:])] {
                var payload = history(items: []).payload.objectValue!
                payload[key] = value
                model.handleFrame(InboundFrame(name: "ui_render", payload: .object(payload)))
                XCTAssertEqual(model.recents.count, 4, key)
                XCTAssertFalse(model.recentsLoading, key)
                XCTAssertFalse(model.workspaceStarted, key)
                XCTAssertTrue(model.canvas.isEmpty, key)
                XCTAssertFalse(model.speaker.isSpeaking, key)
            }
        }
    }

    func testMalformedHistoryDoesNotClearRowsAndInvalidItemsAreNotCoerced() {
        let model = WatchModel()
        model.handleFrame(history())
        for components: JSONValue in [
            .null, .string("bad"), .array([]),
            .array([.object(["type": .string("chat_history"), "items": .object([:])])]),
            .array([.object(["type": .string("text"), "content": .string("Not history")])]),
        ] {
            var payload = history().payload.objectValue!
            payload["components"] = components
            model.handleFrame(InboundFrame(name: "ui_render", payload: .object(payload)))
            XCTAssertEqual(model.recents.count, 4)
            XCTAssertFalse(model.workspaceStarted)
            XCTAssertTrue(model.canvas.isEmpty)
        }
        model.handleFrame(
            history(items: [
                .null, .string("bad"), .object(["chat_id": .number(123)]),
                .object(["chat_id": .string(" \n ")]),
                .object([
                    "chat_id": .string("strict"), "title": .number(2), "icon": .bool(true),
                    "time": .number(3), "saved": .string("true"),
                ]),
            ]))
        XCTAssertEqual(model.recents.count, 1)
        XCTAssertEqual(model.recents.first?.displayTitle, "Untitled chat")
        XCTAssertEqual(model.recents.first?.icon, "")
        XCTAssertEqual(model.recents.first?.relativeTime(), "")
        XCTAssertEqual(model.recents.first?.hasSavedComponents, false)
        model.handleFrame(history(items: []))
        XCTAssertTrue(model.recents.isEmpty)
        XCTAssertFalse(model.recentsLoading)
    }

    func testCanonicalHistoryWinsOverSuspendedRESTAndNewChatDoesNotReenableFallback() async {
        let model = WatchModel()
        await model.refreshRecents {
            XCTAssertTrue(model.recentsLoading)
            model.handleFrame(self.history())
            return [ChatSummary(json: .object(["id": .string("stale-rest")]))!]
        }
        XCTAssertEqual(model.recents.count, 4)
        XCTAssertEqual(model.recents.first?.id, "watch-chat-1")
        model.newConversation()
        var calls = 0
        await model.refreshRecents {
            calls += 1
            return []
        }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(model.recents.count, 4)
        XCTAssertFalse(model.recentsLoading)
    }

    func testRESTRemainsBoundedFallbackAndFailurePreservesVisibleRows() async {
        let model = WatchModel()
        await model.refreshRecents {
            (1...12).map { ChatSummary(json: .object(["id": .string("raw-\($0)")]))! }
        }
        XCTAssertEqual(model.recents.count, 10)
        XCTAssertEqual(model.recentsTitle, "Recent chats")
        XCTAssertFalse(model.recentsLoading)
        await model.refreshRecents { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(model.recents.count, 10)
        XCTAssertFalse(model.recentsLoading)
        model.handleFrame(history())
        XCTAssertEqual(model.recents.count, 4)
    }

    func testOwnerChangeDiscardsPriorRESTReplyWhileSameOwnerReconnectPreservesIt() async {
        for ownerChange in [false, true] {
            let model = WatchModel()
            model.bindConversationAccount(ConversationAccount(issuer: "https://iam.example.test", subject: "first")!)
            XCTAssertTrue(model.beginConversationConnection(connection))
            await model.refreshRecents {
                if ownerChange {
                    model.bindConversationAccount(
                        ConversationAccount(issuer: "https://iam.example.test", subject: "second")!)
                } else {
                    XCTAssertTrue(model.beginConversationConnection("44444444-4444-4444-8444-444444444444"))
                }
                return [ChatSummary(json: .object(["id": .string("pending-rest")]))!]
            }
            XCTAssertEqual(model.recents.isEmpty, ownerChange)
            if !ownerChange { XCTAssertEqual(model.recents.first?.id, "pending-rest") }
            XCTAssertFalse(model.recentsLoading)
            await model.refreshRecents { [ChatSummary(json: .object(["id": .string("current")]))!] }
            XCTAssertEqual(model.recents.first?.id, "current")
        }
    }

    func testConnectionRequestsCanonicalHistoryAndReconnectKeepsServerAdaptedRows() async {
        let model = WatchModel()
        var frames: [JSONValue] = []
        model.outboundTap = { frames.append(try! JSONValue.parse(Data($0.utf8))) }
        XCTAssertTrue(model.beginConversationConnection(connection))
        await model.handle(.connected)
        model.handleFrame(history())
        XCTAssertTrue(model.beginConversationConnection("44444444-4444-4444-8444-444444444444"))
        await model.handle(.connected)
        XCTAssertEqual(frames.count, 2)
        for frame in frames {
            XCTAssertEqual(frame["action"]?.stringValue, "get_history")
            XCTAssertNil(frame["session_id"]?.stringValue)
        }
        var fallbackCalls = 0
        await model.refreshRecents {
            fallbackCalls += 1
            return []
        }
        XCTAssertEqual(fallbackCalls, 0)
        XCTAssertEqual(model.recents.count, 4)
        model.handleFrame(history(items: [item(2)]))
        XCTAssertEqual(model.recents.map(\.id), ["watch-chat-2"])
        XCTAssertFalse(model.workspaceStarted)
    }

    func testAccountReplacementClearsCanonicalRowsAndAllowsCurrentOwnerFallback() async {
        let model = WatchModel()
        let first = ConversationAccount(issuer: "https://iam.example.test", subject: "first")!
        model.bindConversationAccount(first)
        model.handleFrame(history())
        model.bindConversationAccount(first)
        XCTAssertEqual(model.recents.count, 4)
        model.bindConversationAccount(ConversationAccount(issuer: "https://iam.example.test", subject: "second")!)
        XCTAssertTrue(model.recents.isEmpty)
        XCTAssertEqual(model.recentsTitle, "Recent chats")
        await model.refreshRecents { [ChatSummary(json: .object(["id": .string("second-owner")]))!] }
        XCTAssertEqual(model.recents.first?.id, "second-owner")
    }
}

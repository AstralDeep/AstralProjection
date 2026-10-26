// Tests for ConversationContinuity's reducer (Protocol/ConversationContinuity.swift): opaque per-account
// locators, the four definitive clear actions, snapshot replace semantics, and commit-generation fencing for
// mid-turn overlays.

import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
final class ConversationContinuityTests: XCTestCase {
    private let account = ConversationAccount(
        issuer: "https://id.example.test/realms/astral",
        subject: "user-42")!
    private let chat = "11111111-1111-4111-8111-111111111111"
    private let connection = "22222222-2222-4222-8222-222222222222"
    private let hydration = "33333333-3333-4333-8333-333333333333"
    private let commit = "44444444-4444-4444-8444-444444444444"

    private var defaults: UserDefaults!
    private var store: ConversationResumeStore!

    override func setUp() {
        super.setUp()
        let suite = "ConversationContinuityTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = ConversationResumeStore(
            defaults: defaults,
            now: { Date(timeIntervalSince1970: 1_752_605_260) })
    }

    private func inbound(_ text: String) -> InboundFrame {
        InboundFrame.parse(text)!
    }

    private func snapshot(
        id: String = "55555555-5555-4555-8555-555555555555",
        request: String? = nil,
        purpose: String = "hydration",
        revision: Int = 0,
        canvasText: String = "Restored canvas"
    ) -> InboundFrame {
        inbound(
            """
            {"type":"conversation_snapshot","schema_version":1,
             "snapshot_id":"\(id)","chat_id":"\(chat)",
             "connection_generation":"\(connection)",
             "request_generation":"\(request ?? hydration)",
             "snapshot_purpose":"\(purpose)","render_revision":\(revision),
             "committed_at":"2026-07-15T18:41:00Z",
             "transcript":[
               {"message_id":"u1","role":"user","created_at":"2026-07-15T18:40:00Z",
                "parts":[{"type":"text","text":"Question"}],
                "attachments":[{"filename":"report.pdf"}]},
               {"message_id":"a1","role":"assistant","created_at":"2026-07-15T18:40:59Z",
                "parts":[
                  {"type":"structured","value":{"total":21},"plain_text":"total: 21"},
                  {"type":"components","components":[{"type":"text","content":"Component answer"}]}
                ],"attachments":[]}
             ],
             "canvas":{"target":"canvas","components":[{"type":"text","content":"\(canvasText)"}]}}
            """)
    }

    func testAccountScopedLocatorIsOpaqueAndUnknownSchemaIsRetained() throws {
        let other = ConversationAccount(
            issuer: account.issuer,
            subject: "user-43")!
        XCTAssertTrue(store.save(chatId: chat, for: account))
        XCTAssertEqual(store.load(for: account)?.chatId, chat)
        XCTAssertNil(store.load(for: other))
        XCTAssertFalse(account.locatorStorageKey.contains(account.subject))
        XCTAssertFalse(account.locatorStorageKey.contains(account.issuer))
        XCTAssertEqual(
            account.locatorStorageKey,
            "astraldeep.active_chat.v1.a4fd816804e37476d0c967381aeb6b462a4e5edec4b013293ed1b7d10da58c8e")

        let unknown =
            #"{"schema_version":2,"chat_id":"11111111-1111-4111-8111-111111111111","updated_at":"2026-07-15T18:41:00Z"}"#
        defaults.set(unknown, forKey: other.locatorStorageKey)
        XCTAssertNil(store.load(for: other))
        XCTAssertEqual(defaults.string(forKey: other.locatorStorageKey), unknown)
    }

    func testOnlyFourDefinitiveClearActionsRemoveLocator() {
        for reason in [
            ConversationResumeClearReason.newChat,
            .signOut,
            .accountRemoval,
        ] {
            XCTAssertTrue(store.save(chatId: chat, for: account))
            XCTAssertTrue(store.clear(reason, for: account))
            XCTAssertNil(store.load(for: account))
        }

        XCTAssertTrue(store.save(chatId: chat, for: account))
        XCTAssertFalse(
            store.clear(
                .confirmedDeletion,
                for: account,
                chatId: "99999999-9999-4999-8999-999999999999"))
        XCTAssertEqual(store.load(for: account)?.chatId, chat)
        XCTAssertTrue(store.clear(.confirmedDeletion, for: account, chatId: chat))
        XCTAssertNil(store.load(for: account))
    }

    func testRelaunchRegistersLocatorBeforeWelcomeWithFreshUUID4Generations() throws {
        XCTAssertTrue(store.save(chatId: chat, for: account))
        let relaunched = AppModel(conversationResumeStore: store, tokenStore: InMemoryTokenStore())
        relaunched.bindConversationAccount(account)

        let registration = try JSONValue.parse(
            Data(
                relaunched.registrationFrame(
                    token: "token", resumed: true
                ).utf8))
        let connectionGeneration = try XCTUnwrap(
            registration["connection_generation"]?.stringValue)
        let requestGeneration = try XCTUnwrap(
            registration["resume"]?["request_generation"]?.stringValue)
        XCTAssertEqual(registration["resume"]?["active_chat_id"]?.stringValue, chat)
        XCTAssertNotNil(
            connectionGeneration.range(
                of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                options: .regularExpression))
        XCTAssertNotNil(
            requestGeneration.range(
                of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                options: .regularExpression))
        XCTAssertEqual(relaunched.activeChatId, chat)
        XCTAssertFalse(relaunched.consoleDashboardVisible)
        XCTAssertTrue(relaunched.turns.isEmpty)
        XCTAssertTrue(relaunched.canvas.isEmpty)
    }

    func testSnapshotReplacesTranscriptAndCanvasTogetherWithSemanticParts() {
        let model = AppModel(conversationResumeStore: store, tokenStore: InMemoryTokenStore())
        model.bindConversationAccount(account)
        XCTAssertTrue(model.beginConversationConnection(connection))
        XCTAssertTrue(
            model.openConversationRequest(
                chatId: chat,
                requestGeneration: hydration,
                purpose: .hydration))
        model.turns = [.init(id: "old", role: "assistant", text: "Old")]
        model.canvas = [
            AstralComponent(
                json: .object([
                    "type": .string("text"), "content": .string("Old canvas"),
                ]))!
        ]

        model.handleFrame(snapshot())

        XCTAssertEqual(model.turns.map(\.id), ["u1", "a1"])
        XCTAssertEqual(model.turns[0].text, "Question\n📎 report.pdf")
        XCTAssertEqual(model.turns[1].text, "total: 21")
        XCTAssertEqual(model.turns[1].components.map(\.fallbackText), ["Component answer"])
        XCTAssertEqual(model.canvas.map(\.fallbackText), ["Restored canvas"])
        XCTAssertEqual(model.lastCommittedRenderRevision, 0)
        XCTAssertFalse(model.consoleDashboardVisible)
    }

    func testHydrationReplayConflictEqualCommitAndOldGenerationAreNoOps() {
        let model = AppModel(conversationResumeStore: store, tokenStore: InMemoryTokenStore())
        XCTAssertTrue(model.beginConversationConnection(connection))
        XCTAssertTrue(
            model.openConversationRequest(
                chatId: chat,
                requestGeneration: hydration,
                purpose: .hydration))
        let accepted = snapshot()
        model.handleFrame(accepted)
        model.handleFrame(accepted)
        XCTAssertEqual(model.canvas.map(\.fallbackText), ["Restored canvas"])

        model.handleFrame(
            snapshot(
                id: "66666666-6666-4666-8666-666666666666",
                canvasText: "Conflict"))
        XCTAssertEqual(model.canvas.map(\.fallbackText), ["Restored canvas"])

        XCTAssertTrue(
            model.openConversationRequest(
                chatId: chat,
                requestGeneration: commit,
                purpose: .commit))
        model.handleFrame(snapshot(request: commit, purpose: "commit"))
        XCTAssertEqual(model.canvas.map(\.fallbackText), ["Restored canvas"])

        model.handleFrame(
            inbound(
                """
                {"type":"conversation_snapshot","schema_version":1,
                 "snapshot_id":"77777777-7777-4777-8777-777777777777","chat_id":"\(chat)",
                 "connection_generation":"99999999-9999-4999-8999-999999999999",
                 "request_generation":"\(commit)","snapshot_purpose":"commit",
                 "render_revision":1,"committed_at":"2026-07-15T18:41:00Z",
                 "transcript":[],"canvas":{"target":"canvas","components":[]}}
                """))
        XCTAssertEqual(model.canvas.map(\.fallbackText), ["Restored canvas"])
    }

    func testTransientOverlayIsSequencedAndCannotMutateCommittedCanvas() {
        let model = AppModel(conversationResumeStore: store, tokenStore: InMemoryTokenStore())
        XCTAssertTrue(model.beginConversationConnection(connection))
        XCTAssertTrue(
            model.openConversationRequest(
                chatId: chat,
                requestGeneration: commit,
                purpose: .commit))
        model.canvas = [
            AstralComponent(
                json: .object([
                    "type": .string("text"), "content": .string("Committed"),
                ]))!
        ]

        model.handleFrame(
            inbound(
                """
                {"type":"ui_render","target":"canvas","chat_id":"\(chat)",
                 "connection_generation":"\(connection)","request_generation":"\(commit)",
                 "base_render_revision":0,"frame_sequence":1,
                 "components":[{"type":"text","content":"Preview"}]}
                """))
        XCTAssertEqual(model.canvas.map(\.fallbackText), ["Committed"])
        XCTAssertEqual(model.visibleCanvas.map(\.fallbackText), ["Preview"])

        model.handleFrame(
            inbound(
                #"{"type":"stream_error","message":"preview failed"}"#))
        XCTAssertEqual(model.canvas.map(\.fallbackText), ["Committed"])
        XCTAssertEqual(model.visibleCanvas.map(\.fallbackText), ["Committed"])

        model.handleFrame(
            inbound(
                """
                {"type":"ui_render","target":"canvas","chat_id":"\(chat)",
                 "connection_generation":"\(connection)","request_generation":"\(commit)",
                 "base_render_revision":0,"frame_sequence":2,
                 "components":[{"type":"text","content":"Preview next"}]}
                """))
        XCTAssertEqual(model.visibleCanvas.map(\.fallbackText), ["Preview next"])

        model.handleFrame(
            inbound(
                """
                {"type":"ui_render","target":"canvas","chat_id":"\(chat)",
                 "connection_generation":"\(connection)","request_generation":"\(commit)",
                 "base_render_revision":0,"frame_sequence":1,
                 "components":[{"type":"text","content":"Duplicate"}]}
                """))
        XCTAssertEqual(model.visibleCanvas.map(\.fallbackText), ["Preview next"])

        model.handleFrame(
            snapshot(
                id: "77777777-7777-4777-8777-777777777777",
                request: commit,
                purpose: "commit",
                revision: 1,
                canvasText: "Committed next"))
        XCTAssertEqual(model.canvas.map(\.fallbackText), ["Committed next"])
        XCTAssertEqual(model.visibleCanvas.map(\.fallbackText), ["Committed next"])
    }

    func testCommitReadyPreludeFencesDetachedCommitAndRejectsWrongScope() {
        let model = AppModel(conversationResumeStore: store, tokenStore: InMemoryTokenStore())
        XCTAssertTrue(model.beginConversationConnection(connection))
        XCTAssertTrue(
            model.openConversationRequest(
                chatId: chat,
                requestGeneration: hydration,
                purpose: .hydration))
        model.handleFrame(snapshot(revision: 4))

        model.handleFrame(
            inbound(
                """
                {"type":"conversation_commit_ready","schema_version":1,
                 "chat_id":"\(chat)","connection_generation":"\(connection)",
                 "request_generation":"\(commit)","render_revision":5}
                """))
        model.handleFrame(
            snapshot(
                id: "77777777-7777-4777-8777-777777777777",
                request: commit,
                purpose: "commit",
                revision: 5,
                canvasText: "Detached result"))
        XCTAssertEqual(model.canvas.map(\.fallbackText), ["Detached result"])

        model.handleFrame(
            inbound(
                """
                {"type":"conversation_commit_ready","schema_version":1,
                 "chat_id":"\(chat)",
                 "connection_generation":"99999999-9999-4999-8999-999999999999",
                 "request_generation":"88888888-8888-4888-8888-888888888888",
                 "render_revision":6}
                """))
        model.handleFrame(
            snapshot(
                id: "99999999-9999-4999-8999-999999999999",
                request: "88888888-8888-4888-8888-888888888888",
                purpose: "commit",
                revision: 6,
                canvasText: "Wrong scope"))
        XCTAssertEqual(model.canvas.map(\.fallbackText), ["Detached result"])
    }

    func testNewTurnUsesCommitGenerationAndOnlyMutatesPendingOverlay() throws {
        let model = AppModel(conversationResumeStore: store, tokenStore: InMemoryTokenStore())
        XCTAssertTrue(model.beginConversationConnection(connection))
        XCTAssertTrue(
            model.openConversationRequest(
                chatId: chat,
                requestGeneration: hydration,
                purpose: .hydration))
        model.turns = [.init(id: "committed", role: "assistant", text: "Committed")]
        model.canvas = [
            AstralComponent(
                json: .object([
                    "type": .string("text"), "content": .string("Committed canvas"),
                ]))!
        ]
        var sent: JSONValue?
        model.outboundTap = { text in
            sent = try? JSONValue.parse(Data(text.utf8))
        }

        model.sendChat("Pending question")

        XCTAssertEqual(model.turns.map(\.text), ["Committed"])
        XCTAssertEqual(model.visibleTurns.map(\.text), ["Committed", "Pending question"])
        XCTAssertEqual(model.canvas.map(\.fallbackText), ["Committed canvas"])
        XCTAssertEqual(sent?["payload"]?["snapshot_purpose"]?.stringValue, "commit")
        let request = try XCTUnwrap(sent?["payload"]?["request_generation"]?.stringValue)
        XCTAssertNotNil(
            request.range(
                of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                options: .regularExpression))
    }

    func testLoadPersistsBeforeSendAndDisconnectDoesNotClearLocator() {
        let model = AppModel(conversationResumeStore: store, tokenStore: InMemoryTokenStore())
        model.bindConversationAccount(account)
        var wasPersistedAtSend = false
        model.outboundTap = { [store, account, chat] _ in
            wasPersistedAtSend = store?.load(for: account)?.chatId == chat
        }

        model.openChat(chat)
        XCTAssertTrue(wasPersistedAtSend)
        model.handleFrame(inbound(#"{"type":"error","code":"snapshot_retryable","message":"retry"}"#))
        XCTAssertEqual(store.load(for: account)?.chatId, chat)
    }

    func testAcceptedHistoryPrimitiveUsesNormalHydration() throws {
        let model = AppModel(conversationResumeStore: store, tokenStore: InMemoryTokenStore())
        model.bindConversationAccount(account)
        model.signedIn = true
        model.connected = true
        XCTAssertTrue(model.beginConversationConnection(connection))
        XCTAssertTrue(model.openConversationRequest(chatId: chat, requestGeneration: hydration, purpose: .hydration))
        let target = "66666666-6666-4666-8666-666666666666"
        let history: JSONValue = .object([
            "type": .string("chat_history"),
            "items": .array([.object(["chat_id": .string(target), "title": .string("Owned history")])]),
        ])
        var frame = snapshot().payload.objectValue!
        frame["canvas"] = .object(["target": .string("canvas"), "components": .array([history])])
        model.handleFrame(InboundFrame(name: "conversation_snapshot", payload: .object(frame)))
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        model.navigationCallback(try XCTUnwrap(model.canvas.first), surface: false)(["chat_id": .string(target)])
        XCTAssertEqual(model.activeChatId, target)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["action"]?.stringValue, "load_chat")
        XCTAssertEqual(sent.first?["session_id"]?.stringValue, target)
    }

    func testCapturedHistoryRowsBindActualSourceAndRetireWithItsLifetime() throws {
        for origin in ["canvas", "transcript", "surface"] {
            for change in [
                "current", "replacement", "request", "owner", "connection", "disconnected", "signed-out",
                "pending", "mandatory", "timeline", "wrong-target", "malformed", "extra",
            ] {
                let model = AppModel(conversationResumeStore: store, tokenStore: InMemoryTokenStore())
                model.bindConversationAccount(account)
                model.signedIn = true
                model.connected = true
                XCTAssertTrue(model.beginConversationConnection(connection))
                XCTAssertTrue(
                    model.openConversationRequest(chatId: chat, requestGeneration: hydration, purpose: .hydration))
                let target = "66666666-6666-4666-8666-666666666666"
                let history: JSONValue = .object([
                    "type": .string("chat_history"),
                    "items": .array([.object(["id": .string(target), "title": .string("Owned history")])]),
                ])
                var sent: [JSONValue] = []
                model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
                var frame = snapshot().payload.objectValue!
                if origin == "transcript" {
                    frame["transcript"] = .array([
                        .object([
                            "message_id": .string("history"), "role": .string("assistant"),
                            "created_at": .string("2026-07-15T18:40:59Z"), "attachments": .array([]),
                            "parts": .array([.object(["type": .string("components"), "components": .array([history])])]
                            ),
                        ])
                    ])
                } else {
                    frame["canvas"] = .object(["target": .string("canvas"), "components": .array([history])])
                }
                model.handleFrame(InboundFrame(name: "conversation_snapshot", payload: .object(frame)))
                if origin == "surface" {
                    model.openSurface("search")
                    let request = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
                    model.handleFrame(
                        InboundFrame(
                            name: "chrome_surface",
                            payload: .object([
                                "type": .string("chrome_surface"), "surface_key": .string("search"),
                                "title": .string("Sources"), "mode": .string("replace"),
                                "request_generation": .string(request),
                                "components": .array([history]),
                            ])))
                }
                let component = try XCTUnwrap(
                    origin == "surface"
                        ? model.pendingSurface?.components.first
                        : origin == "transcript" ? model.turns.first?.components.first : model.canvas.first)
                let callback = model.navigationCallback(
                    component, surface: origin == "surface", transcript: origin == "transcript" ? "history" : nil)
                switch change {
                case "replacement":
                    if origin == "surface" {
                        model.openSurface("search")
                        let replacement = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
                        model.handleFrame(
                            InboundFrame(
                                name: "chrome_surface",
                                payload: .object([
                                    "type": .string("chrome_surface"), "surface_key": .string("search"),
                                    "title": .string("Sources"), "mode": .string("replace"),
                                    "request_generation": .string(replacement), "components": .array([history]),
                                ])))
                    } else {
                        let replacement = UUID().uuidString.lowercased()
                        XCTAssertTrue(
                            model.openConversationRequest(
                                chatId: chat, requestGeneration: replacement, purpose: .hydration))
                        frame["snapshot_id"] = .string(UUID().uuidString.lowercased())
                        frame["request_generation"] = .string(replacement)
                        model.handleFrame(InboundFrame(name: "conversation_snapshot", payload: .object(frame)))
                    }
                case "request":
                    _ = model.openConversationRequest(chatId: chat, requestGeneration: commit, purpose: .commit)
                case "owner":
                    model.bindConversationAccount(
                        ConversationAccount(issuer: account.issuer, subject: "replacement-owner")!)
                case "connection": _ = model.beginConversationConnection("77777777-7777-4777-8777-777777777777")
                case "disconnected": model.connected = false
                case "signed-out": model.signedIn = false
                case "pending": model.openSurface("search")
                case "mandatory": model.mandatorySurface = true
                case "timeline": model.timelineReadOnly = true
                default: break
                }
                let before = model.activeChatId
                sent.removeAll()
                var payload: [String: JSONValue] =
                    change == "malformed" ? [:] : ["chat_id": .string(change == "wrong-target" ? chat : target)]
                if change == "extra" { payload["other"] = .bool(true) }
                callback(payload)
                if change == "current" {
                    XCTAssertEqual(model.activeChatId, target, origin)
                    XCTAssertEqual(sent.count, 1, origin)
                    XCTAssertEqual(sent.first?["action"]?.stringValue, "load_chat", origin)
                } else {
                    XCTAssertEqual(model.activeChatId, before, "\(origin)/\(change)")
                    XCTAssertTrue(sent.isEmpty, "\(origin)/\(change)")
                    if change == "replacement" {
                        let fresh = try XCTUnwrap(
                            origin == "surface"
                                ? model.pendingSurface?.components.first
                                : origin == "transcript" ? model.turns.first?.components.first : model.canvas.first)
                        model.navigationCallback(
                            fresh, surface: origin == "surface", transcript: origin == "transcript" ? "history" : nil)([
                                "chat_id": .string(target)
                            ])
                        XCTAssertEqual(model.activeChatId, target, origin)
                        XCTAssertEqual(sent.count, 1, origin)
                    }
                }
            }
        }
    }

    func testReconnectedTranscriptPreviewCannotRebindTheRetainedCanvasHistory() throws {
        let model = AppModel(conversationResumeStore: store, tokenStore: InMemoryTokenStore())
        model.bindConversationAccount(account)
        model.signedIn = true
        model.connected = true
        XCTAssertTrue(model.beginConversationConnection(connection))
        XCTAssertTrue(model.openConversationRequest(chatId: chat, requestGeneration: hydration, purpose: .hydration))
        let target = "66666666-6666-4666-8666-666666666666"
        let history: JSONValue = .object([
            "type": .string("chat_history"),
            "items": .array([.object(["chat_id": .string(target), "title": .string("Retained history")])]),
        ])
        var frame = snapshot().payload.objectValue!
        frame["canvas"] = .object(["target": .string("canvas"), "components": .array([history])])
        model.handleFrame(InboundFrame(name: "conversation_snapshot", payload: .object(frame)))
        let component = try XCTUnwrap(model.canvas.first)
        let old = model.navigationCallback(component, surface: false)
        let replacement = "77777777-7777-4777-8777-777777777777"
        XCTAssertTrue(model.beginConversationConnection(replacement))
        XCTAssertTrue(model.openConversationRequest(chatId: chat, requestGeneration: commit, purpose: .commit))
        model.handleFrame(
            inbound(
                """
                {"type":"ui_render","target":"chat","chat_id":"\(chat)",
                "connection_generation":"\(replacement)","request_generation":"\(commit)",
                "base_render_revision":0,"frame_sequence":1,"components":[{"type":"text","content":"Current preview"}]}
                """))
        XCTAssertFalse(model.transientTurns.isEmpty)
        var sent: [String] = []
        model.outboundTap = { sent.append($0) }
        old(["chat_id": .string(target)])
        model.navigationCallback(component, surface: false)(["chat_id": .string(target)])
        XCTAssertEqual(model.activeChatId, chat)
        XCTAssertTrue(sent.isEmpty)
        model.handleFrame(
            inbound(
                """
                {"type":"ui_render","target":"canvas","chat_id":"\(chat)",
                "connection_generation":"\(replacement)","request_generation":"\(commit)",
                "base_render_revision":0,"frame_sequence":2,"components":[\(String(decoding: try history.encoded(), as: UTF8.self))]}
                """))
        model.navigationCallback(try XCTUnwrap(model.visibleCanvas.first), surface: false)(["chat_id": .string(target)])
        XCTAssertEqual(model.activeChatId, target)
        XCTAssertEqual(sent.count, 1)
    }

    func testSharedChromeConversationOpensTheSelectedChatAndHydratesBeforeNextSend() throws {
        let model = AppModel(conversationResumeStore: store, tokenStore: InMemoryTokenStore())
        model.bindConversationAccount(account)
        model.signedIn = true
        model.connected = true
        XCTAssertTrue(model.beginConversationConnection(connection))
        XCTAssertTrue(model.openConversationRequest(chatId: chat, requestGeneration: hydration, purpose: .hydration))
        model.handleFrame(snapshot())
        var sent: [JSONValue] = []
        model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
        model.openSurface("search")
        let surfaceRequest = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
        let target = "66666666-6666-4666-8666-666666666666"
        let payload: JSONValue = .object(["chat_id": .string(target)])
        model.handleFrame(
            InboundFrame(
                name: "chrome_surface",
                payload: .object([
                    "type": .string("chrome_surface"), "surface_key": .string("search"),
                    "title": .string("Search"), "mode": .string("replace"),
                    "request_generation": .string(surfaceRequest),
                    "components": .array([
                        .object([
                            "type": .string("button"), "label": .string("Open conversation"),
                            "action": .string("load_chat"), "payload": payload,
                        ])
                    ]),
                ])))
        XCTAssertNotNil(model.pendingSurface)
        sent.removeAll()
        model.sendEvent("load_chat", payload)
        let load = try XCTUnwrap(sent.first)
        XCTAssertEqual(load["session_id"]?.stringValue, target)
        XCTAssertEqual(load["payload"]?["chat_id"]?.stringValue, target)
        XCTAssertEqual(model.activeChatId, target)
        XCTAssertEqual(model.screen, .chat)
        XCTAssertEqual(sent.count, 1)
        var restored = snapshot(canvasText: "Target canvas").payload.objectValue!
        restored["chat_id"] = .string(target)
        restored["request_generation"] = load["request_generation"]
        model.handleFrame(InboundFrame(name: "conversation_snapshot", payload: .object(restored)))
        XCTAssertEqual(model.canvas.map(\.fallbackText), ["Target canvas"])
        XCTAssertEqual(model.turns.map(\.id), ["u1", "a1"])
        XCTAssertFalse(sent.contains { $0["action"]?.stringValue == "chat_message" })
        model.sendChat("Explicit next message")
        XCTAssertEqual(sent.last?["action"]?.stringValue, "chat_message")
        XCTAssertEqual(sent.last?["session_id"]?.stringValue, target)
    }

    func testSharedChromeConversationRefusesRetiredDisabledAndChangedOffers() throws {
        for change in [
            "closed", "pending", "disabled", "wrong-target", "disconnected", "owner", "connection", "mandatory",
            "malformed", "failure",
        ] {
            let model = AppModel(conversationResumeStore: store, tokenStore: InMemoryTokenStore())
            model.bindConversationAccount(account)
            model.signedIn = true
            model.connected = true
            XCTAssertTrue(model.beginConversationConnection(connection))
            XCTAssertTrue(
                model.openConversationRequest(chatId: chat, requestGeneration: hydration, purpose: .hydration))
            var sent: [JSONValue] = []
            model.outboundTap = { sent.append(try! JSONValue.parse(Data($0.utf8))) }
            model.openSurface("search")
            let request = try XCTUnwrap(sent.last?["request_generation"]?.stringValue)
            let target = change == "malformed" ? "invalid" : "66666666-6666-4666-8666-666666666666"
            let payload: JSONValue = .object(["chat_id": .string(target)])
            model.handleFrame(
                InboundFrame(
                    name: "chrome_surface",
                    payload: .object([
                        "type": .string("chrome_surface"), "surface_key": .string("search"),
                        "title": .string("Search"), "mode": .string("replace"), "request_generation": .string(request),
                        "components": .array([
                            .object([
                                "type": .string("card"), "title": .string("Source"),
                                "content": .array([
                                    .object([
                                        "type": .string("button"), "label": .string("Open conversation"),
                                        "action": .string("load_chat"), "payload": payload,
                                        "disabled": .bool(change == "disabled"),
                                    ])
                                ]),
                            ])
                        ]),
                    ])))
            switch change {
            case "closed": model.closeSurface()
            case "pending": model.openSurface("search")
            case "disconnected": model.connected = false
            case "owner":
                model.bindConversationAccount(
                    ConversationAccount(issuer: account.issuer, subject: "replacement-owner")!)
            case "connection": _ = model.beginConversationConnection("77777777-7777-4777-8777-777777777777")
            case "failure": model.surfaceFailureMessage = "Reload this surface"
            case "mandatory": model.mandatorySurface = true
            default: break
            }
            let before = model.activeChatId
            sent.removeAll()
            model.sendEvent("load_chat", change == "wrong-target" ? .object(["chat_id": .string(chat)]) : payload)
            XCTAssertEqual(model.activeChatId, before, change)
            XCTAssertTrue(sent.isEmpty, change)
        }
    }

}

// Covers the chat_memory_v1 pure decoders and builders: acknowledgement and server-frame parsing,
// the optional transcript chip field, exact outbound intent fields, and fail-closed shape rejection.

import Foundation
import XCTest

@testable import AstralCore

final class ChatMemoryFrameTests: XCTestCase {
    private let chat = "11111111-1111-4111-8111-111111111111"
    private let message = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let change = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    private func parse(_ text: String) -> InboundFrame? {
        InboundFrame.parse(text)
    }

    private func value(_ text: String) -> JSONValue? {
        InboundFrame.parse(text)?.payload
    }

    func testAcknowledgementRequiresExactVersionOneShape() {
        let accepted = ChatMemoryAcknowledgement(
            json: value(#"{"type":"rote_config","device_profile":{"console":{"chat_memory":{"version":1}}}}"#))
        XCTAssertNotNil(accepted)
        XCTAssertNil(
            ChatMemoryAcknowledgement(
                json: value(#"{"type":"rote_config","device_profile":{"console":{"chat_memory":{"version":2}}}}"#)))
        XCTAssertNil(
            ChatMemoryAcknowledgement(
                json: value(
                    #"{"type":"rote_config","device_profile":{"console":{"chat_memory":{"version":1,"extra":true}}}}"#)))
        XCTAssertNil(
            ChatMemoryAcknowledgement(json: value(#"{"type":"rote_config","device_profile":{"console":{}}}"#)))
    }

    func testChatMemoryStateParsesExactServerFields() {
        let state = ChatMemoryState(
            frame: parse(
                #"{"type":"chat_memory_state","chat_id":"\#(chat)","use":true,"learn":false,"pending":2}"#)!)
        XCTAssertEqual(state?.chatId, chat)
        XCTAssertEqual(state?.useMemory, true)
        XCTAssertEqual(state?.learnFromChat, false)
        XCTAssertEqual(state?.pending, 2)
    }

    func testChatMemoryStateRejectsMalformedShapes() {
        XCTAssertNil(
            ChatMemoryState(
                frame: parse(
                    #"{"type":"chat_memory_state","chat_id":"\#(chat)","use":true,"learn":false,"pending":2,"extra":1}"#
                )!))
        XCTAssertNil(
            ChatMemoryState(
                frame: parse(
                    #"{"type":"chat_memory_state","chat_id":"not-a-uuid","use":true,"learn":false,"pending":2}"#)!))
        XCTAssertNil(
            ChatMemoryState(
                frame: parse(
                    #"{"type":"chat_memory_state","chat_id":"\#(chat)","use":true,"learn":false,"pending":-1}"#)!))
        XCTAssertNil(
            ChatMemoryState(
                frame: parse(
                    #"{"type":"chat_memory_state","chat_id":"\#(chat)","use":true,"learn":false,"pending":100}"#)!))
        XCTAssertNil(
            ChatMemoryState(
                frame: parse(
                    #"{"type":"chat_memory_state","chat_id":"\#(chat)","use":"yes","learn":false,"pending":0}"#)!))
        XCTAssertNil(
            ChatMemoryState(
                frame: parse(
                    #"{"type":"chat_memory_snapshot","chat_id":"\#(chat)","use":true,"learn":false,"pending":0}"#)!))
    }

    func testMemoryChangeParsesAppliedAndStagedSummaries() {
        let applied = MemoryChange(
            json: value(
                #"{"change_id":"\#(change)","state":"applied","summary":"Remembered a preference","revision":3}"#))
        XCTAssertEqual(applied?.state, .applied)
        XCTAssertEqual(applied?.revision, 3)
        let staged = MemoryChange(
            json: value(#"{"change_id":"\#(change)","state":"staged","summary":"Proposed a goal","revision":1}"#))
        XCTAssertEqual(staged?.state, .staged)
    }

    func testMemoryChangeRejectsMalformedShapes() {
        XCTAssertNil(
            MemoryChange(
                json: value(
                    #"{"change_id":"\#(change)","state":"applied","summary":"Remembered a preference","revision":3,"extra":true}"#)))
        XCTAssertNil(
            MemoryChange(
                json: value(
                    #"{"change_id":"\#(change)","state":"forgotten","summary":"Remembered a preference","revision":3}"#)))
        XCTAssertNil(
            MemoryChange(json: value(#"{"change_id":"\#(change)","state":"applied","summary":"","revision":3}"#)))
        XCTAssertNil(
            MemoryChange(
                json: value(#"{"change_id":"\#(change)","state":"applied","summary":"Remembered","revision":0}"#)))
        XCTAssertNil(
            MemoryChange(
                json: value(
                    #"{"change_id":"\#(change)","state":"applied","summary":"\#(String(repeating: "x", count: 513))","revision":1}"#)))
        XCTAssertNil(
            MemoryChange(
                json: value(#"{"change_id":"not-a-uuid","state":"applied","summary":"Remembered","revision":1}"#)))
    }

    func testRecordedPushParsesTheAuthoritativeChipState() {
        let recorded = MemoryChangeRecorded(
            frame: parse(
                """
                {"type":"memory_change_recorded","chat_id":"\(chat)","message_id":"\(message)",
                 "change":{"change_id":"\(change)","state":"applied","summary":"Undone","revision":4}}
                """)!)
        XCTAssertEqual(recorded?.chatId, chat)
        XCTAssertEqual(recorded?.messageId, message)
        XCTAssertEqual(recorded?.change.changeId, change)
        XCTAssertEqual(recorded?.change.state, .applied)
        XCTAssertNil(
            MemoryChangeRecorded(
                frame: parse(
                    """
                    {"type":"memory_change_recorded","chat_id":"\(chat)","message_id":"\(message)",
                     "change":{"change_id":"\(change)","state":"applied","summary":"Undone","revision":4},"x":1}
                    """)!))
        XCTAssertNil(
            MemoryChangeRecorded(
                frame: parse(
                    """
                    {"type":"memory_change_recorded","chat_id":"\(chat)","message_id":"\(message)",
                     "change":{"change_id":"\(change)","state":"applied","summary":"Undone","revision":0}}
                    """)!))
    }

    func testRefusedPushParsesClosedCodesAndOptionalChange() {
        let conflict = MemoryChangeRefused(
            frame: parse(
                #"{"type":"memory_change_refused","chat_id":"\#(chat)","change_id":"\#(change)","code":"stale_revision","message":"The change moved on"}"#
            )!)
        XCTAssertEqual(conflict?.code, .staleRevision)
        XCTAssertEqual(conflict?.changeId, change)
        let plain = MemoryChangeRefused(
            frame: parse(
                #"{"type":"memory_change_refused","chat_id":"\#(chat)","code":"unavailable","message":"Memory is unavailable"}"#
            )!)
        XCTAssertEqual(plain?.code, .unavailable)
        XCTAssertNil(plain?.changeId)
        for code in ["not_found", "phi_protected"] {
            XCTAssertNotNil(
                MemoryChangeRefused(
                    frame: parse(
                        #"{"type":"memory_change_refused","chat_id":"\#(chat)","code":"\#(code)","message":"refused"}"#
                    )!))
        }
    }

    func testRefusedPushRejectsUnknownCodesAndBadIdentities() {
        XCTAssertNil(
            MemoryChangeRefused(
                frame: parse(
                    #"{"type":"memory_change_refused","chat_id":"\#(chat)","code":"whatever","message":"m"}"#)!))
        XCTAssertNil(
            MemoryChangeRefused(
                frame: parse(
                    #"{"type":"memory_change_refused","chat_id":"\#(chat)","change_id":"nope","code":"stale_revision","message":"m"}"#
                )!))
        XCTAssertNil(
            MemoryChangeRefused(
                frame: parse(#"{"type":"memory_change_refused","chat_id":"\#(chat)","code":"not_found"}"#)!))
        XCTAssertNil(
            MemoryChangeRefused(
                frame: parse(
                    #"{"type":"memory_change_refused","chat_id":"not-a-uuid","code":"not_found","message":"m"}"#)!))
    }

    func testOutboundIntentsCarryExactFieldsAndFences() {
        let use = ChatMemoryOutbound.chatMemoryUse(chat, enabled: false, sessionId: chat)
        let repeated = ChatMemoryOutbound.chatMemoryUse(
            chat, enabled: false, sessionId: chat, submissionId: submissionId(use!),
            requestGeneration: requestGeneration(use!))
        XCTAssertNotEqual(use, repeated)
        XCTAssertEqual(submissionId(use!), submissionId(repeated))
        XCTAssertEqual(requestGeneration(use!), requestGeneration(repeated))
        XCTAssertEqual(payload(use!)?["chat_id"], .string(chat))
        XCTAssertEqual(payload(use!)?["enabled"], .bool(false))
        XCTAssertEqual(action(use!), "chat_memory_use")
        XCTAssertNotNil(continuityUUID4(payload(use!)?["client_message_id"]?.stringValue))
        XCTAssertNotNil(continuityUUID4(submissionId(use!)))
        XCTAssertNotNil(continuityUUID4(requestGeneration(use!)))

        let learn = ChatMemoryOutbound.chatMemoryLearn(chat, enabled: true, sessionId: chat)
        XCTAssertEqual(payload(learn!)?["enabled"], .bool(true))
        XCTAssertEqual(action(learn!), "chat_memory_learn")

        let forget = ChatMemoryOutbound.chatMemoryForget(chat, sessionId: chat)
        XCTAssertEqual(action(forget!), "chat_memory_forget")
        let forgetPayload = payload(forget!)?.objectValue ?? [:]
        XCTAssertEqual(Set(forgetPayload.keys), ["chat_id", "client_message_id"])

        let undo = ChatMemoryOutbound.chatMemoryUndo(chat, changeId: change, expectedRevision: 4, sessionId: chat)
        XCTAssertEqual(action(undo!), "chat_memory_undo")
        XCTAssertEqual(payload(undo!)?["change_id"], .string(change))
        XCTAssertEqual(payload(undo!)?["expected_revision"], .number(4))

        let approve = ChatMemoryOutbound.chatMemoryDecide(
            chat, changeId: change, decisionApproves: true, expectedRevision: 2, sessionId: chat)
        XCTAssertEqual(action(approve!), "chat_memory_decide")
        XCTAssertEqual(payload(approve!)?["decision"], .string("approve"))
        let reject = ChatMemoryOutbound.chatMemoryDecide(
            chat, changeId: change, decisionApproves: false, expectedRevision: 2, sessionId: chat)
        XCTAssertEqual(payload(reject!)?["decision"], .string("reject"))
    }

    func testOutboundIntentsRejectMalformedIdentitiesAndRevisions() {
        XCTAssertNil(ChatMemoryOutbound.chatMemoryUse("nope", enabled: true, sessionId: chat))
        XCTAssertNil(ChatMemoryOutbound.chatMemoryLearn("nope", enabled: true, sessionId: chat))
        XCTAssertNil(ChatMemoryOutbound.chatMemoryForget("nope", sessionId: chat))
        XCTAssertNil(
            ChatMemoryOutbound.chatMemoryUndo(chat, changeId: "nope", expectedRevision: 1, sessionId: chat))
        XCTAssertNil(ChatMemoryOutbound.chatMemoryUndo(chat, changeId: change, expectedRevision: 0, sessionId: chat))
        XCTAssertNil(
            ChatMemoryOutbound.chatMemoryDecide(
                chat, changeId: change, decisionApproves: true, expectedRevision: 0, sessionId: chat))
    }

    func testSnapshotMessagesCarryTheOptionalChipField() {
        let withChange = ConversationMessage(
            json: parse(
                """
                {"message_id":"\(message)","role":"assistant","created_at":"2026-11-03T10:00:00Z",
                 "parts":[{"type":"text","text":"Saved it"}],"attachments":[],
                 "memory_change":{"change_id":"\(change)","state":"applied","summary":"Remembered","revision":2}}
                """)!.payload)
        XCTAssertEqual(withChange?.memoryChange?.changeId, change)
        let withoutChange = ConversationMessage(
            json: parse(
                """
                {"message_id":"\(message)","role":"assistant","created_at":"2026-11-03T10:00:00Z",
                 "parts":[{"type":"text","text":"Hello"}],"attachments":[]}
                """)!.payload)
        XCTAssertNil(withoutChange?.memoryChange)
        XCTAssertNil(
            ConversationMessage(
                json: parse(
                    """
                    {"message_id":"\(message)","role":"assistant","created_at":"2026-11-03T10:00:00Z",
                     "parts":[{"type":"text","text":"Hello"}],"attachments":[],
                     "memory_change":{"change_id":"\(change)","state":"applied","summary":"Remembered","revision":2},
                     "unexpected":true}
                    """)!.payload))
        XCTAssertNil(
            ConversationMessage(
                json: parse(
                    """
                    {"message_id":"\(message)","role":"assistant","created_at":"2026-11-03T10:00:00Z",
                     "parts":[{"type":"text","text":"Hello"}],"attachments":[],
                     "memory_change":{"change_id":"\(change)","state":"applied","summary":"Remembered"}}
                    """)!.payload))
    }

    private func action(_ frameText: String) -> String? {
        (try? JSONValue.parse(Data(frameText.utf8)))?["action"]?.stringValue
    }

    private func payload(_ frameText: String) -> JSONValue? {
        (try? JSONValue.parse(Data(frameText.utf8)))?["payload"]
    }

    private func submissionId(_ frameText: String) -> String {
        (try? JSONValue.parse(Data(frameText.utf8)))?["submission_id"]?.stringValue ?? ""
    }

    private func requestGeneration(_ frameText: String) -> String {
        (try? JSONValue.parse(Data(frameText.utf8)))?["request_generation"]?.stringValue ?? ""
    }
}

// Covers Mac per-turn conversation actions: exact intent payloads, running and read-only fences, refusal
// recovery that keeps the current branch, branch switcher state from server snapshots, and sidebar-stable
// fork failures.

#if os(macOS)
    import AppKit
    import AstralCore
    import Foundation
    import SwiftUI
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class MacConversationTurnActionTests: XCTestCase {
        private let chat = "11111111-1111-4111-8111-111111111111"
        private let connection = "22222222-2222-4222-8222-222222222222"
        private let older = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        private let mine = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        private let newer = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        private let reply = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        private let group = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"

        override func tearDown() {
            NSPasteboard.general.clearContents()
            super.tearDown()
        }

        private func model() -> AppModel {
            let suite = "MacConversationTurnActionTests.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else {
                XCTFail("No defaults suite")
                return AppModel(
                    conversationResumeStore: ConversationResumeStore(),
                    tokenStore: InMemoryTokenStore(), defaults: .standard)
            }
            addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
            let model = AppModel(
                conversationResumeStore: ConversationResumeStore(defaults: defaults),
                tokenStore: InMemoryTokenStore(), defaults: defaults)
            model.signedIn = true
            model.connected = true
            XCTAssertTrue(model.beginConversationConnection(connection))
            model.activeChatId = chat
            return model
        }

        private func turn(
            _ id: String, role: String, text: String, branch: ConversationMessageBranch? = nil
        ) -> AppModel.ChatTurn {
            AppModel.ChatTurn(id: id, role: role, text: text, components: [], branch: branch)
        }

        private func siblingBranch(
            index: Int, siblings: [String], messageId: String
        ) -> ConversationMessageBranch {
            ConversationMessageBranch(
                json: .object([
                    "group_id": .string(group),
                    "index": .number(Double(index)),
                    "count": .number(Double(siblings.count)),
                    "siblings": .array(siblings.map { .string($0) }),
                ]), messageId: messageId)!
        }

        private func capture(_ model: AppModel) -> () -> [JSONValue] {
            var sent: [JSONValue] = []
            model.outboundTap = { text in
                if let frame = try? JSONValue.parse(Data(text.utf8)) { sent.append(frame) }
            }
            return { sent }
        }

        private func submissionId(of frame: JSONValue) -> String? {
            frame["submission_id"]?.stringValue
        }

        private func refusal(_ submissionId: String) -> InboundFrame {
            InboundFrame(
                name: "error",
                payload: .object([
                    "type": .string("error"),
                    "submission_id": .string(submissionId),
                    "accepted": .bool(false),
                    "code": .string("operation_failed"),
                    "message": .string("Conversation branches are not available on this server yet."),
                    "retryable": .bool(false),
                    "retry_after_ms": .null,
                ]))
        }

        private func hydrateBranchedTurns(_ model: AppModel) throws {
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
                           {"message_id":"\(older)","role":"user","created_at":"2026-11-03T09:59:00Z",
                            "parts":[{"type":"text","text":"First wording"}],"attachments":[]},
                           {"message_id":"\(mine)","role":"user","created_at":"2026-11-03T10:00:00Z",
                            "parts":[{"type":"text","text":"Revised wording"}],"attachments":[],
                            "branch":{"group_id":"\(group)","index":2,"count":3,
                              "siblings":["\(older)","\(mine)","\(newer)"]}}
                         ],
                         "canvas":{"target":"canvas","components":[]}}
                        """)!))
        }

        private func parse(_ text: String) -> JSONValue? {
            try? JSONValue.parse(Data(text.utf8))
        }

        func testForkFromUserTurnDispatchesExactChatForkIntent() {
            let model = model()
            model.turns = [turn(mine, role: "user", text: "Question")]
            let sent = capture(model)

            model.forkFromTurn(turn(mine, role: "user", text: "Question"))

            guard let frame = sent().last else {
                XCTFail("No outbound frame was captured")
                return
            }
            XCTAssertEqual(frame["action"], .string("chat_fork"))
            XCTAssertEqual(frame["session_id"], .string(chat))
            XCTAssertEqual(frame["payload"]?["chat_id"], .string(chat))
            XCTAssertEqual(frame["payload"]?["turn_id"], .string(mine))
            XCTAssertNil(frame["payload"]?["summarize_departed"])
            XCTAssertNil(model.pendingTurnDeparture)
        }

        func testForkWithBranchStructureWaitsForTheOptionalSummaryChoice() {
            let model = model()
            model.turns = [
                turn(older, role: "user", text: "First wording"),
                turn(
                    mine, role: "user", text: "Revised wording",
                    branch: siblingBranch(
                        index: 2, siblings: [older, mine, newer], messageId: mine)),
            ]
            let sent = capture(model)

            model.forkFromTurn(turn(mine, role: "user", text: "Revised wording"))
            XCTAssertEqual(sent().count, 0)
            XCTAssertNotNil(model.pendingTurnDeparture)

            model.cancelTurnDeparture()
            XCTAssertNil(model.pendingTurnDeparture)
            XCTAssertEqual(sent().count, 0)

            model.forkFromTurn(turn(mine, role: "user", text: "Revised wording"))
            model.confirmTurnDeparture(summarizeDeparted: true)
            guard let frame = sent().last else {
                XCTFail("No outbound frame was captured")
                return
            }
            XCTAssertEqual(frame["action"], .string("chat_fork"))
            XCTAssertEqual(frame["payload"]?["summarize_departed"], .bool(true))
            XCTAssertNil(model.pendingTurnDeparture)
        }

        func testRegenerateDispatchesChatRegenerateForAssistantTurns() {
            let model = model()
            model.turns = [
                turn(mine, role: "user", text: "Question"),
                turn(reply, role: "assistant", text: "Answer"),
            ]
            let sent = capture(model)

            model.regenerateTurn(turn(reply, role: "assistant", text: "Answer"))
            guard let frame = sent().last else {
                XCTFail("No outbound frame was captured")
                return
            }
            XCTAssertEqual(frame["action"], .string("chat_regenerate"))
            XCTAssertEqual(frame["payload"]?["chat_id"], .string(chat))
            XCTAssertEqual(frame["payload"]?["turn_id"], .string(reply))

            _ = sent()
            model.regenerateTurn(turn(mine, role: "user", text: "Question"))
            XCTAssertEqual(sent().count, 1)
        }

        func testBranchSelectDispatchesTheExactTargetSibling() {
            let model = model()
            let branched = turn(
                mine, role: "user", text: "Revised wording",
                branch: siblingBranch(index: 2, siblings: [older, mine, newer], messageId: mine))
            model.turns = [turn(older, role: "user", text: "First wording"), branched]
            let sent = capture(model)

            model.selectBranch(of: branched, targetTurnId: newer)
            XCTAssertNotNil(model.pendingTurnDeparture)
            XCTAssertEqual(sent().count, 0)
            model.confirmTurnDeparture(summarizeDeparted: false)
            XCTAssertNil(model.pendingTurnDeparture)
            guard let frame = sent().last else {
                XCTFail("No outbound frame was captured")
                return
            }
            XCTAssertEqual(frame["action"], .string("chat_branch_select"))
            XCTAssertEqual(frame["payload"]?["turn_id"], .string(mine))
            XCTAssertEqual(frame["payload"]?["target_turn_id"], .string(newer))
            XCTAssertNil(frame["payload"]?["summarize_departed"])

            model.selectBranch(of: branched, targetTurnId: reply)
            model.confirmTurnDeparture(summarizeDeparted: false)
            model.selectBranch(of: branched, targetTurnId: mine)
            model.confirmTurnDeparture(summarizeDeparted: false)
            XCTAssertEqual(sent().count, 1)
        }

        func testRunningTurnDisablesEveryTurnAction() {
            let model = model()
            model.turns = [
                turn(mine, role: "user", text: "Question"),
                turn(reply, role: "assistant", text: "Answer"),
            ]
            let sent = capture(model)
            model.turnActive = true

            XCTAssertFalse(model.canActOnTurns)
            model.forkFromTurn(turn(mine, role: "user", text: "Question"))
            model.regenerateTurn(turn(reply, role: "assistant", text: "Answer"))
            model.beginTurnEdit(turn(mine, role: "user", text: "Question"))
            model.selectBranch(
                of: turn(
                    mine, role: "user", text: "Question",
                    branch: siblingBranch(
                        index: 1, siblings: [mine, newer], messageId: mine)),
                targetTurnId: newer)

            XCTAssertEqual(sent().count, 0)
            XCTAssertNil(model.turnEditor)
            XCTAssertNil(model.pendingTurnDeparture)
        }

        func testReadOnlySignedOutAndMandatoryStatesDisableTurnActions() {
            for state in ["read_only", "signed_out", "disconnected", "mandatory", "no_chat"] {
                let model = model()
                model.turns = [turn(mine, role: "user", text: "Question")]
                if state == "read_only" { model.timelineReadOnly = true }
                if state == "signed_out" { model.signedIn = false }
                if state == "disconnected" { model.connected = false }
                if state == "mandatory" { model.mandatorySurface = true }
                if state == "no_chat" { model.activeChatId = nil }
                let sent = capture(model)

                model.forkFromTurn(turn(mine, role: "user", text: "Question"))
                model.beginTurnEdit(turn(mine, role: "user", text: "Question"))
                model.sendEditedTurn()

                XCTAssertEqual(sent().count, 0, state)
                XCTAssertNil(model.turnEditor, state)
            }
        }

        func testRefusedForkShowsRefusalAndKeepsTheCurrentBranch() {
            let model = model()
            model.turns = [turn(mine, role: "user", text: "Question")]
            let sent = capture(model)

            model.forkFromTurn(turn(mine, role: "user", text: "Question"))
            guard let frame = sent().last else {
                XCTFail("No outbound frame was captured")
                return
            }
            guard let submission = submissionId(of: frame) else {
                XCTFail("The captured frame carried no submission identifier")
                return
            }
            XCTAssertEqual(model.activeChatId, chat)

            model.handleFrame(refusal(submission))

            XCTAssertEqual(model.errorBanner, "Conversation branches are not available on this server yet.")
            XCTAssertTrue(model.bannerIsError)
            XCTAssertEqual(model.activeChatId, chat)
            XCTAssertEqual(model.turns.map(\.id), [mine])
            XCTAssertTrue(model.projects.chats.isEmpty)
            XCTAssertNil(model.pendingTurnDeparture)
        }

        func testRefusedEditResendDiscardsTheOptimisticTurnAndKeepsTheBranch() {
            let model = model()
            model.turns = [turn(mine, role: "user", text: "Question")]
            let sent = capture(model)

            model.beginTurnEdit(turn(mine, role: "user", text: "Question"))
            model.turnEditor?.draft = "Take two"
            model.sendEditedTurn()

            XCTAssertNil(model.turnEditor)
            XCTAssertEqual(model.transientTurns.count, 1)
            guard let frame = sent().last else {
                XCTFail("No outbound frame was captured")
                return
            }
            XCTAssertEqual(frame["action"], .string("chat_message"))
            XCTAssertEqual(frame["payload"]?["revised_turn_id"], .string(mine))
            XCTAssertEqual(frame["payload"]?["message"], .string("Take two"))
            guard let submission = submissionId(of: frame) else {
                XCTFail("The captured frame carried no submission identifier")
                return
            }

            model.handleFrame(refusal(submission))

            XCTAssertEqual(model.errorBanner, "Conversation branches are not available on this server yet.")
            XCTAssertEqual(model.transientTurns.count, 0)
            XCTAssertEqual(model.turns.map(\.id), [mine])
            XCTAssertEqual(model.activeChatId, chat)
        }

        func testAReconnectKeepsAnEditWhoseTurnIsStillThere() throws {
            let model = model()
            model.turns = [turn(mine, role: "user", text: "Revised wording")]
            model.beginTurnEdit(turn(mine, role: "user", text: "Revised wording"))
            model.turnEditor?.draft = "A long revision typed before the drop"
            try hydrateBranchedTurns(model)
            XCTAssertEqual(model.turnEditor?.draft, "A long revision typed before the drop")
        }

        func testAnEditIsDroppedWhenItsTurnIsGone() throws {
            let model = model()
            let gone = "ffffffff-ffff-4fff-8fff-ffffffffffff"
            model.turns = [turn(gone, role: "user", text: "Old")]
            model.beginTurnEdit(turn(gone, role: "user", text: "Old"))
            try hydrateBranchedTurns(model)
            XCTAssertNil(model.turnEditor)
        }

        func testEditedTurnClearedByBranchSwitchingSnapshotLeavesNoStaleEditor() throws {
            let model = model()
            model.turns = [turn(mine, role: "user", text: "Question")]
            model.beginTurnEdit(turn(mine, role: "user", text: "Question"))
            XCTAssertNotNil(model.turnEditor)

            try hydrateBranchedTurns(model)

            XCTAssertNil(model.turnEditor)
            XCTAssertTrue(model.conversationShowsBranches)
            XCTAssertEqual(model.turns.count, 2)
            XCTAssertEqual(model.turns[1].branch?.groupId, group)
            XCTAssertEqual(model.turns[1].branch?.index, 2)
            XCTAssertEqual(model.turns[1].branch?.count, 3)
        }

        func testSnapshotWithoutBranchesKeepsTheConversationUnbranched() {
            let model = model()
            let generation = UUID().uuidString.lowercased()
            XCTAssertTrue(
                model.openConversationRequest(chatId: chat, requestGeneration: generation, purpose: .hydration))
            model.handleFrame(
                InboundFrame(
                    name: "conversation_snapshot",
                    payload: parse(
                        """
                        {"type":"conversation_snapshot","schema_version":1,
                         "snapshot_id":"66666666-6666-4666-8666-666666666666","chat_id":"\(chat)",
                         "connection_generation":"\(connection)","request_generation":"\(generation)",
                         "snapshot_purpose":"hydration","render_revision":1,
                         "committed_at":"2026-11-03T10:01:00Z",
                         "transcript":[
                           {"message_id":"\(mine)","role":"user","created_at":"2026-11-03T10:00:00Z",
                            "parts":[{"type":"text","text":"Question"}],"attachments":[]}
                         ],
                         "canvas":{"target":"canvas","components":[]}}
                        """)!))

            XCTAssertFalse(model.conversationShowsBranches)
            XCTAssertNil(model.turns.first?.branch)
        }

        func testCopyTurnTextPlacesPlainTextOnThePasteboard() {
            let model = model()
            model.copyTurnText(turn(mine, role: "assistant", text: "Answer body"))

            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Answer body")
            XCTAssertEqual(model.errorBanner, "Copied to clipboard.")
            XCTAssertFalse(model.bannerIsError)

            model.copyTurnText(turn(mine, role: "assistant", text: ""))
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Answer body")
        }

        func testEditFlowPrefillsCancelsAndRefusesEmptySends() {
            let model = model()
            model.turns = [turn(mine, role: "user", text: "Question")]
            let sent = capture(model)

            model.beginTurnEdit(turn(mine, role: "user", text: "Question"))
            XCTAssertEqual(model.turnEditor?.turnId, mine)
            XCTAssertEqual(model.turnEditor?.draft, "Question")
            XCTAssertEqual(model.turnEditor?.summarizesDeparted, false)

            model.sendEditedTurn()
            XCTAssertEqual(sent().count, 0)

            model.turnEditor?.draft = "   "
            model.sendEditedTurn()
            XCTAssertEqual(sent().count, 0)

            model.turnEditor?.draft = "Take two"
            model.sendEditedTurn()
            XCTAssertEqual(sent().count, 1)
            guard let frame = sent().last else {
                XCTFail("No outbound frame was captured")
                return
            }
            XCTAssertEqual(frame["payload"]?["message"], .string("Take two"))
            XCTAssertEqual(frame["payload"]?["revised_turn_id"], .string(mine))
            XCTAssertNil(frame["payload"]?["summarize_departed"])

            model.cancelTurnEdit()
            XCTAssertNil(model.turnEditor)
        }

        func testEditOfferedOnlyForUserTurnsAndRegenerateOnlyForOtherRoles() {
            let model = model()
            model.turns = [
                turn(mine, role: "user", text: "Question"),
                turn(reply, role: "assistant", text: "Answer"),
            ]
            let sent = capture(model)

            model.beginTurnEdit(turn(reply, role: "assistant", text: "Answer"))
            XCTAssertNil(model.turnEditor)
            model.beginTurnEdit(turn(mine, role: "user", text: "Question"))
            XCTAssertNotNil(model.turnEditor)
            model.cancelTurnEdit()

            model.regenerateTurn(turn(reply, role: "assistant", text: "Answer"))
            XCTAssertEqual(sent().count, 1)
            XCTAssertEqual(sent().last?["action"], .string("chat_regenerate"))
        }

        func testPendingProjectNegotiationPreservesTheEditedDraftUntilSubmissionIsReady() {
            let model = model()
            model.turns = [turn(mine, role: "user", text: "Question")]
            model.beginTurnEdit(turn(mine, role: "user", text: "Question"))
            model.turnEditor?.draft = "Revised question"
            model.projects.bind(
                scope: "pending-owner", client: RestClient(serverBase: model.serverBase, tokenProvider: { nil }))
            let sent = capture(model)

            model.sendEditedTurn()

            XCTAssertTrue(sent().isEmpty)
            XCTAssertEqual(model.turnEditor?.draft, "Revised question")
            XCTAssertTrue(model.transientTurns.isEmpty)
            model.projects.negotiate(false)
            model.sendEditedTurn()
            XCTAssertEqual(sent().count, 1)
            XCTAssertNil(model.turnEditor)
            XCTAssertEqual(model.transientTurns.last?.text, "Revised question")
        }

        func testSteerPresentationRetainsItsLabelAndActualRoleActions() async throws {
            let model = model()
            let steer = turn(mine, role: "steer", text: "Use the staging cluster")
            model.turns = [steer]
            let mount = SurfaceMount(
                MacWorkbenchTranscript(maximumWidth: 720, contentPadding: EdgeInsets()), model: model,
                size: CGSize(width: 760, height: 500))
            defer { mount.close() }
            try await mount.settle()

            let tree = try mount.accessibility
            XCTAssertEqual(tree.first { $0.identifier == "conversation-turn-\(mine)" }?.label, "Steer")
            let steerLabel = tree.first { $0.identifier == "transcript-steer-label" }
            XCTAssertEqual(steerLabel?.label ?? steerLabel?.value, "Steer")
            XCTAssertNil(tree.first { $0.identifier == "conversation-edit-\(mine)" })
            XCTAssertEqual(tree.first { $0.identifier == "conversation-copy-\(mine)" }?.label, "Copy")
            XCTAssertEqual(tree.first { $0.identifier == "conversation-fork-\(mine)" }?.label, "Fork from here")

            model.beginTurnEdit(steer)
            XCTAssertNil(model.turnEditor)
        }

        func testTranscriptExposesNamedActionsAndTheSwitcherToAccessibility() async throws {
            let model = model()
            model.turns = [
                turn(older, role: "user", text: "First wording"),
                turn(
                    mine, role: "user", text: "Revised wording",
                    branch: siblingBranch(
                        index: 2, siblings: [older, mine, newer], messageId: mine)),
                turn(reply, role: "assistant", text: "Answer"),
            ]
            let mount = SurfaceMount(
                MacWorkbenchTranscript(maximumWidth: 720, contentPadding: EdgeInsets()), model: model,
                size: CGSize(width: 760, height: 900))
            defer { mount.close() }
            try await mount.settle()

            let tree = try mount.accessibility
            let named = { (identifier: String) -> SurfaceAccessibility.Element? in
                tree.first { $0.identifier == identifier }
            }
            XCTAssertEqual(named("conversation-edit-\(mine)")?.label, "Edit and resend")
            XCTAssertEqual(named("conversation-copy-\(mine)")?.label, "Copy")
            XCTAssertEqual(named("conversation-fork-\(mine)")?.label, "Fork to new chat")
            XCTAssertEqual(named("conversation-regenerate-\(reply)")?.label, "Regenerate reply")
            XCTAssertEqual(named("conversation-fork-\(reply)")?.label, "Fork from here")
            XCTAssertEqual(named("conversation-turn-\(mine)")?.label, "You")

            XCTAssertEqual(named("conversation-branch-\(mine)")?.label, "Branch 2 of 3")
            let position = named("conversation-branch-position-\(mine)")
            XCTAssertEqual(position?.label ?? position?.value, "2 of 3")
            XCTAssertEqual(named("conversation-branch-previous-\(mine)")?.enabled, true)
            XCTAssertEqual(named("conversation-branch-next-\(mine)")?.enabled, true)

            model.turnActive = true
            try await mount.settle()
            let busy = try mount.accessibility
            for identifier in [
                "conversation-edit-\(mine)", "conversation-copy-\(mine)", "conversation-fork-\(mine)",
                "conversation-regenerate-\(reply)", "conversation-fork-\(reply)",
                "conversation-branch-previous-\(mine)", "conversation-branch-next-\(mine)",
            ] {
                XCTAssertEqual(busy.first { $0.identifier == identifier }?.enabled, false, identifier)
            }
        }
    }
#endif

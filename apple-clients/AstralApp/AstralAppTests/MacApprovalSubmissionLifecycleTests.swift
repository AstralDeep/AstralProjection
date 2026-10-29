// Covers approval-button submission cleanup across canonical receipts and pre-send transport failure.

#if os(macOS)
    import AstralCore
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class MacApprovalSubmissionLifecycleTests: XCTestCase {
        private let request = String(repeating: "ab", count: 16)
        private let chat = "33333333-3333-4333-8333-333333333333"
        private var suites: [String] = []

        override func tearDown() {
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
            suites.removeAll()
            super.tearDown()
        }

        private func model() throws -> (AppModel, String, () -> [JSONValue]) {
            let (model, suite) = try SurfaceFixtures.model()
            suites.append(suite)
            let connection = UUID().uuidString.lowercased()
            XCTAssertTrue(model.beginConversationConnection(connection))
            model.activeChatId = chat
            model.projects.bind(
                scope: "surface-owner",
                client: RestClient(serverBase: URL(string: "https://example.test")!, tokenProvider: { nil }))
            model.projects.negotiate(true)
            var sent: [JSONValue] = []
            model.outboundTap = { text in
                if let frame = try? JSONValue.parse(Data(text.utf8)) { sent.append(frame) }
            }
            return (model, connection, { sent })
        }

        private func card() -> AstralComponent {
            AstralComponent(
                type: "card",
                raw: .object([
                    "type": .string("card"), "id": .string("au_approval_\(request)"),
                    "title": .string("Confirm an action on this Mac"),
                    "content": .array([
                        .object(["type": .string("text"), "content": .string("Confirm the proposed action")]),
                        .object([
                            "type": .string("button"), "label": .string("Approve"),
                            "action": .string("remote_op_decision"),
                            "payload": .object(["proposal_id": .string(request), "decision": .string("approve")]),
                        ]),
                        .object([
                            "type": .string("button"), "label": .string("Decline"),
                            "action": .string("remote_op_decision"),
                            "payload": .object(["proposal_id": .string(request), "decision": .string("decline")]),
                        ]),
                    ]),
                ]))
        }

        private func receipt(_ connection: String, state: String, decision: String) -> InboundFrame {
            InboundFrame(
                name: "chat_status",
                payload: .object([
                    "type": .string("chat_status"), "status": .string("approval_decision"),
                    "chat_id": .string(chat), "connection_generation": .string(connection),
                    "approval_decision": .object([
                        "request_id": .string(request), "decision": .string(decision),
                        "state": .string(state), "message": .string("Server receipt: \(state)"),
                        "revision": .number(1),
                    ]),
                ]))
        }

        func testCanonicalApprovalReceiptClearsOnlyItsLocalSubmission() throws {
            for (state, decision, expected) in [
                ("accepted", "approve", AppModel.ActivityRow.Approval.approved),
                ("refused", "decline", AppModel.ActivityRow.Approval.refused),
            ] {
                let (model, connection, sent) = try model()
                model.currentApprovalDecisionSendOverride = { _, _ in true }
                model.canvas = [card()]
                let prompt = try XCTUnwrap(model.approvalPrompts.first)

                model.sendEvent("discover_agents")
                let unrelated = try XCTUnwrap(
                    sent().first { $0["action"] == .string("discover_agents") }?["submission_id"]?.stringValue)
                model.decideApproval(prompt, allow: decision != "decline")
                let approval = try XCTUnwrap(
                    sent().first { $0["action"] == .string("remote_op_decision") }?["submission_id"]?.stringValue)

                XCTAssertNotNil(model.localOperationSubmissions[approval])
                XCTAssertNotNil(model.localOperationSubmissions[unrelated])
                model.handleFrame(receipt(UUID().uuidString.lowercased(), state: state, decision: decision))
                XCTAssertNotNil(model.localOperationSubmissions[approval])
                model.handleFrame(receipt(connection, state: state, decision: decision))

                XCTAssertNil(model.localOperationSubmissions[approval])
                XCTAssertNotNil(model.localOperationSubmissions[unrelated])
                XCTAssertEqual(model.activity.last?.approval, expected)
                XCTAssertEqual(model.statusText, "Submitting…")
                XCTAssertEqual(sent().filter { $0["action"] == .string("remote_op_decision") }.count, 1)
            }
        }

        func testDecisionNotSentWithoutAUsableSocketSettlesAsUncertainWithoutReplay() throws {
            let (model, _, sent) = try model()
            model.canvas = [card()]
            model.decideApproval(try XCTUnwrap(model.approvalPrompts.first), allow: true)

            XCTAssertEqual(model.activity.last?.approval, .uncertain)
            XCTAssertNotEqual(model.statusText, "Submitting…")
            XCTAssertNotNil(model.errorBanner)
            XCTAssertEqual(sent().filter { $0["action"] == .string("remote_op_decision") }.count, 1)
        }
    }
#endif

// Covers the main-window approval banner: a pending review card, including a browser-pane origin, is named, counted
// in the footer and answerable with Allow or Deny even while the browser pane is collapsed, in the three themes.

#if os(macOS)
    import AppKit
    import AstralCore
    import SwiftUI
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class MacApprovalBannerTests: XCTestCase {
        private let proposal = String(repeating: "ab", count: 16)
        private var suites: [String] = []

        override func tearDown() {
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
            suites.removeAll()
            super.tearDown()
        }

        private func originCard(disabled: Bool = false) -> AstralComponent {
            func button(_ label: String, _ decision: String) -> JSONValue {
                .object([
                    "type": .string("button"), "label": .string(label), "action": .string("remote_op_decision"),
                    "disabled": .bool(disabled),
                    "payload": .object(["proposal_id": .string(proposal), "decision": .string(decision)]),
                ])
            }
            return AstralComponent(
                type: "card",
                raw: .object([
                    "type": .string("card"), "id": .string("au_approval_\(proposal)"),
                    "title": .string("Confirm an action on Studio Mac"),
                    "content": .array([
                        .object([
                            "type": .string("text"), "variant": .string("body"),
                            "content": .string(
                                "Open https://docs.example.com/start in the Astral browser pane on Studio Mac. "
                                    + "Approving this site lets the pane load its pages; passwords and payment fields "
                                    + "are never filled."),
                        ]),
                        .object([
                            "type": .string("text"), "variant": .string("caption"),
                            "content": .string("This runs on your computer exactly as shown and I can't undo it."),
                        ]),
                        button("Approve", "approve"), button("Allow this site for the task", "grant_task"),
                        button("Decline", "decline"),
                    ]),
                ]))
        }

        private func model() throws -> (AppModel, () -> [JSONValue]) {
            let (model, suite) = try SurfaceFixtures.model()
            suites.append(suite)
            XCTAssertTrue(model.beginConversationConnection(UUID().uuidString.lowercased()))
            model.activeChatId = "33333333-3333-4333-8333-333333333333"
            var sent: [JSONValue] = []
            model.outboundTap = { text in if let frame = try? JSONValue.parse(Data(text.utf8)) { sent.append(frame) } }
            return (model, { sent })
        }

        private func decisions(_ frames: [JSONValue]) -> [JSONValue] {
            frames.filter { $0["action"] == .string("remote_op_decision") }.compactMap { $0["payload"] }
        }

        func testDecisionWaitsForCurrentConnectionReceiptAndCannotBeOverwritten() throws {
            let (model, _) = try model()
            let connection = UUID().uuidString.lowercased()
            XCTAssertTrue(model.beginConversationConnection(connection))
            model.projects.bind(
                scope: "owner",
                client: RestClient(serverBase: URL(string: "https://example.test")!, tokenProvider: { nil }))
            model.projects.negotiate(true)
            model.canvas = [originCard()]
            model.turnActive = true
            model.statusText = "Other work is running"
            model.decideApproval(try XCTUnwrap(model.approvalPrompts.first), allow: true)
            XCTAssertEqual(model.activity.last?.approvalLabel, "Decision submitted")
            let statusBeforeReceipt = model.statusText
            func receipt(_ generation: String, _ state: String) -> InboundFrame {
                InboundFrame(
                    name: "chat_status",
                    payload: .object([
                        "type": .string("chat_status"), "status": .string("approval_decision"),
                        "chat_id": .string(model.activeChatId!), "connection_generation": .string(generation),
                        "approval_decision": .object([
                            "request_id": .string(proposal), "decision": .string("approve"),
                            "revision": .number(1), "state": .string(state), "message": .string("Server receipt"),
                        ]),
                    ]))
            }
            model.handleFrame(receipt(UUID().uuidString.lowercased(), "accepted"))
            XCTAssertEqual(model.activity.last?.approvalLabel, "Decision submitted")
            model.handleFrame(receipt(connection, "accepted"))
            XCTAssertEqual(model.activity.last?.approvalLabel, "Approved")
            model.handleFrame(receipt(connection, "expired"))
            XCTAssertEqual(model.activity.last?.approvalLabel, "Approved")
            XCTAssertTrue(model.turnActive)
            XCTAssertEqual(model.statusText, statusBeforeReceipt)
        }
        func testServerAlertRemainsVisibleWhileReviewIsOpen() throws {
            let (model, _) = try model()
            model.canvas = [originCard()]
            model.handleFrame(
                InboundFrame(
                    name: "ui_render",
                    payload: .object([
                        "type": .string("ui_render"), "target": .string("chat"),
                        "components": .array([
                            .object([
                                "type": .string("alert"), "message": .string("This confirmation expired."),
                                "variant": .string("warning"),
                            ])
                        ]),
                    ])))
            XCTAssertEqual(model.errorBanner, "This confirmation expired.")
        }

        func testABrowserOriginApprovalIsNamedCountedAndAllowedWhileThePaneIsCollapsed() throws {
            let (model, sent) = try model()
            model.macBrowser.isPresented = false
            model.canvas = [originCard()]
            let prompt = try XCTUnwrap(model.approvalPrompts.first)
            XCTAssertEqual(model.approvalPrompts.count, 1)
            XCTAssertEqual(prompt.site, "https://docs.example.com")
            XCTAssertTrue(prompt.summary.hasPrefix("Open https://docs.example.com/start in the Astral browser pane"))
            XCTAssertEqual(model.waitingApprovals, 1)
            let footer = MacStatusFooterModel.items(
                connection: .connected, usage: LLMUsageTally(), approvals: model.waitingApprovals, computer: nil)
            XCTAssertEqual(footer.last?.text, "1 approval waiting")
            model.decideApproval(prompt, allow: true)
            let decided = try XCTUnwrap(decisions(sent()).last)
            XCTAssertEqual(decided["proposal_id"], .string(proposal))
            XCTAssertEqual(decided["decision"], .string("approve"))
            XCTAssertTrue(model.approvalPrompts.isEmpty)
            XCTAssertEqual(model.waitingApprovals, 0)
            model.decideApproval(prompt, allow: true)
            XCTAssertEqual(decisions(sent()).count, 1)
        }

        func testDenySendsTheCardsDeclineAndSettledCardsRaiseNoBanner() throws {
            let (model, sent) = try model()
            model.canvas = [originCard()]
            let prompt = try XCTUnwrap(model.approvalPrompts.first)
            model.decideApproval(prompt, allow: false)
            XCTAssertEqual(decisions(sent()).last?["decision"], .string("decline"))
            XCTAssertTrue(model.approvalPrompts.isEmpty)
            let (settled, _) = try self.model()
            settled.canvas = [originCard(disabled: true)]
            XCTAssertTrue(settled.approvalPrompts.isEmpty)
            XCTAssertEqual(settled.waitingApprovals, 0)
            XCTAssertNil(AppModel.approvalSite("Run ls in Documents on Studio Mac"))
            XCTAssertNil(AppModel.approvalSite("Open file:///etc in the Astral browser pane"))
            XCTAssertEqual(
                AppModel.approvalSite("Open http://127.0.0.1:8080/a in the Astral browser pane on M."),
                "http://127.0.0.1:8080")
        }

        func testBannerRendersInEachThemeAndItsButtonsDecide() async throws {
            for preset in SurfaceFixtures.presets {
                let (model, sent) = try model()
                model.canvas = [originCard()]
                let prompt = try XCTUnwrap(model.approvalPrompts.first)
                let mount = SurfaceMount(
                    MacApprovalBanner(prompt: prompt), model: model, size: CGSize(width: 820, height: 76),
                    preset: preset)
                defer { mount.close() }
                try await mount.settle()
                let text = try mount.text()
                for kept in ["https://docs.example.com", "Allow", "Deny"] {
                    XCTAssertTrue(text.contains(kept), "\(preset) missing \(kept): \(text)")
                }
                try mount.snapshot(self, name: "approval_banner-\(preset)")
                try mount.click(text: "Deny")
                try await mount.settle()
                XCTAssertEqual(decisions(sent()).last?["decision"], .string("decline"), preset)
            }
        }

        func testWorkbenchShowsTheBannerWithTheBrowserPaneCollapsed() async throws {
            let (model, sent) = try model()
            let fixture = try SurfaceFixtures.json("mac-workbench")
            let row = try XCTUnwrap(
                fixture["cases"]?.arrayValue?.first { $0["viewport"]?.arrayValue?.first?.numberValue == 1440 })
            model.handleFrame(
                InboundFrame(
                    name: "rote_config",
                    payload: .object([
                        "type": .string("rote_config"),
                        "device_profile": .object(["console": try XCTUnwrap(row["presentation"])]),
                    ])))
            let console = try XCTUnwrap(model.console)
            let presentation = try XCTUnwrap(model.consolePresentation)
            model.macBrowser.isPresented = false
            model.canvas = [originCard()]
            let mount = SurfaceMount(
                MacWorkbenchView(
                    console: console, presentation: presentation, workbench: try XCTUnwrap(presentation.workbench)),
                model: model, size: CGSize(width: 1440, height: 900))
            defer { mount.close() }
            try await mount.settle()
            let text = try mount.text()
            XCTAssertTrue(text.contains("https://docs.example.com"), text)
            XCTAssertTrue(text.contains("1 approval waiting"), text)
            try mount.snapshot(self, name: "workbench_approval_banner-graphite")
            try mount.click(text: "Allow")
            try await mount.settle()
            XCTAssertEqual(decisions(sent()).last?["decision"], .string("approve"))
        }

        func testBannerExposesItsNameSiteAndButtonsInReadingOrder() async throws {
            try SurfaceAccessibility.requireTrust()
            let (model, _) = try model()
            model.canvas = [originCard()]
            let prompt = try XCTUnwrap(model.approvalPrompts.first)
            let mount = SurfaceMount(
                MacApprovalBanner(prompt: prompt), model: model, size: CGSize(width: 820, height: 76))
            defer { mount.close() }
            try await mount.settle()
            let tree = mount.accessibility
            let banner = try XCTUnwrap(tree.first { $0.identifier == "approval-banner" })
            XCTAssertEqual(banner.label, "Approval waiting")
            let buttons = tree.filter { $0.role == kAXButtonRole }
            XCTAssertEqual(buttons.map(\.identifier), ["approval-banner-deny", "approval-banner-allow"])
            XCTAssertEqual(buttons.map(\.label), ["Deny", "Allow"])
            XCTAssertTrue(
                tree.contains { $0.value == "https://docs.example.com" || $0.label == "https://docs.example.com" })
        }
    }
#endif

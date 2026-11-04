// Covers the main-window approval banner and its review sheet: pending cards are named, counted and answerable with
// Deny plus one-click Allow for short single-line cards or Review for anything the banner would cut, in three themes.
// The sheet shows every text and code entry, approves only on Command-Return or its button, and echoes the payload.

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

        private let caption = "This runs on your computer exactly as shown and I can't undo it."
        private let shortSummary = "Open https://example.com/ in the Astral browser pane on MacBook"
        private let digest = String(repeating: "0f", count: 32)

        private func text(_ content: String, _ variant: String = "body") -> JSONValue {
            .object(["type": .string("text"), "variant": .string(variant), "content": .string(content)])
        }

        private func code(_ content: String) -> JSONValue {
            .object(["type": .string("code"), "language": .string("json"), "code": .string(content)])
        }

        private func reviewCard(_ content: [JSONValue], flags: [String] = [], digest: String? = nil) -> AstralComponent
        {
            func button(_ label: String, _ decision: String) -> JSONValue {
                .object([
                    "type": .string("button"), "label": .string(label), "action": .string("remote_op_decision"),
                    "payload": .object(["proposal_id": .string(proposal), "decision": .string(decision)]),
                ])
            }
            var raw: [String: JSONValue] = [
                "type": .string("card"), "id": .string("au_approval_\(proposal)"),
                "title": .string("Confirm an action on Studio Mac"),
                "content": .array(
                    content + [
                        button("Approve", "approve"),
                        button("Decline", "decline"),
                    ]),
            ]
            if !flags.isEmpty { raw["review_flags"] = .array(flags.map { .string($0) }) }
            if let digest { raw["display_digest"] = .string(digest) }
            return AstralComponent(type: "card", raw: .object(raw))
        }

        private func commandSummary() -> String {
            [
                "Run a command on Studio Mac", "Command: rm -rf build", "Folder: /Users/me/project",
                "Timeout: 60 s", "Environment: none", "Background: no",
            ].joined(separator: "\n")
        }

        private func reviewPrompt(_ card: AstralComponent) throws -> AppModel.ApprovalPrompt {
            let (model, _) = try model()
            model.canvas = [card]
            return try XCTUnwrap(model.approvalPrompts.first)
        }

        private func model() throws -> (AppModel, () -> [JSONValue]) {
            let (model, suite) = try SurfaceFixtures.model()
            suites.append(suite)
            XCTAssertTrue(model.beginConversationConnection(UUID().uuidString.lowercased()))
            model.activeChatId = "33333333-3333-4333-8333-333333333333"
            var sent: [JSONValue] = []
            model.outboundTap = { text in if let frame = try? JSONValue.parse(Data(text.utf8)) { sent.append(frame) } }
            model.currentApprovalDecisionSendOverride = { text, _ in WSClient.isApprovalDecision(text) }
            return (model, { sent })
        }

        private func decisions(_ frames: [JSONValue]) -> [JSONValue] {
            frames.filter { $0["action"] == .string("remote_op_decision") }.compactMap { $0["payload"] }
        }

        func testLegacyDecisionsStayUnconfirmedSendOnceAndSettleOnServerTurnCompletion() throws {
            for decision in ["approve", "grant_task", "decline"] {
                let (model, sent) = try model()
                let connection = UUID().uuidString.lowercased()
                XCTAssertTrue(model.beginConversationConnection(connection))
                XCTAssertFalse(model.projects.enabled)
                model.canvas = [originCard()]
                let payload: [String: JSONValue] = [
                    "proposal_id": .string(proposal), "decision": .string(decision),
                ]
                model.emit("remote_op_decision", payload: payload)
                XCTAssertEqual(decisions(sent()).count, 1)
                XCTAssertEqual(model.activity.last?.approval, .uncertain)
                XCTAssertTrue(model.activity.last?.result.contains("does not confirm") == true)
                XCTAssertTrue(model.canCancelTurn)
                model.handleFrame(receipt(connection, chat: model.activeChatId!, state: "accepted", decision: decision))
                XCTAssertEqual(model.activity.last?.approval, .uncertain)
                model.projects.bind(
                    scope: "owner",
                    client: RestClient(serverBase: URL(string: "https://example.test")!, tokenProvider: { nil }))
                model.projects.negotiate(true)
                model.handleFrame(receipt(connection, chat: model.activeChatId!, state: "accepted", decision: decision))
                XCTAssertEqual(model.activity.last?.approval, .uncertain)
                model.emit("remote_op_decision", payload: payload)
                XCTAssertEqual(decisions(sent()).count, 1)
                model.handleFrame(ActivityFrames.status("done"))
                XCTAssertEqual(model.activity.last?.approval, .uncertain)
                XCTAssertEqual(model.activity.last?.state, .completed)
                XCTAssertFalse(model.canCancelTurn)
                XCTAssertTrue(model.beginConversationConnection(UUID().uuidString.lowercased()))
                model.emit("remote_op_decision", payload: payload)
                XCTAssertEqual(decisions(sent()).count, 1)
                XCTAssertEqual(model.activity.last?.approval, .uncertain)
            }
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
        private func receipt(_ connection: String, chat: String, state: String, decision: String = "approve")
            -> InboundFrame
        {
            InboundFrame(
                name: "chat_status",
                payload: .object([
                    "type": .string("chat_status"), "status": .string("approval_decision"),
                    "chat_id": .string(chat), "connection_generation": .string(connection),
                    "approval_decision": .object([
                        "request_id": .string(proposal), "decision": .string(decision),
                        "revision": .number(1), "state": .string(state), "message": .string("Server: " + state),
                    ]),
                ]))
        }

        private func negotiated(_ model: AppModel, connection: String) {
            XCTAssertTrue(model.beginConversationConnection(connection))
            model.projects.bind(
                scope: "owner",
                client: RestClient(serverBase: URL(string: "https://example.test")!, tokenProvider: { nil }))
            model.projects.negotiate(true)
        }

        func testEveryTerminalReceiptIsStickyAndPreservesUnrelatedWork() throws {
            let cases: [(String, Bool, AppModel.ActivityRow.Approval)] = [
                ("accepted", true, .approved), ("refused", true, .refused), ("expired", true, .expired),
                ("error", true, .refused), ("uncertain", true, .uncertain), ("cancelled", true, .refused),
                ("cancelled", false, .denied), ("refused", false, .refused),
            ]
            for (state, allow, expected) in cases {
                let (model, sent) = try model()
                let connection = UUID().uuidString.lowercased()
                negotiated(model, connection: connection)
                let origin = try XCTUnwrap(model.activeChatId)
                model.canvas = [originCard()]
                let prompt = try XCTUnwrap(model.approvalPrompts.first)
                model.decideApproval(prompt, allow: allow)
                model.decideApproval(prompt, allow: allow)
                XCTAssertEqual(decisions(sent()).count, 1)
                model.activeChatId = "another-chat"
                model.turnActive = true
                model.statusText = "Another chat is running"
                let otherRows = model.activity
                let decision = allow ? "approve" : "decline"
                model.handleFrame(receipt(connection, chat: "foreign-chat", state: state, decision: decision))
                model.activeChatId = origin
                XCTAssertEqual(model.activity.last?.approval, .submitted)
                model.activeChatId = "another-chat"
                model.handleFrame(receipt(connection, chat: origin, state: state, decision: decision))
                XCTAssertEqual(model.activity, otherRows)
                XCTAssertTrue(model.turnActive)
                XCTAssertEqual(model.statusText, "Another chat is running")
                model.activeChatId = origin
                XCTAssertEqual(model.activity.last?.approval, expected, state)
                if state != "accepted" { XCTAssertEqual(model.activity.last?.result, "Server: " + state) }
                model.handleFrame(receipt(connection, chat: origin, state: "accepted", decision: decision))
                XCTAssertEqual(model.activity.last?.approval, expected)
                XCTAssertTrue(model.approvalPrompts.isEmpty)
            }
        }

        func testOldCardCannotSubmitUnderNewNavigation() throws {
            let (model, sent) = try model()
            model.canvas = [originCard()]
            let prompt = try XCTUnwrap(model.approvalPrompts.first)
            let original = model.activeChatId
            XCTAssertTrue(
                model.openConversationRequest(
                    chatId: "44444444-4444-4444-8444-444444444444", requestGeneration: UUID().uuidString.lowercased(),
                    purpose: .hydration))
            model.decideApproval(prompt, allow: true)
            XCTAssertTrue(decisions(sent()).isEmpty)
            XCTAssertTrue(model.activity.isEmpty)
            model.activeChatId = original
            XCTAssertNotEqual(model.activity.last?.approval, .submitted)
        }

        func testDisconnectAndConnectionReplacementRetireSubmittedWithoutReplay() async throws {
            for supportsReceipt in [true, false] {
                for disconnect in [true, false] {
                    let (model, sent) = try model()
                    let old = UUID().uuidString.lowercased()
                    if supportsReceipt {
                        negotiated(model, connection: old)
                    } else {
                        XCTAssertTrue(model.beginConversationConnection(old))
                    }
                    let chat = try XCTUnwrap(model.activeChatId)
                    model.canvas = [originCard()]
                    model.decideApproval(try XCTUnwrap(model.approvalPrompts.first), allow: true)
                    if disconnect { await model.handle(.disconnected(reason: "test")) }
                    XCTAssertTrue(model.beginConversationConnection(UUID().uuidString.lowercased()))
                    XCTAssertEqual(model.activity.last?.approval, .uncertain)
                    model.handleFrame(receipt(old, chat: chat, state: "accepted"))
                    XCTAssertEqual(model.activity.last?.approval, .uncertain)
                    XCTAssertTrue(model.approvalPrompts.isEmpty)
                    XCTAssertEqual(decisions(sent()).count, 1)
                }
            }
        }

        func testRefusalReceiptSurfacesItsMessageWithoutClearingBusyState() throws {
            let (model, _) = try model()
            let connection = UUID().uuidString.lowercased()
            negotiated(model, connection: connection)
            model.canvas = [originCard()]
            model.decideApproval(try XCTUnwrap(model.approvalPrompts.first), allow: true)
            model.turnActive = true
            model.statusText = "Working"
            model.handleFrame(receipt(connection, chat: model.activeChatId!, state: "refused"))
            XCTAssertEqual(model.errorBanner, "Server: refused")
            XCTAssertEqual(model.activity.last?.approval, .refused)
            XCTAssertTrue(model.turnActive)
            XCTAssertEqual(model.statusText, "Working")
        }

        func testReceiptFromPreviousOwnerCannotSettleDecision() throws {
            let (model, _) = try model()
            let connection = UUID().uuidString.lowercased()
            negotiated(model, connection: connection)
            model.canvas = [originCard()]
            model.decideApproval(try XCTUnwrap(model.approvalPrompts.first), allow: true)
            model.signedIn.toggle()
            model.handleFrame(receipt(connection, chat: model.activeChatId!, state: "accepted"))
            XCTAssertNotEqual(model.activity.last?.approval, .approved)
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
                for (card, primary, missing) in [
                    (reviewCard([text(commandSummary()), text(caption, "caption")]), "Review", "Allow"),
                    (originCard(), "Allow", "Review"),
                ] {
                    let (model, sent) = try model()
                    model.canvas = [card]
                    let prompt = try XCTUnwrap(model.approvalPrompts.first)
                    let mount = SurfaceMount(
                        MacApprovalBanner(prompt: prompt), model: model, size: CGSize(width: 820, height: 76),
                        preset: preset)
                    defer { mount.close() }
                    try await mount.settle()
                    let text = try mount.text()
                    for kept in [primary, "Deny"] {
                        XCTAssertTrue(text.contains(kept), "\(preset) missing \(kept): \(text)")
                    }
                    if let site = prompt.site {
                        let element = try XCTUnwrap(
                            mount.accessibility.first { $0.identifier == "approval-banner-site" })
                        XCTAssertTrue(element.label == site || element.value == site, preset)
                    }
                    XCTAssertFalse(text.contains(missing), "\(preset) shows \(missing): \(text)")
                    try mount.snapshot(self, name: "approval_banner-\(primary.lowercased())-\(preset)")
                    try mount.click(text: "Deny")
                    try await mount.settle()
                    XCTAssertEqual(decisions(sent()).last?["decision"], .string("decline"), preset)
                }
            }
        }

        func testWorkbenchShowsTheBannerWithTheBrowserPaneCollapsed() async throws {
            for reviewed in [false, true] {
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
                model.canvas = [
                    reviewed ? reviewCard([text(commandSummary()), text(caption, "caption")]) : originCard()
                ]
                let mount = SurfaceMount(
                    MacWorkbenchView(
                        console: console, presentation: presentation,
                        workbench: try XCTUnwrap(presentation.workbench)),
                    model: model, size: CGSize(width: 1440, height: 900))
                defer { mount.close() }
                try await mount.settle()
                let text = try mount.text()
                XCTAssertTrue(text.contains("1 approval waiting"), text)
                if reviewed {
                    XCTAssertNil(try mount.textFrame("Allow", exact: true))
                    try mount.click(text: "Review")
                    let sheet = try await attachedSheet(mount)
                    XCTAssertTrue(
                        sheet.performKeyEquivalent(
                            with: try SurfaceKey.commandReturn.event(windowNumber: sheet.windowNumber)))
                } else {
                    XCTAssertTrue(text.contains("https://docs.example.com"), text)
                    let summary = try XCTUnwrap(
                        try mount.accessibility.first { $0.identifier == "approval-banner-summary" })
                    XCTAssertEqual(summary.value ?? summary.label, try XCTUnwrap(model.approvalPrompts.first).summary)
                    XCTAssertTrue((summary.value ?? summary.label ?? "").hasSuffix("are never filled."))
                    try mount.snapshot(self, name: "workbench_approval_banner-graphite")
                    XCTAssertNil(try mount.textFrame("Review", exact: true))
                    try mount.click(text: "Allow")
                }
                try await mount.settle()
                XCTAssertEqual(decisions(sent()).last?["decision"], .string("approve"))
                XCTAssertNil(mount.window.attachedSheet)
            }
        }

        func testBannerExposesItsNameSiteAndButtonsInReadingOrder() async throws {
            for (card, site, primary) in [
                (reviewCard([text(commandSummary()), text(caption, "caption")]), nil, "review"),
                (originCard(), "https://docs.example.com", "allow"),
            ] {
                let (model, _) = try model()
                model.canvas = [card]
                let prompt = try XCTUnwrap(model.approvalPrompts.first)
                let mount = SurfaceMount(
                    MacApprovalBanner(prompt: prompt), model: model, size: CGSize(width: 820, height: 76))
                defer { mount.close() }
                try await mount.settle()
                let tree = try mount.accessibility
                let banner = try XCTUnwrap(tree.first { $0.identifier == "approval-banner" })
                XCTAssertEqual(banner.label, "Approval waiting")
                let buttons = tree.filter { $0.role == kAXButtonRole }
                XCTAssertEqual(buttons.map(\.identifier), ["approval-banner-deny", "approval-banner-\(primary)"])
                XCTAssertEqual(buttons.map(\.label), ["Deny", primary.capitalized])
                if let site { XCTAssertTrue(tree.contains { $0.value == site || $0.label == site }) }
            }
        }

        func testMultiLineCommandCardNeedsReviewAndKeepsEveryLine() throws {
            let prompt = try reviewPrompt(reviewCard([text(commandSummary()), text(caption, "caption")]))
            XCTAssertTrue(prompt.requiresReview)
            XCTAssertFalse(prompt.hiddenCharacters)
            XCTAssertEqual(prompt.title, "Confirm an action on Studio Mac")
            XCTAssertEqual(prompt.details, [commandSummary(), caption])
        }

        func testFlaggedCardNeedsReviewEvenWhenItsSummaryIsShort() throws {
            let escaped = "Open https://example.com/\\u{202E}fdp.exe in the Astral browser pane on MacBook"
            let flagged = try reviewPrompt(reviewCard([text(escaped)], flags: ["hidden_characters"]))
            XCTAssertTrue(flagged.requiresReview)
            XCTAssertTrue(flagged.hiddenCharacters)
            XCTAssertEqual(flagged.details, [escaped])
            let unflagged = try reviewPrompt(reviewCard([text(escaped)], flags: ["other_flag"]))
            XCTAssertFalse(unflagged.requiresReview)
            XCTAssertFalse(unflagged.hiddenCharacters)
        }

        func testInvisibleCharactersInTheSummaryNeedReviewWithoutAServerFlag() throws {
            for hidden in ["\u{202E}", "\u{200B}", "\u{2066}", "\u{FEFF}", "\u{0007}", "\u{2028}", "\r"] {
                let summary = "Open https://example.com/\(hidden)fdp.exe in the Astral browser pane on MacBook"
                let prompt = try reviewPrompt(reviewCard([text(summary)]))
                XCTAssertTrue(
                    prompt.requiresReview, summary.unicodeScalars.map { String($0.value, radix: 16) }.joined())
                XCTAssertFalse(prompt.hiddenCharacters)
            }
        }

        func testCodeChildrenAndLongLinesNeedReview() throws {
            XCTAssertTrue(
                try reviewPrompt(reviewCard([text(shortSummary), code("{\"path\": \"/tmp/a\"}")])).requiresReview)
            XCTAssertTrue(
                try reviewPrompt(
                    reviewCard([
                        text(shortSummary),
                        .object(["type": .string("table"), "headers": .array([.string("Key")]), "rows": .array([])]),
                    ])
                ).requiresReview)
            let edge = "Open https://example.com/ in the Astral browser pane on MacBook "
            let limit = edge + String(repeating: "a", count: 300 - edge.count)
            XCTAssertEqual(limit.count, 300)
            XCTAssertFalse(try reviewPrompt(reviewCard([text(limit)])).requiresReview)
            XCTAssertTrue(try reviewPrompt(reviewCard([text(limit + "b")])).requiresReview)
            XCTAssertTrue(try reviewPrompt(reviewCard([text(edge + " two  spaces")])).requiresReview)
            XCTAssertFalse(try reviewPrompt(originCard()).requiresReview)
        }

        func testOnlyCaptionsMayStayHiddenBehindOneClick() throws {
            let captioned = try reviewPrompt(
                reviewCard([text(shortSummary), text(caption, "caption"), text("Second caption", "caption")]))
            XCTAssertFalse(captioned.requiresReview)
            XCTAssertEqual(captioned.details, [shortSummary, caption, "Second caption"])
            let extra = try reviewPrompt(reviewCard([text(shortSummary), text("Folder: /Users/me/private")]))
            XCTAssertTrue(extra.requiresReview)
            XCTAssertEqual(extra.details, [shortSummary, "Folder: /Users/me/private"])
        }

        func testShortSingleLineCardStaysOneClick() throws {
            let prompt = try reviewPrompt(reviewCard([text(shortSummary), text(caption, "caption")]))
            XCTAssertFalse(prompt.requiresReview)
            XCTAssertFalse(prompt.hiddenCharacters)
            XCTAssertEqual(prompt.summary, shortSummary)
            XCTAssertEqual(prompt.site, "https://example.com")
        }

        func testApprovalEchoesTheCardDigestInAFrameTheSocketAccepts() throws {
            let cases: [(digest: String?, allow: Bool, echoed: JSONValue?)] = [
                (digest, true, .string(digest)), (digest, false, nil), (nil, true, nil),
                (digest.uppercased(), true, nil), (String(digest.dropLast()), true, nil),
            ]
            for item in cases {
                let (model, sent) = try model()
                let card = reviewCard([text(commandSummary())], digest: item.digest)
                model.canvas = [card]
                let prompt = try XCTUnwrap(model.approvalPrompts.first)
                let button = try XCTUnwrap(
                    card.children.first {
                        $0.raw["payload"]?["decision"] == .string(item.allow ? "approve" : "decline")
                    })
                let offered = try XCTUnwrap(button.raw["payload"]?.objectValue)
                model.decideApproval(prompt, allow: item.allow)
                let frame = try XCTUnwrap(sent().last { $0["action"] == .string("remote_op_decision") })
                let text = String(decoding: try frame.encoded(), as: UTF8.self)
                XCTAssertTrue(WSClient.isApprovalDecision(text), text)
                XCTAssertNil(model.errorBanner)
                let echoed = try XCTUnwrap(frame["payload"]?.objectValue)
                for (key, value) in offered { XCTAssertEqual(echoed[key], value, key) }
                XCTAssertEqual(echoed["display_digest"], item.echoed)
                XCTAssertTrue(
                    Set(echoed.keys).subtracting(offered.keys).isSubset(
                        of: ["submission_id", "request_generation", "display_digest"]),
                    "\(echoed.keys.sorted())")
            }
        }

        func testDetailsKeepEveryTextAndCodeInOrderWithoutTruncation() throws {
            let long = "Write file on Studio Mac (overwrite): " + String(repeating: "/very/long/path", count: 40)
            let script = (0..<200).map { "line \($0): document.body.dataset.k\($0) = 'v'" }.joined(separator: "\n")
            let card = reviewCard([
                text(long), text("Risks: writes_files. Source: model."), code(script), text(caption, "caption"),
                .object([
                    "type": .string("container"),
                    "children": .array([text("Nested note"), code("--- a\n+++ b\n-old\n+new")]),
                ]),
            ])
            let prompt = try reviewPrompt(card)
            XCTAssertTrue(prompt.requiresReview)
            XCTAssertEqual(
                prompt.details,
                [
                    long, "Risks: writes_files. Source: model.", script, caption, "Nested note",
                    "--- a\n+++ b\n-old\n+new",
                ])
            XCTAssertTrue(prompt.summary.hasSuffix("…"))
            XCTAssertFalse(prompt.details.contains { ["Approve", "Decline"].contains($0) })
        }

        private func attachedSheet(_ mount: SurfaceMount) async throws -> NSWindow {
            for _ in 0..<40 where mount.window.attachedSheet == nil { try await mount.settle() }
            return try XCTUnwrap(mount.window.attachedSheet, "The review sheet did not open")
        }

        private func reviewMount(_ card: AstralComponent) async throws -> (
            AppModel, () -> [JSONValue], SurfaceMount, NSWindow
        ) {
            let (model, sent) = try model()
            model.canvas = [card]
            let prompt = try XCTUnwrap(model.approvalPrompts.first)
            let mount = SurfaceMount(
                MacApprovalBanner(prompt: prompt), model: model, size: CGSize(width: 820, height: 640))
            try await mount.settle()
            try mount.click(text: "Review")
            return (model, sent, mount, try await attachedSheet(mount))
        }

        func testReturnAloneNeverApprovesFromTheReviewSheet() async throws {
            let (_, sent, mount, sheet) = try await reviewMount(
                reviewCard([text(commandSummary()), text(caption, "caption")], digest: digest))
            defer { mount.close() }
            XCTAssertFalse(
                sheet.performKeyEquivalent(with: try SurfaceKey.returnKey.event(windowNumber: sheet.windowNumber)))
            sheet.sendEvent(try SurfaceKey.returnKey.event(windowNumber: sheet.windowNumber))
            try await mount.settle()
            XCTAssertTrue(decisions(sent()).isEmpty)
            XCTAssertNotNil(mount.window.attachedSheet)
            XCTAssertTrue(
                sheet.performKeyEquivalent(with: try SurfaceKey.commandReturn.event(windowNumber: sheet.windowNumber)))
            try await mount.settle()
            let approved = try XCTUnwrap(decisions(sent()).last)
            XCTAssertEqual(approved["decision"], .string("approve"))
            XCTAssertEqual(approved["display_digest"], .string(digest))
            XCTAssertEqual(decisions(sent()).count, 1)
            XCTAssertNil(mount.window.attachedSheet)
        }

        func testEscapeDeniesFromTheReviewSheet() async throws {
            let (_, sent, mount, sheet) = try await reviewMount(reviewCard([text(commandSummary())]))
            defer { mount.close() }
            XCTAssertTrue(
                sheet.performKeyEquivalent(with: try SurfaceKey.escape.event(windowNumber: sheet.windowNumber)))
            try await mount.settle()
            XCTAssertEqual(decisions(sent()).map { $0["decision"] }, [.string("decline")])
            XCTAssertNil(mount.window.attachedSheet)
        }

        func testReviewSheetClosesWithoutDecidingWhenTheCardIsWithdrawn() async throws {
            let (model, sent, mount, _) = try await reviewMount(reviewCard([text(commandSummary())]))
            defer { mount.close() }
            model.canvas = []
            for _ in 0..<40 where mount.window.attachedSheet != nil { try await mount.settle() }
            XCTAssertNil(mount.window.attachedSheet)
            XCTAssertTrue(decisions(sent()).isEmpty)
        }

        func testReviewSheetShowsTheTitleWarningAndEveryDetailInEachTheme() async throws {
            let escaped =
                "Contains hidden or direction-changing characters, shown as \\u{…} escapes.\n"
                + "Run a command on Studio Mac\nCommand: echo \\u{202E}txt.exe"
            let card = reviewCard(
                [text(escaped), text(caption, "caption"), code("{\"argv\": [\"echo\"]}")], flags: ["hidden_characters"])
            for preset in SurfaceFixtures.presets {
                let (model, sent) = try model()
                model.canvas = [card]
                let prompt = try XCTUnwrap(model.approvalPrompts.first)
                let mount = SurfaceMount(
                    MacApprovalReviewSheet(prompt: prompt), model: model, size: CGSize(width: 620, height: 520),
                    preset: preset)
                defer { mount.close() }
                try await mount.settle()
                let tree = try mount.accessibility
                XCTAssertTrue(tree.contains { $0.identifier == "approval-review-sheet" }, preset)
                XCTAssertTrue(tree.contains { $0.identifier == "approval-review-warning" }, preset)
                for index in prompt.details.indices {
                    XCTAssertTrue(
                        tree.contains { $0.identifier == "approval-review-detail-\(index)" }, "\(preset) \(index)")
                }
                let buttons = tree.filter { $0.role == kAXButtonRole }
                XCTAssertEqual(buttons.map(\.identifier), ["approval-review-deny", "approval-review-allow"], preset)
                let text = try mount.text()
                for kept in ["Confirm an action on Studio Mac", "Command: echo", "Deny", "Allow"] {
                    XCTAssertTrue(text.contains(kept), "\(preset) missing \(kept): \(text)")
                }
                try mount.snapshot(self, name: "approval_review_sheet-\(preset)")
                try mount.click(text: "Allow", exact: true)
                try await mount.settle()
                XCTAssertEqual(decisions(sent()).last?["decision"], .string("approve"), preset)
            }
        }
    }
#endif

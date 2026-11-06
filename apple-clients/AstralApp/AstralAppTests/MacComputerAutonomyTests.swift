// Covers the Mac autonomy-mode feature: server-confirmed mode selection with pending states, legacy and
// unsupported degradation, the breaker notice, bypass reconciliation, reviewer verdicts on activity rows,
// the recently blocked list with one exact-action retry, and the selector's stable accessibility.

#if os(macOS)
    import AppKit
    import AstralCore
    import SwiftUI
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class MacComputerAutonomyTests: XCTestCase {
        private var suites: [String] = []
        private var sent: [JSONValue] = []

        override func tearDown() {
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
            suites.removeAll()
            super.tearDown()
        }

        private static let owner = "https://sandbox.example|account-a"
        private let hostId = "77777777-7777-4777-8777-777777777777"
        private let sessionId = "88888888-8888-4888-8888-888888888888"
        private let generation = "99999999-9999-4999-8999-999999999999"

        private func makeHost() throws -> MacComputerHost {
            let name = "MacComputerAutonomyTests.\(UUID().uuidString)"
            suites.append(name)
            let host = MacComputerHost(
                available: true, defaults: try XCTUnwrap(UserDefaults(suiteName: name)),
                projectGrants: MacProjectGrants(
                    grants: MacComputerTestWorkspaceGrants().port,
                    persistence: .init(read: { _ in nil }, write: { _, _ in })),
                driver: MacComputerTaskDriver(), monitor: MacComputerTaskMonitor(),
                permissionProvider: { MacComputerPermissions(accessibility: true, screen: true, monitoring: true) },
                desktopProbe: { true }, desktopRearm: { true }, system: MacComputerTestSystem(),
                panelPresenter: { _ in })
            sent.removeAll()
            host.announcer = { _ in }
            addTeardownBlock { host.applicationWillTerminate() }
            host.bind(owner: Self.owner) { [weak self] text in
                if let frame = try? JSONValue.parse(Data(text.utf8)) { self?.sent.append(frame) }
                return true
            }
            host.setEnabled(true)
            return host
        }

        private func flush(_ host: MacComputerHost) async {
            for _ in 0..<20 {
                _ = await host.flushCurrentSends()
                await Task.yield()
            }
        }

        private func modeFrame(
            _ host: MacComputerHost, mode: String, supported: [String], breaker: [String: JSONValue]? = nil
        ) throws -> InboundFrame {
            var computerMode: [String: JSONValue] = [
                "mode": .string(mode), "supported": .array(supported.map(JSONValue.string)),
            ]
            if let breaker { computerMode["breaker"] = .object(breaker) }
            return InboundFrame(
                name: "computer_session",
                payload: .object([
                    "type": .string("computer_session"), "host_id": .string(try XCTUnwrap(host.descriptor).hostId),
                    "session_id": .string(sessionId), "state": .string("active"),
                    "controller_label": .string("Autonomy test"), "computer_mode": .object(computerMode),
                ]))
        }

        private func legacyFrame(_ host: MacComputerHost) throws -> InboundFrame {
            InboundFrame(
                name: "computer_session",
                payload: .object([
                    "type": .string("computer_session"), "host_id": .string(try XCTUnwrap(host.descriptor).hostId),
                    "session_id": .string(sessionId), "state": .string("active"),
                    "controller_label": .string("Autonomy test"),
                ]))
        }

        private func actionNames() -> [String] {
            sent.compactMap { $0["action"]?.stringValue }
        }

        func testAutoReviewRequestSendsTheModeFrameAndWaitsForTheServerConfirmation() async throws {
            let host = try makeHost()
            host.consume(try modeFrame(host, mode: "ask", supported: ["ask", "auto_review", "bypass"]))
            XCTAssertEqual(host.confirmedMode, .ask)
            XCTAssertTrue(host.modeAware)
            XCTAssertTrue(host.supportedModes.contains(.autoReview))
            host.requestAutonomyMode(.autoReview, from: .controls)
            XCTAssertTrue(host.modeWaitingConfirmation)
            XCTAssertEqual(host.pendingModeRequest, .autoReview)
            XCTAssertEqual(host.confirmedMode, .ask, "the selector never guesses the server's confirmation")
            await flush(host)
            XCTAssertTrue(actionNames().contains("chrome_computer_mode_set"), actionNames())
            host.consume(try modeFrame(host, mode: "auto_review", supported: ["ask", "auto_review", "bypass"]))
            XCTAssertEqual(host.confirmedMode, .autoReview)
            XCTAssertFalse(host.modeWaitingConfirmation)
            XCTAssertNil(host.pendingModeRequest)
            host.signedOut()
        }

        func testLegacyServersKeepAskAndBypassOnlyAndRefuseAutoReview() async throws {
            let host = try makeHost()
            host.consume(try legacyFrame(host))
            XCTAssertFalse(host.modeAware)
            XCTAssertEqual(host.supportedModes, [.ask, .bypass])
            host.requestAutonomyMode(.autoReview, from: .controls)
            XCTAssertNil(host.pendingModeRequest)
            XCTAssertEqual(host.lastError, "The server does not offer Auto-review for this Mac.")
            await flush(host)
            XCTAssertFalse(actionNames().contains("chrome_computer_mode_set"), actionNames())
            host.signedOut()
        }

        func testServersWithoutTheAutoReviewModeAreRefused() async throws {
            let host = try makeHost()
            host.consume(try modeFrame(host, mode: "ask", supported: ["ask", "bypass"]))
            XCTAssertTrue(host.modeAware)
            XCTAssertFalse(host.supportedModes.contains(.autoReview))
            host.requestAutonomyMode(.autoReview, from: .controls)
            XCTAssertEqual(host.lastError, "The server does not offer Auto-review for this Mac.")
            host.signedOut()
        }

        func testBreakerNoticeAppearsPinsAskAndClearsWithTheServer() async throws {
            let host = try makeHost()
            host.consume(try modeFrame(host, mode: "auto_review", supported: ["ask", "auto_review", "bypass"]))
            host.consume(
                try modeFrame(
                    host, mode: "ask", supported: ["ask", "auto_review", "bypass"],
                    breaker: ["open": .bool(true), "reason": .string("Five reviewer denials in a row.")]))
            XCTAssertEqual(host.breakerNotice, "Five reviewer denials in a row.")
            XCTAssertEqual(host.confirmedMode, .ask)
            host.requestAutonomyMode(.autoReview, from: .controls)
            XCTAssertEqual(
                host.lastError, "The review circuit breaker is open, so the server keeps this Mac in Ask.")
            XCTAssertNil(host.pendingModeRequest)
            host.consume(try modeFrame(host, mode: "ask", supported: ["ask", "auto_review", "bypass"]))
            XCTAssertNil(host.breakerNotice)
            host.signedOut()
        }

        func testAServerAskModeWithdrawsStandingBypassWithoutAnotherFrame() async throws {
            let host = try makeHost()
            host.requestBypass(true, from: .controls)
            host.confirmBypass()
            XCTAssertTrue(host.bypass)
            host.consume(try modeFrame(host, mode: "ask", supported: ["ask", "auto_review", "bypass"]))
            XCTAssertFalse(host.bypass, "the server's confirmed mode withdraws standing bypass")
            XCTAssertNil(host.breakerNotice)
            host.signedOut()
        }

        func testBypassSelectionKeepsTheOwnerOnlyConfirmationFlow() async throws {
            let host = try makeHost()
            host.consume(try modeFrame(host, mode: "ask", supported: ["ask", "auto_review", "bypass"]))
            host.requestAutonomyMode(.bypass, from: .footer)
            XCTAssertEqual(host.bypassConfirmation, .footer)
            XCTAssertFalse(host.bypass)
            host.confirmBypass()
            XCTAssertTrue(host.bypass)
            await flush(host)
            let bypassFrames = sent.filter { $0["action"] == .string("chrome_computer_bypass_set") }
            XCTAssertEqual(bypassFrames.last?["payload"]?["enabled"], .bool(true))
            host.signedOut()
        }

        func testSwitchingBackToAskSendsTheModeFrameAfterBypassOff() async throws {
            let host = try makeHost()
            host.consume(try modeFrame(host, mode: "auto_review", supported: ["ask", "auto_review", "bypass"]))
            host.requestAutonomyMode(.ask, from: .controls)
            XCTAssertEqual(host.pendingModeRequest, .ask)
            await flush(host)
            XCTAssertEqual(actionNames().filter { $0 == "chrome_computer_mode_set" }.count, 1)
            host.consume(try modeFrame(host, mode: "ask", supported: ["ask", "auto_review", "bypass"]))
            XCTAssertFalse(host.modeWaitingConfirmation)
            host.requestAutonomyMode(.ask, from: .controls)
            await flush(host)
            XCTAssertEqual(
                actionNames().filter { $0 == "chrome_computer_mode_set" }.count, 1, "no duplicate frame")
            host.signedOut()
        }

        func testDisconnectClearsPendingRequestsAndTheBreakerNotice() async throws {
            let host = try makeHost()
            host.consume(
                try modeFrame(
                    host, mode: "ask", supported: ["ask", "auto_review", "bypass"],
                    breaker: ["open": .bool(true)]))
            XCTAssertNotNil(host.breakerNotice)
            host.requestAutonomyMode(.ask, from: .controls)
            host.disconnect()
            XCTAssertNil(host.breakerNotice)
            XCTAssertNil(host.pendingModeRequest)
            host.signedOut()
        }

        func testVerdictFramesDriveActivityRowsAndTheBlockedList() throws {
            let model = try autonomyModel()
            model.continuity.beginConnection(generation)
            model.activeChatId = "audit-chat"
            model.handleFrame(try stepFrame(id: "step-allow", name: "click", status: "completed", decision: "allow"))
            model.handleFrame(try stepFrame(id: "step-deny", name: "run_command", status: "errored", decision: "deny"))
            model.handleFrame(
                try stepFrame(id: "step-raise", name: "type_text", status: "in_progress", decision: "escalate"))
            let rows = model.activity
            XCTAssertEqual(rows.count, 3)
            XCTAssertEqual(rows.first { $0.id == "step-deny" }?.verdict?.decision, .deny)
            XCTAssertEqual(rows.first { $0.id == "step-allow" }?.verdictLabel, "Reviewer allowed")
            XCTAssertEqual(rows.first { $0.id == "step-raise" }?.verdictLabel, "Reviewer raised a card")
            XCTAssertEqual(model.recentlyBlocked.count, 1)
            let entry = try XCTUnwrap(model.recentlyBlocked.first)
            XCTAssertEqual(entry.eventId, "review.auto.2c7a5d3f-9b52-4d3f-ac7a-5d3f9b522c7a")
            XCTAssertEqual(entry.chatId, "audit-chat")
            XCTAssertEqual(entry.tool, "run_command")
            XCTAssertEqual(entry.reason, "Command leaves the granted folders.")
            XCTAssertEqual(entry.retry, .available)

            var emitted: [String] = []
            model.outboundTap = { emitted.append($0) }
            model.retryBlockedAction(entry)
            XCTAssertEqual(model.recentlyBlocked.first?.retry, .sent)
            let frame = try XCTUnwrap(JSONValue.parse(Data(try XCTUnwrap(emitted.last).utf8)))
            XCTAssertEqual(frame["action"], .string("chrome_computer_review_retry"))
            XCTAssertEqual(frame["payload"]?["chat_id"], .string("audit-chat"))
            XCTAssertEqual(
                frame["payload"]?["event_id"], .string("review.auto.2c7a5d3f-9b52-4d3f-ac7a-5d3f9b522c7a"))
            XCTAssertNotNil(frame["payload"]?["client_message_id"]?.stringValue)
            XCTAssertTrue(continuityUUID4(try XCTUnwrap(frame["payload"]?["client_message_id"]?.stringValue)))
        }

        func testARepeatDenyKeepsOneEntryAndItsRetryState() throws {
            let model = try autonomyModel()
            model.activeChatId = "audit-chat"
            model.handleFrame(try stepFrame(id: "step-deny", name: "run_command", status: "errored", decision: "deny"))
            model.retryBlockedAction(try XCTUnwrap(model.recentlyBlocked.first))
            model.handleFrame(try stepFrame(id: "step-deny", name: "run_command", status: "errored", decision: "deny"))
            XCTAssertEqual(model.recentlyBlocked.count, 1)
            XCTAssertEqual(model.recentlyBlocked.first?.retry, .sent, "a newer verdict cannot revive the retry")
        }

        func testStaleBlockedEntriesCannotBeRetriedAndSayWhy() throws {
            let model = try autonomyModel()
            model.activeChatId = "audit-chat"
            let entry = AppModel.BlockedComputerAction(
                eventId: "review.auto.2c7a5d3f-9b52-4d3f-ac7a-5d3f9b522c7a", chatId: "audit-chat",
                tool: "run_command", summary: "run command", reason: "leaves folders", connection: nil,
                receivedAt: Date())
            XCTAssertNil(model.blockedRetryRefusal(entry))

            let otherChat = AppModel.BlockedComputerAction(
                eventId: "review.auto.2c7a5d3f-9b52-4d3f-ac7a-5d3f9b522c7a", chatId: "another-chat",
                tool: "run_command", summary: "run command", reason: "", connection: nil, receivedAt: Date())
            XCTAssertEqual(model.blockedRetryRefusal(otherChat), "Open the chat that raised this block to retry it.")

            let staleConnection = AppModel.BlockedComputerAction(
                eventId: "review.auto.2c7a5d3f-9b52-4d3f-ac7a-5d3f9b522c7a", chatId: "audit-chat",
                tool: "run_command", summary: "run command", reason: "", connection: "older-generation",
                receivedAt: Date())
            XCTAssertEqual(
                model.blockedRetryRefusal(staleConnection),
                "The connection changed since this block, so it can no longer be retried.")

            let expired = AppModel.BlockedComputerAction(
                eventId: "review.auto.2c7a5d3f-9b52-4d3f-ac7a-5d3f9b522c7a", chatId: "audit-chat",
                tool: "run_command", summary: "run command", reason: "", connection: nil,
                receivedAt: Date().addingTimeInterval(-3_601))
            XCTAssertEqual(model.blockedRetryRefusal(expired), "This blocked action expired; ask for it again.")

            let sent = AppModel.BlockedComputerAction(
                eventId: "review.auto.2c7a5d3f-9b52-4d3f-ac7a-5d3f9b522c7a", chatId: "audit-chat",
                tool: "run_command", summary: "run command", reason: "", connection: nil, receivedAt: Date(),
                retry: .sent)
            XCTAssertEqual(
                model.blockedRetryRefusal(sent), "You already approved a retry for this action.")

            var working = entry
            model.retryBlockedAction(working)
            working.retry = .sent
            XCTAssertEqual(
                model.blockedRetryRefusal(working), "You already approved a retry for this action.")
        }

        func testControlsRenderTheSelectorWithStableAccessibleIdentifiers() async throws {
            let host = try makeHost()
            host.consume(
                try modeFrame(
                    host, mode: "ask", supported: ["ask", "auto_review", "bypass"],
                    breaker: ["open": .bool(true), "reason": .string("Five reviewer denials in a row.")]))
            let (model, suite) = try SurfaceFixtures.model()
            suites.append(suite)
            let mount = SurfaceMount(
                MacComputerControls(host: host), model: model, size: CGSize(width: 560, height: 900))
            defer { mount.close() }
            try await mount.settle()
            let tree = try mount.accessibility
            let identifiers = tree.compactMap(\.identifier)
            XCTAssertTrue(identifiers.contains("mac-computer-breaker-notice"))
            for mode in ["ask", "auto_review", "bypass"] {
                let row = try XCTUnwrap(tree.first { $0.identifier == "mac-computer-mode-\(mode)" }, mode)
                XCTAssertEqual(row.role, kAXButtonRole, mode)
                XCTAssertFalse(row.label.isEmpty, mode)
            }
            XCTAssertEqual(tree.first { $0.identifier == "mac-computer-mode-ask" }?.value, "Selected")
            let refused = try XCTUnwrap(tree.first { $0.identifier == "mac-computer-mode-auto_review" })
            XCTAssertTrue(refused.value?.contains("Unavailable") == true)
            let bypassRow = try XCTUnwrap(tree.first { $0.identifier == "mac-computer-mode-bypass" })
            XCTAssertTrue(bypassRow.value?.contains("Unavailable") == true)
            try mount.snapshot(self, name: "computer_controls_autonomy_breaker")
        }

        func testControlsShowPendingAndConfirmedModesWithoutABreaker() async throws {
            let host = try makeHost()
            host.consume(try modeFrame(host, mode: "ask", supported: ["ask", "auto_review", "bypass"]))
            host.requestAutonomyMode(.autoReview, from: .controls)
            let (model, suite) = try SurfaceFixtures.model()
            suites.append(suite)
            let mount = SurfaceMount(
                MacComputerControls(host: host), model: model, size: CGSize(width: 560, height: 900))
            defer { mount.close() }
            try await mount.settle()
            let tree = try mount.accessibility
            let identifiers = tree.compactMap(\.identifier)
            XCTAssertTrue(identifiers.contains("mac-computer-mode-pending"))
            XCTAssertFalse(identifiers.contains("mac-computer-breaker-notice"))
            XCTAssertEqual(tree.first { $0.identifier == "mac-computer-mode-ask" }?.value, "Selected")
            host.consume(try modeFrame(host, mode: "auto_review", supported: ["ask", "auto_review", "bypass"]))
            try await mount.settle()
            let settled = try mount.accessibility
            XCTAssertFalse(settled.compactMap(\.identifier).contains("mac-computer-mode-pending"))
            XCTAssertEqual(settled.first { $0.identifier == "mac-computer-mode-auto_review" }?.value, "Selected")
            XCTAssertEqual(settled.first { $0.identifier == "mac-computer-mode-ask" }?.value, "Not selected")
        }

        func testLegacyControlsShowOnlyAskAndBypassWithTheUnavailableNotice() async throws {
            let host = try makeHost()
            host.consume(try legacyFrame(host))
            let (model, suite) = try SurfaceFixtures.model()
            suites.append(suite)
            let mount = SurfaceMount(
                MacComputerControls(host: host), model: model, size: CGSize(width: 560, height: 900))
            defer { mount.close() }
            try await mount.settle()
            let identifiers = try mount.accessibility.compactMap(\.identifier)
            XCTAssertTrue(identifiers.contains("mac-computer-bypass"))
            XCTAssertFalse(identifiers.contains("mac-computer-mode-ask"))
            XCTAssertFalse(identifiers.contains("mac-computer-mode-auto_review"))
            XCTAssertTrue(identifiers.contains("mac-computer-mode-unavailable"))
        }

        func testTheBlockedListRendersItsExactRetryAndRefusals() async throws {
            let model = try autonomyModel()
            model.activeChatId = "audit-chat"
            model.handleFrame(try stepFrame(id: "step-deny", name: "run_command", status: "errored", decision: "deny"))
            let suite = "MacComputerAutonomyTests.render.\(UUID().uuidString)"
            suites.append(suite)
            let host = MacComputerHost(
                available: true, defaults: try XCTUnwrap(UserDefaults(suiteName: suite)),
                permissionProvider: { MacComputerPermissions(accessibility: false, screen: false, monitoring: false) })
            let mount = SurfaceMount(
                MacComputerControls(host: host), model: model, size: CGSize(width: 560, height: 1200))
            defer { mount.close() }
            try await mount.settle()
            let identifiers = try mount.accessibility.compactMap(\.identifier)
            XCTAssertTrue(identifiers.contains("mac-computer-blocked"))
            XCTAssertTrue(identifiers.contains("mac-computer-blocked-summary"))
            XCTAssertTrue(identifiers.contains("mac-computer-blocked-reason"))
            XCTAssertTrue(identifiers.contains("mac-computer-blocked-retry"))
            try mount.click(text: "Approve and retry")
            try await mount.settle()
            let after = try mount.accessibility.compactMap(\.identifier)
            XCTAssertTrue(after.contains("mac-computer-blocked-sent"))
            XCTAssertFalse(after.contains("mac-computer-blocked-retry"))
            model.handleFrame(
                try stepFrame(
                    id: "step-deny-zoom", name: "zoom", status: "errored", decision: "deny", chat: "other-chat",
                    eventId: "review.auto.3d8b6e4a-ac63-4e4a-bd8b-6e4aac633d8b"))
            try await mount.settle()
            XCTAssertTrue(try mount.accessibility.compactMap(\.identifier).contains("mac-computer-blocked-retry"))
            model.retryBlockedAction(try XCTUnwrap(model.recentlyBlocked.first))
            try await mount.settle()
            let unavailable = try mount.accessibility.compactMap(\.identifier)
            XCTAssertTrue(unavailable.contains("mac-computer-blocked-refusal"))
            XCTAssertFalse(unavailable.contains("mac-computer-blocked-retry"))
        }

        func testTheFooterShowsTheModeSelectorAndBreakerItems() throws {
            let computer = MacStatusFooterModel.Computer(
                enabled: true, sessionState: "active", statusLabel: "Computer task active", bypass: false,
                mode: .autoReview, modeAware: true, pendingMode: false, breaker: true)
            let items = MacStatusFooterModel.items(
                connection: .connected, usage: LLMUsageTally(), approvals: 0, computer: computer)
            XCTAssertEqual(items.map(\.kind), [.connection, .computer, .mode, .breaker])
            XCTAssertEqual(items[1].text, "Computer active")
            XCTAssertEqual(items[2].text, "Mode: Auto-review")
            XCTAssertEqual(items[2].label, "Autonomy mode")
            XCTAssertTrue(items[3].text.contains("Circuit breaker open"))
            XCTAssertTrue(items[3].attention)
            let legacy = MacStatusFooterModel.Computer(
                enabled: true, sessionState: nil, statusLabel: "Computer on")
            let legacyItems = MacStatusFooterModel.items(
                connection: .connected, usage: LLMUsageTally(), approvals: 0, computer: legacy)
            XCTAssertEqual(legacyItems.map(\.kind), [.connection, .computer, .mode])
            XCTAssertEqual(legacyItems[1].text, "Computer on")
            XCTAssertEqual(legacyItems[2].text, "Mode: Ask")
            let pending = MacStatusFooterModel.Computer(
                enabled: true, sessionState: nil, statusLabel: "Computer on", mode: .ask, modeAware: true,
                pendingMode: true)
            let pendingItems = MacStatusFooterModel.items(
                connection: .connected, usage: LLMUsageTally(), approvals: 0, computer: pending)
            XCTAssertTrue(pendingItems[2].value.contains("waiting for the server to confirm"))
            let bypassed = MacStatusFooterModel.Computer(
                enabled: true, sessionState: "active", statusLabel: "Computer task active", bypass: true,
                mode: .bypass, modeAware: true)
            let bypassItems = MacStatusFooterModel.items(
                connection: .connected, usage: LLMUsageTally(), approvals: 0, computer: bypassed)
            XCTAssertEqual(bypassItems.map(\.kind), [.connection, .computer, .mode, .bypass])
            XCTAssertEqual(bypassItems[2].text, "Mode: Bypass")
        }

        func testTheModeNameVocabularyIsClosed() {
            XCTAssertEqual(
                [ComputerAutonomyMode.ask, .autoReview, .bypass].map(MacStatusFooterModel.modeName),
                ["Ask", "Auto-review", "Bypass"])
        }

        private func autonomyModel() throws -> AppModel {
            let name = "MacComputerAutonomyTests.model.\(UUID().uuidString)"
            suites.append(name)
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            let host = MacComputerHost(
                available: true, defaults: defaults,
                driver: MacComputerTaskDriver(), monitor: MacComputerTaskMonitor(),
                permissionProvider: { MacComputerPermissions(accessibility: true, screen: true, monitoring: true) },
                desktopProbe: { true }, desktopRearm: { true }, system: MacComputerTestSystem(),
                panelPresenter: { _ in })
            host.announcer = { _ in }
            addTeardownBlock { host.applicationWillTerminate() }
            let model = AppModel(
                conversationResumeStore: ConversationResumeStore(defaults: defaults),
                tokenStore: InMemoryTokenStore(), defaults: defaults, computerHost: host)
            model.signedIn = true
            model.connected = true
            model.outboundTap = { _ in }
            return model
        }

        private func stepFrame(
            id: String, name: String, status: String, decision: String, chat: String = "audit-chat",
            eventId: String? = nil
        ) throws -> InboundFrame {
            let eventIds = [
                "allow": "review.auto.1b6f4c2e-8a41-4c2e-9b6f-4c2e8a411b6f",
                "deny": "review.auto.2c7a5d3f-9b52-4d3f-ac7a-5d3f9b522c7a",
                "escalate": "review.auto.3d8b6e4a-ac63-4e4a-bd8b-6e4aac633d8b",
            ]
            let reasons = [
                "allow": "Within the granted workspace.",
                "deny": "Command leaves the granted folders.",
                "escalate": "Reviewer could not verify the target window.",
            ]
            return InboundFrame(
                name: "chat_step",
                payload: .object([
                    "type": .string("chat_step"), "chat_id": .string(chat),
                    "step": .object([
                        "id": .string(id), "chat_id": .string(chat), "kind": .string("tool_call"),
                        "name": .string(name), "status": .string(status),
                        "review_verdict": .object([
                            "event_id": .string(try XCTUnwrap(eventId ?? eventIds[decision])),
                            "decision": .string(decision),
                            "reason": .string(try XCTUnwrap(reasons[decision])),
                            "card_raised": .bool(decision == "escalate"),
                        ]),
                    ]),
                ]))
        }
    }
#endif

// Covers the Mac bypass-approvals mode: the local-human gate and confirmation, the host's own bypass frame, the
// frame-driven footer item and session banner, every clearing trigger, the floor that still prompts, the palette
// command, and renders of the toggle row, sheet and footer item in Graphite, Midnight and Daylight.

#if os(macOS)
    import AppKit
    import AstralCore
    import SwiftUI
    import Vision
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class MacComputerBypassTests: XCTestCase {
        private final class Gate {
            var local = true
        }

        private var sent: [JSONValue] = []
        private var announced: [String] = []
        private var suites: [String] = []

        override func tearDown() {
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
            suites.removeAll()
            super.tearDown()
        }

        private func makeHost(gate: Gate = Gate()) throws -> MacComputerHost {
            let suite = "MacComputerBypassTests.\(UUID().uuidString)"
            suites.append(suite)
            let host = MacComputerHost(
                available: true, defaults: try XCTUnwrap(UserDefaults(suiteName: suite)),
                driver: MacComputerTaskDriver(), monitor: MacComputerTaskMonitor(),
                permissionProvider: { MacComputerPermissions(accessibility: true, screen: true, monitoring: true) },
                desktopProbe: { true }, desktopRearm: { gate.local }, system: MacComputerTestSystem(),
                panelPresenter: { _ in })
            host.announcer = { [weak self] in self?.announced.append($0) }
            bind(host)
            host.setEnabled(true)
            addTeardownBlock { host.applicationWillTerminate() }
            return host
        }

        private func bind(_ host: MacComputerHost) {
            host.bind(owner: "bypass-owner") { [weak self] text in
                if let frame = try? JSONValue.parse(Data(text.utf8)) { self?.sent.append(frame) }
                return true
            }
        }

        private func bypassFrames() -> [Bool] {
            sent.filter { $0["action"] == .string("chrome_computer_bypass_set") }
                .compactMap { $0["payload"]?["enabled"]?.boolValue }
        }

        private func flush(_ host: MacComputerHost) async {
            for _ in 0..<20 {
                _ = await host.flushCurrentSends()
                await Task.yield()
            }
        }

        private func session(_ host: MacComputerHost, _ id: String, bypass: Bool?) throws -> InboundFrame {
            var payload: [String: JSONValue] = [
                "type": .string("computer_session"), "host_id": .string(try XCTUnwrap(host.descriptor).hostId),
                "session_id": .string(id), "state": .string("active"), "controller_label": .string("Bypass test"),
            ]
            if let bypass { payload["bypass"] = .bool(bypass) }
            return InboundFrame(name: "computer_session", payload: .object(payload))
        }

        private func enable(_ host: MacComputerHost) async {
            host.requestBypass(true, from: .controls)
            host.confirmBypass()
            await flush(host)
        }

        func testPhysicalBypassWithdrawsOnlyThisHostsCardsWithoutApprovingOrReplaying() async throws {
            for submitted in [false, true] {
                let host = try makeHost()
                let suite = "BypassReview.\(UUID().uuidString)"
                suites.append(suite)
                let model = AppModel(
                    tokenStore: InMemoryTokenStore(), defaults: try XCTUnwrap(UserDefaults(suiteName: suite)),
                    computerHost: host)
                model.signedIn = true
                model.connected = true
                let connection = UUID().uuidString.lowercased()
                XCTAssertTrue(model.beginConversationConnection(connection))
                model.currentApprovalDecisionSendOverride = { _, sentConnection in sentConnection == connection }
                model.activeChatId = "33333333-3333-4333-8333-333333333333"
                model.projects.bind(
                    scope: "owner",
                    client: RestClient(serverBase: URL(string: "https://example.test")!, tokenProvider: { nil }))
                model.projects.negotiate(true)
                let request = String(repeating: "ab", count: 16)
                let other = String(repeating: "cd", count: 16)
                func card(_ id: String, _ hostId: String) -> AstralComponent {
                    AstralComponent(
                        type: "card",
                        raw: .object([
                            "type": .string("card"), "id": .string("au_approval_" + id),
                            "title": .string("Confirm an action on Mac"), "computer_host_id": .string(hostId),
                            "content": .array(
                                ["approve", "decline"].map { decision in
                                    .object([
                                        "type": .string("button"), "label": .string(decision),
                                        "action": .string("remote_op_decision"),
                                        "payload": .object(["proposal_id": .string(id), "decision": .string(decision)]),
                                    ])
                                }),
                        ]))
                }
                model.canvas = [card(request, try XCTUnwrap(host.descriptor).hostId), card(other, "other-mac")]
                let prompt = try XCTUnwrap(model.approvalPrompts.first { $0.requestId == request })
                var decisions = 0
                model.outboundTap = { _ in decisions += 1 }
                if submitted { model.decideApproval(prompt, allow: true) }
                let before = decisions
                await enable(host)
                XCTAssertTrue(host.bypass)
                XCTAssertEqual(model.approvalPrompts.map(\.requestId), [other])
                XCTAssertEqual(AppModel.pendingComputerApprovals(in: model.canvas).map(\.requestId), [other])
                XCTAssertEqual(model.waitingApprovals, 1)
                model.canvas = [card(request, try XCTUnwrap(host.descriptor).hostId), card(other, "other-mac")]
                XCTAssertEqual(AppModel.pendingComputerApprovals(in: model.canvas).map(\.requestId), [other])
                XCTAssertEqual(model.activity.first?.approval, .withdrawing)
                XCTAssertNil(model.activity.first?.approvalLabel)
                if !submitted {
                    XCTAssertEqual(model.activity.first?.state, .completed)
                    XCTAssertEqual(model.activity.first?.action, "Review closed on this Mac")
                    XCTAssertTrue(model.activity.first?.result.contains("check the action outcome") == true)
                }
                model.decideApproval(prompt, allow: true)
                XCTAssertEqual(decisions, before)
                model.handleFrame(
                    InboundFrame(
                        name: "chat_status",
                        payload: .object([
                            "chat_id": .string(model.activeChatId!), "connection_generation": .string(connection),
                            "approval_decision": .object([
                                "request_id": .string(request), "decision": .string(submitted ? "approve" : "withdraw"),
                                "state": .string(submitted ? "accepted" : "cancelled"), "revision": .number(1),
                                "message": .string("Computer approval mode changed."),
                            ]),
                        ])))
                XCTAssertEqual(
                    model.activity.first?.approval, submitted ? .approved : AppModel.ActivityRow.Approval.none)
                XCTAssertNil(model.errorBanner)
                if !submitted { XCTAssertNil(model.activity.first?.approvalLabel) }
                XCTAssertEqual(model.approvalPrompts.map(\.requestId), [other])
                XCTAssertEqual(decisions, before)
            }
        }

        func testLateApprovalFramesCannotPublishWhileBypassingOrAfterEarlyWithdrawal() async throws {
            for route in ["canvas", "append", "upsert", "chat"] {
                for mode in [
                    "bypass", "withdraw", "wrong-connection", "wrong-chat", "replacement", "other-host", "overflow",
                    "overflow-replacement", "disconnect",
                ] {
                    let host = try makeHost()
                    let suite = "LateReview.\(UUID().uuidString)"
                    suites.append(suite)
                    let model = AppModel(
                        tokenStore: InMemoryTokenStore(), defaults: try XCTUnwrap(UserDefaults(suiteName: suite)),
                        computerHost: host)
                    model.announcer = { [weak self] in self?.announced.append($0) }
                    let connection = UUID().uuidString.lowercased()
                    let chat = UUID().uuidString.lowercased()
                    let generation = UUID().uuidString.lowercased()
                    XCTAssertTrue(model.beginConversationConnection(connection))
                    XCTAssertTrue(
                        model.openConversationRequest(chatId: chat, requestGeneration: generation, purpose: .commit))
                    model.projects.bind(
                        scope: "owner",
                        client: RestClient(serverBase: URL(string: "https://example.test")!, tokenProvider: { nil }))
                    model.projects.negotiate(true)
                    var id = String(repeating: "ab", count: 16)
                    if mode != "bypass" && mode != "other-host" {
                        model.handleFrame(
                            InboundFrame(
                                name: "chat_status",
                                payload: .object([
                                    "chat_id": .string(mode == "wrong-chat" ? UUID().uuidString.lowercased() : chat),
                                    "connection_generation": .string(
                                        mode == "wrong-connection" ? UUID().uuidString.lowercased() : connection),
                                    "approval_decision": .object([
                                        "request_id": .string(id), "decision": .string("withdraw"),
                                        "state": .string("cancelled"),
                                        "revision": .number(1), "message": .string("Computer approval mode changed."),
                                    ]),
                                ])))
                    }
                    var currentConnection = connection
                    if mode == "disconnect" {
                        await model.handle(.disconnected(reason: "network lost"))
                        bind(host)
                        host.setEnabled(true)
                    }
                    if mode.hasPrefix("overflow") {
                        for index in 0..<512 {
                            model.handleFrame(
                                InboundFrame(
                                    name: "chat_status",
                                    payload: .object([
                                        "chat_id": .string(chat), "connection_generation": .string(connection),
                                        "approval_decision": .object([
                                            "request_id": .string("retired-\(index)"), "decision": .string("withdraw"),
                                            "state": .string("cancelled"), "revision": .number(1),
                                            "message": .string("Closed"),
                                        ]),
                                    ])))
                        }
                    }
                    if mode == "replacement" || mode == "overflow-replacement" {
                        currentConnection = UUID().uuidString.lowercased()
                        XCTAssertTrue(model.beginConversationConnection(currentConnection))
                        XCTAssertTrue(
                            model.openConversationRequest(chatId: chat, requestGeneration: generation, purpose: .commit)
                        )
                    }
                    if mode.hasPrefix("overflow") { id = String(repeating: "ef", count: 16) }
                    host.consume(try session(host, UUID().uuidString.lowercased(), bypass: false))
                    XCTAssertNotNil(host.session)
                    if mode == "bypass" || mode == "other-host" { await enable(host) }
                    let before = announced.count
                    let card: JSONValue = .object([
                        "type": .string("card"), "id": .string("au_approval_" + id),
                        "computer_host_id": .string(
                            mode == "other-host" ? "other-mac" : try XCTUnwrap(host.descriptor).hostId),
                        "title": .string("Confirm an action on Mac"),
                        "content": .array(
                            [.object(["type": .string("text"), "content": .string("Late computer review")])]
                                + ["approve", "decline"].map {
                                    .object([
                                        "type": .string("button"), "label": .string($0),
                                        "action": .string("remote_op_decision"),
                                        "payload": .object(["proposal_id": .string(id), "decision": .string($0)]),
                                    ])
                                }),
                    ])
                    let ordinary: JSONValue = .object([
                        "type": .string("card"), "id": .string("ordinary"), "title": .string("Review document"),
                        "content": .array([
                            .object([
                                "type": .string("button"), "label": .string("Open"), "action": .string("open_document"),
                            ])
                        ]),
                    ])
                    var payload: [String: JSONValue] = [
                        "chat_id": .string(chat), "connection_generation": .string(currentConnection),
                        "request_generation": .string(generation), "base_render_revision": .number(0),
                        "frame_sequence": .number(1),
                        "target": .string(route == "chat" ? "chat" : "canvas"),
                    ]
                    if route == "upsert" {
                        payload["ops"] = .array([
                            .object([
                                "op": .string("upsert"), "component_id": .string("au_approval_" + id),
                                "component": card,
                            ]),
                            .object([
                                "op": .string("upsert"), "component_id": .string("ordinary"), "component": ordinary,
                            ]),
                        ])
                    } else {
                        payload["components"] = .array([card, ordinary])
                    }
                    model.handleFrame(
                        InboundFrame(
                            name: route == "upsert" ? "ui_upsert" : route == "append" ? "ui_append" : "ui_render",
                            payload: .object(payload)))
                    let suppressed =
                        mode == "bypass" || mode == "withdraw" || mode == "overflow" || mode == "disconnect"
                    let raw = model.canvas + (model.transientCanvas ?? []) + model.visibleTurns.flatMap(\.components)
                    if route == "chat" {
                        XCTAssertEqual(
                            model.visibleTurns.contains { $0.text.contains("Late computer review") }, !suppressed)
                    } else {
                        XCTAssertTrue(raw.contains { $0.componentId == "ordinary" })
                    }
                    let noCard = suppressed || route == "chat"
                    XCTAssertEqual(AppModel.pendingComputerApprovals(in: raw).isEmpty, noCard, "\(route)/\(mode)")
                    XCTAssertEqual(model.approvalPrompts.isEmpty, noCard, "\(route)/\(mode)")
                    XCTAssertEqual(model.waitingApprovals, noCard ? 0 : 1)
                    XCTAssertEqual(host.awaitingApproval, !noCard, "\(route)/\(mode)")
                    XCTAssertEqual(announced.dropFirst(before).contains { $0.hasPrefix("Approval waiting") }, !noCard)
                    if mode == "bypass" {
                        host.requestBypass(false, from: .controls)
                        payload["frame_sequence"] = .number(2)
                        model.handleFrame(
                            InboundFrame(
                                name: route == "upsert" ? "ui_upsert" : route == "append" ? "ui_append" : "ui_render",
                                payload: .object(payload)))
                        XCTAssertTrue(model.approvalPrompts.isEmpty)
                        XCTAssertTrue(
                            AppModel.pendingComputerApprovals(
                                in: model.canvas + (model.transientCanvas ?? [])
                                    + model.visibleTurns.flatMap(\.components)
                            ).isEmpty)
                    }
                }
            }
        }

        func testEnablingFromTheBackgroundOrWithoutComputerAccessIsRefused() async throws {
            let gate = Gate()
            let host = try makeHost(gate: gate)
            gate.local = false
            host.requestBypass(true, from: .controls)
            XCTAssertNil(host.bypassConfirmation)
            XCTAssertFalse(host.bypass)
            XCTAssertEqual(host.lastError, "Turn on bypass yourself from Astral's active, unlocked local desktop.")
            gate.local = true
            host.requestBypass(true, from: .controls)
            XCTAssertEqual(host.bypassConfirmation, .controls)
            gate.local = false
            host.confirmBypass()
            XCTAssertNil(host.bypassConfirmation)
            XCTAssertFalse(host.bypass)
            gate.local = true
            host.setEnabled(false)
            host.requestBypass(true, from: .settings)
            XCTAssertNil(host.bypassConfirmation)
            XCTAssertEqual(host.lastError, "Allow computer tasks on this Mac before bypassing approvals.")
            await flush(host)
            XCTAssertTrue(bypassFrames().isEmpty)
            XCTAssertTrue(announced.isEmpty)
        }

        func testConfirmationEnablesThroughTheHostChannelAndDisablingNeedsNoConfirmation() async throws {
            let host = try makeHost()
            host.requestBypass(true, from: .palette)
            XCTAssertEqual(host.bypassConfirmation, .palette)
            host.cancelBypass()
            XCTAssertNil(host.bypassConfirmation)
            XCTAssertFalse(host.bypass)
            await enable(host)
            XCTAssertTrue(host.bypass)
            XCTAssertEqual(bypassFrames(), [true])
            let frame = try XCTUnwrap(sent.last { $0["action"] == .string("chrome_computer_bypass_set") })
            XCTAssertEqual(frame["payload"]?["host_id"], .string(try XCTUnwrap(host.descriptor).hostId))
            XCTAssertEqual(announced, ["Approvals bypassed on this Mac"])
            host.requestBypass(false, from: .controls)
            await flush(host)
            XCTAssertNil(host.bypassConfirmation)
            XCTAssertFalse(host.bypass)
            XCTAssertEqual(bypassFrames(), [true, false])
            XCTAssertEqual(announced.last, "Approval bypass is off")
        }

        func testSessionFramesDriveTheFooterItemAndTheSessionBanner() async throws {
            let host = try makeHost()
            await enable(host)
            let id = UUID().uuidString.lowercased()
            host.consume(try session(host, id, bypass: true))
            XCTAssertTrue(host.bypass)
            let on = MacStatusFooterModel.items(
                connection: .connected, usage: LLMUsageTally(), approvals: 0,
                computer: .init(
                    enabled: host.enabled, sessionState: host.session?.state, statusLabel: host.statusLabel,
                    bypass: host.bypass))
            let item = try XCTUnwrap(on.first { $0.kind == .bypass })
            XCTAssertEqual(item.text, "Approvals bypassed")
            XCTAssertEqual(item.label, "Approval bypass")
            XCTAssertTrue(item.attention)
            let (model, suite) = try SurfaceFixtures.model()
            suites.append(suite)
            let banner = SurfaceMount(
                MacComputerSessionControls(host: host), model: model, size: .init(width: 380, height: 110))
            defer { banner.close() }
            try await banner.settle()
            XCTAssertTrue(try banner.text().contains("Bypass on"))
            host.consume(try session(host, id, bypass: false))
            XCTAssertFalse(host.bypass)
            XCTAssertEqual(announced.last, "Approval bypass is off")
            XCTAssertNil(
                MacStatusFooterModel.items(
                    connection: .connected, usage: LLMUsageTally(), approvals: 0,
                    computer: .init(enabled: true, sessionState: "active", statusLabel: "", bypass: host.bypass)
                ).first { $0.kind == .bypass })
            try await banner.settle()
            XCTAssertFalse(try banner.text().contains("Bypass on"))
            host.consume(try session(host, id, bypass: true))
            await flush(host)
            XCTAssertFalse(host.bypass)
            XCTAssertEqual(bypassFrames(), [true, false])
        }

        func testAccessOffDisconnectAndReRegistrationClearBypass() async throws {
            let host = try makeHost()
            await enable(host)
            host.setEnabled(false)
            await flush(host)
            XCTAssertFalse(host.bypass)
            XCTAssertEqual(bypassFrames(), [true, false])
            host.setEnabled(true)
            await enable(host)
            XCTAssertTrue(host.bypass)
            host.disconnect()
            XCTAssertFalse(host.bypass)
            XCTAssertEqual(bypassFrames(), [true, false, true])
            bind(host)
            host.setEnabled(true)
            XCTAssertFalse(host.bypass)
            host.consume(try session(host, UUID().uuidString.lowercased(), bypass: nil))
            await flush(host)
            XCTAssertEqual(bypassFrames(), [true, false, true, false])
            host.consume(try session(host, UUID().uuidString.lowercased(), bypass: nil))
            await flush(host)
            XCTAssertEqual(bypassFrames(), [true, false, true, false])
        }

        func testSignOutAndQuitTurnBypassOffAndSendEnabledFalse() async throws {
            for quit in [false, true] {
                sent = []
                let host = try makeHost()
                let (model, suite) = try modelWith(host)
                suites.append(suite)
                var outbound: [JSONValue] = []
                model.outboundTap = { text in
                    if let frame = try? JSONValue.parse(Data(text.utf8)) { outbound.append(frame) }
                }
                await enable(host)
                let hostId = try XCTUnwrap(host.descriptor).hostId
                if quit {
                    model.computerApplicationWillTerminate()
                } else {
                    await model.signOut(revokeRemote: false)
                }
                XCTAssertFalse(host.bypass, "quit \(quit)")
                let farewell = try XCTUnwrap(
                    outbound.last { $0["action"] == .string("chrome_computer_bypass_set") }, "quit \(quit)")
                XCTAssertEqual(farewell["payload"]?["enabled"], .bool(false))
                XCTAssertEqual(farewell["payload"]?["host_id"], .string(hostId))
            }
        }

        private func modelWith(_ host: MacComputerHost) throws -> (AppModel, String) {
            let suite = "MacComputerBypassModel.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let model = AppModel(
                conversationResumeStore: ConversationResumeStore(defaults: defaults), tokenStore: InMemoryTokenStore(),
                defaults: defaults, computerHost: host, processActivity: RecordingActivityScheduler())
            model.signedIn = true
            model.connected = true
            return (model, suite)
        }

        func testServerAutoApprovedCardsDoNotPromptButFloorCardsStillDo() throws {
            let host = try makeHost()
            let (model, suite) = try modelWith(host)
            suites.append(suite)
            model.outboundTap = { _ in }
            func card(_ id: String, source: String?) -> AstralComponent {
                var raw: [String: JSONValue] = [
                    "type": .string("card"), "id": .string("au_approval_\(id)"),
                    "title": .string("Confirm an action on Studio Mac"),
                    "content": .array(
                        [.object(["type": .string("text"), "content": .string("Run sudo ls on Studio Mac")])]
                            + ["approve", "decline"].map { decision in
                                .object([
                                    "type": .string("button"), "label": .string(decision),
                                    "action": .string("remote_op_decision"),
                                    "payload": .object(["proposal_id": .string(id), "decision": .string(decision)]),
                                ])
                            }),
                ]
                if let source { raw["approval_source"] = .string(source) }
                return AstralComponent(type: "card", raw: .object(raw))
            }
            let floor = String(repeating: "f", count: 32)
            let automatic = String(repeating: "a", count: 32)
            host.requestBypass(true, from: .controls)
            host.confirmBypass()
            XCTAssertTrue(host.bypass)
            model.canvas = [card(automatic, source: "bypass"), card(floor, source: nil)]
            XCTAssertEqual(model.approvalPrompts.map(\.requestId), [floor])
            XCTAssertEqual(model.waitingApprovals, 1)
            let (unbypassed, otherSuite) = try modelWith(try makeHost())
            suites.append(otherSuite)
            unbypassed.outboundTap = { _ in }
            unbypassed.canvas = [
                card(automatic, source: "bypass"), card("project", source: "project_grant"), card(floor, source: nil),
            ]
            XCTAssertEqual(unbypassed.approvalPrompts.map(\.requestId), [floor])
        }

        func testBrowserControlsSkipTheLocalReviewOnlyForBypassRequestsAndNeverForSecrets() async throws {
            let harness = try MacBrowserHarness()
            await harness.start()
            addTeardownBlock { harness.close() }
            var bypassOn = true
            harness.driver.bypassActive = { bypassOn }
            _ = try await harness.open("/form")
            let snap = try await harness.snapshot()
            let pay = try harness.ref(snap.lines, containing: "button \"Pay now\"")
            let password = try harness.ref(snap.lines, containing: "Password")
            let click: [String: JSONValue] = ["ref": .string(pay), "snapshot_id": .string(snap.id)]
            await harness.expectCode("browser_click", click, "confirmation_required")
            do {
                _ = try await harness.driver.execute(
                    "browser_click", args: click, session: MacBrowserHarness.session, remaining: 20,
                    approvalSource: "bypass", authorize: {})
            } catch { XCTFail("bypass click refused: \(error)") }
            try await harness.expectPage("document.title", "paid")
            let fill: [String: JSONValue] = [
                "snapshot_id": .string(snap.id),
                "fields": .array([.object(["ref": .string(password), "value": .string("x")])]),
            ]
            do {
                _ = try await harness.driver.execute(
                    "browser_fill", args: fill, session: MacBrowserHarness.session, remaining: 20,
                    approvalSource: "bypass", authorize: {})
                XCTFail("a password field was filled under bypass")
            } catch let error as ComputerHostError {
                XCTAssertEqual(error.code, "secret_field")
            }
            bypassOn = false
            await harness.expectCode("browser_click", click, "confirmation_required")
            do {
                _ = try await harness.driver.execute(
                    "browser_click", args: click, session: MacBrowserHarness.session, remaining: 20,
                    approvalSource: "bypass", authorize: {})
                XCTFail("a bypass request ran with local bypass off")
            } catch let error as ComputerHostError {
                XCTAssertEqual(error.code, "confirmation_required")
            }
        }

        func testConfirmationExposesItsTitleMessageAndButtonsInReadingOrder() async throws {
            let host = try makeHost()
            let (model, suite) = try SurfaceFixtures.model()
            suites.append(suite)
            host.requestBypass(true, from: .controls)
            let sheet = SurfaceMount(
                MacBypassConfirmation(host: host), model: model, size: CGSize(width: 440, height: 240))
            defer { sheet.close() }
            try await sheet.settle()
            let tree = try sheet.accessibility
            XCTAssertNotNil(tree.first { $0.identifier == "mac-bypass-title" })
            XCTAssertNotNil(tree.first { $0.identifier == "mac-bypass-message" })
            let buttons = tree.filter { $0.role == kAXButtonRole }.compactMap(\.identifier)
            XCTAssertEqual(buttons, ["mac-bypass-close", "mac-bypass-cancel", "mac-bypass-confirm"])
        }

        func testPaletteOffersBypassOnlyWithComputerAccessOn() {
            var context = MacPaletteContext(computerAvailable: false)
            XCTAssertNil(
                MacCommandPaletteModel.rows(context: context, menu: nil, query: "").first { $0.id == "app/bypass" })
            context.computerAvailable = true
            let off = MacCommandPaletteModel.rows(context: context, menu: nil, query: "bypass")
            XCTAssertEqual(off.map(\.title), ["Bypass Approvals On"])
            XCTAssertFalse(MacCommandPaletteModel.runnable(.toggleBypass, context: context, menu: nil))
            context.computerEnabled = true
            XCTAssertTrue(MacCommandPaletteModel.runnable(.toggleBypass, context: context, menu: nil))
            context.bypass = true
            XCTAssertEqual(
                MacCommandPaletteModel.rows(context: context, menu: nil, query: "bypass").map(\.title),
                ["Bypass Approvals Off"])
        }

        func testToggleRowSheetAndFooterItemRenderInEachTheme() async throws {
            for preset in SurfaceFixtures.presets {
                sent = []
                let host = try makeHost()
                let (model, suite) = try SurfaceFixtures.model()
                suites.append(suite)
                let controls = SurfaceMount(
                    MacComputerControls(host: host), model: model, size: CGSize(width: 560, height: 640), preset: preset
                )
                try await controls.settle()
                XCTAssertTrue(try controls.text().contains("Bypass approvals"), preset)
                try controls.snapshot(self, name: "computer_controls_bypass_row-\(preset)")
                controls.close()
                host.requestBypass(true, from: .controls)
                let sheet = SurfaceMount(
                    MacBypassConfirmation(host: host), model: model, size: CGSize(width: 440, height: 240),
                    preset: preset)
                try await sheet.settle()
                let titleRequest = VNRecognizeTextRequest()
                titleRequest.recognitionLevel = .accurate
                titleRequest.usesLanguageCorrection = false
                titleRequest.regionOfInterest = CGRect(x: 0, y: 0.75, width: 1, height: 0.25)
                try VNImageRequestHandler(cgImage: XCTUnwrap(sheet.bitmap().cgImage)).perform([titleRequest])
                let title = (titleRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(
                    separator: "\n")
                XCTAssertEqual(title, "Bypass approvals on this Mac?", preset)
                let text = try sheet.text()
                for kept in ["Cancel", "Bypass approvals", "without asking"] {
                    XCTAssertTrue(text.contains(kept), "\(preset) missing \(kept): \(text)")
                }
                XCTAssertFalse(text.contains("Done"), preset)
                try sheet.snapshot(self, name: "bypass_confirmation-\(preset)")
                try sheet.click(text: "Cancel")
                try await sheet.settle()
                XCTAssertNil(host.bypassConfirmation, preset)
                XCTAssertFalse(host.bypass, preset)
                host.requestBypass(true, from: .controls)
                try await sheet.settle()
                try sheet.click(text: "Bypass approvals", exact: true)
                try await sheet.settle()
                XCTAssertTrue(host.bypass, preset)
                sheet.close()
                let footerModel = try modelWith(host)
                suites.append(footerModel.1)
                let footer = SurfaceMount(
                    MacStatusFooter {}, model: footerModel.0, size: CGSize(width: 900, height: 26), preset: preset)
                try await footer.settle()
                XCTAssertTrue(try footer.text().contains("Approvals bypassed"), preset)
                try footer.snapshot(self, name: "status_footer_bypass-\(preset)")
                footer.close()
                let settings = SurfaceMount(
                    MacSettingsThisMac(host: host), model: model, size: CGSize(width: 460, height: 220), preset: preset)
                try await settings.settle()
                XCTAssertTrue(try settings.text().contains("Bypass approvals"), preset)
                try settings.snapshot(self, name: "settings_this_mac_bypass-\(preset)")
                settings.close()
            }
        }
    }
#endif

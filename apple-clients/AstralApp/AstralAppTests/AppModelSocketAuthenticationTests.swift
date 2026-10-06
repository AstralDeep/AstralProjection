// Exercises AppModel credential refresh and registered WebSocket ownership through a local HTTP and socket peer.
// Controlled clocks and held identity-provider responses verify expiry, rotation, cancellation, and recovery without real credentials.

import AstralCore
import CryptoKit
import Network
import XCTest

@testable import AstralDeep

@MainActor
final class AppModelSocketAuthenticationTests: XCTestCase {
    private let menu = InboundFrame.parse(
        #"{"type":"chrome_menu","model":{"version":2,"topbar":[{"key":"work","kind":"action","label":"Work","action":{"surface":"work","params":{"mode":"list"}}},{"key":"guidance","kind":"action","label":"Private notes","action":{"surface":"guidance","params":{"mode":"list"}}}],"menu":[]}}"#
    )!

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }

    private func withModel(
        jwtLifetime: TimeInterval = 3600,
        _ body: (AppModel, SocketAuthenticationPeer, InMemoryTokenStore, CredentialTestClock) async throws -> Void
    ) async throws {
        let clock = CredentialTestClock()
        let peer = try SocketAuthenticationPeer(clock: clock, jwtLifetime: jwtLifetime)
        peer.start()
        defer { peer.stop() }
        await fulfillment(of: [peer.ready], timeout: 10)
        let port = try XCTUnwrap(peer.listener.port).rawValue
        let suite = "AppModelSocketAuthenticationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("http://127.0.0.1:\(port)", forKey: "serverBase")
        defaults.set("http://127.0.0.1:\(port)", forKey: "authority")
        let store = InMemoryTokenStore()
        store.save(
            StoredTokens(
                from: TokenSet(accessToken: peer.originalToken, refreshToken: "fixture-refresh", expiresIn: 3600)))
        let model = AppModel(
            conversationResumeStore: ConversationResumeStore(defaults: defaults),
            tokenStore: store, defaults: defaults, credentialClock: { clock.now })
        let registered = peer.expectRegistration()
        await model.bootstrap()
        await fulfillment(of: [registered], timeout: 10)
        try await waitUntil { model.connected }
        model.handleFrame(menu)
        do { try await body(model, peer, store, clock) } catch {
            await model.signOut(revokeRemote: false)
            throw error
        }
        await model.signOut(revokeRemote: false)
    }

    func testRESTTokenRotationRenewsTheRegisteredSocket() async throws {
        try await withModel { model, peer, store, clock in
            clock.advance(7200)
            let registered = peer.expectRegistration()
            _ = try await model.rest.chats()
            XCTAssertNotEqual(store.load()?.accessToken, peer.originalToken)
            await fulfillment(of: [registered], timeout: 10)
            XCTAssertEqual(peer.registrations.count, 2)
            XCTAssertEqual(peer.registrations.last?.token, store.load()?.accessToken)
            XCTAssertNotEqual(peer.registrations.first?.generation, peer.registrations.last?.generation)
            XCTAssertEqual(peer.refreshCount, 1)
        }
    }

    func testExpiredPrivateReadsRenewBeforeSendingFreshLists() async throws {
        for surface in ["guidance", "work"] {
            try await withModel { model, peer, _, clock in
                clock.advance(7200)
                let registered = peer.expectRegistration()
                model.openSurface(surface, params: .object(["mode": .string("list")]))
                await fulfillment(of: [registered], timeout: 10)
                try await waitUntil {
                    peer.events.contains { $0.frame.payload["payload"]?["surface"]?.stringValue == surface }
                }
                let reads = peer.events.filter { $0.frame.payload["payload"]?["surface"]?.stringValue == surface }
                XCTAssertEqual(reads.count, 1)
                XCTAssertEqual(reads.first?.socket, peer.registrations.last?.socket)
                XCTAssertEqual(reads.first?.frame.payload["payload"]?["params"], .object(["mode": .string("list")]))
                XCTAssertEqual(peer.refreshCount, 1)
                XCTAssertEqual(peer.registrations.count, 2)
            }
        }
    }

    func testRefreshCompletionCannotRestoreSignedOutCredentialsOrAuthorizeREST() async throws {
        try await withModel { model, peer, store, clock in
            clock.advance(7200)
            peer.holdRefresh()
            let requested = peer.expectRefresh()
            let request = Task { try? await model.rest.chats() }
            await fulfillment(of: [requested], timeout: 10)
            await model.signOut(revokeRemote: false)
            peer.releaseRefresh()
            _ = await request.value
            XCTAssertFalse(model.signedIn)
            XCTAssertNil(store.load())
            XCTAssertTrue(peer.restAuthorization.allSatisfy(\.isEmpty))
            XCTAssertEqual(peer.registrations.count, 1)
        }
    }

    func testRefreshCompletionCannotInstallCredentialsForAChangedOwner() async throws {
        try await withModel { model, peer, store, clock in
            clock.advance(7200)
            peer.holdRefresh()
            let requested = peer.expectRefresh()
            let request = Task { try? await model.rest.chats() }
            await fulfillment(of: [requested], timeout: 10)
            let replacement = try XCTUnwrap(
                ConversationAccount(issuer: "https://issuer.example.test", subject: "other"))
            model.bindConversationAccount(replacement)
            peer.releaseRefresh()
            _ = await request.value
            XCTAssertEqual(model.downloadOwner.account, replacement)
            XCTAssertEqual(store.load()?.accessToken, peer.originalToken)
            XCTAssertTrue(peer.restAuthorization.allSatisfy(\.isEmpty))
            XCTAssertEqual(peer.registrations.count, 1)
        }
    }

    func testChangedOwnerCannotReuseCachedRESTCredentials() async throws {
        try await withModel { model, peer, _, _ in
            model.bindConversationAccount(
                try XCTUnwrap(ConversationAccount(issuer: "https://issuer.example.test", subject: "other")))
            _ = try await model.rest.chats()
            XCTAssertTrue(peer.restAuthorization.allSatisfy(\.isEmpty))
            XCTAssertEqual(peer.refreshCount, 0)
        }
    }

    func testCurrentCredentialsLeaveReadsOnTheirRegisteredConnection() async throws {
        try await withModel { model, peer, _, _ in
            for surface in ["guidance", "work", "authoring"] {
                model.openSurface(
                    surface, params: surface == "authoring" ? .object([:]) : .object(["mode": .string("list")]))
                try await waitUntil {
                    peer.events.contains { $0.frame.payload["payload"]?["surface"]?.stringValue == surface }
                }
            }
            XCTAssertEqual(peer.refreshCount, 0)
            XCTAssertEqual(peer.registrations.count, 1)
            XCTAssertTrue(peer.events.allSatisfy { $0.socket == peer.registrations[0].socket })
        }
    }

    func testExpiredOrdinaryAuthoringReadReopensWithANewGeneration() async throws {
        try await withModel { model, peer, _, clock in
            clock.advance(7200)
            let registered = peer.expectRegistration()
            model.openSurface("authoring")
            await fulfillment(of: [registered], timeout: 10)
            try await waitUntil {
                peer.events.contains { $0.frame.payload["payload"]?["surface"]?.stringValue == "authoring" }
            }
            let reads = peer.events.filter { $0.frame.payload["payload"]?["surface"]?.stringValue == "authoring" }
            XCTAssertEqual(reads.count, 1)
            XCTAssertEqual(reads.first?.socket, peer.registrations.last?.socket)
            XCTAssertEqual(peer.refreshCount, 1)
        }
    }

    func testJWTEarlierExpiryRefreshesDespiteLaterStoredExpiry() async throws {
        try await withModel(jwtLifetime: 120) { model, peer, _, clock in
            clock.advance(180)
            let registered = peer.expectRegistration()
            model.openSurface("guidance", params: .object(["mode": .string("list")]))
            await fulfillment(of: [registered], timeout: 10)
            XCTAssertEqual(peer.refreshCount, 1)
            XCTAssertEqual(peer.registrations.count, 2)
        }
    }

    func testRepeatedExpirySignalsShareOneRefreshWithoutReplayingAQuery() async throws {
        try await withModel { model, peer, _, _ in
            model.composerDraft = "Unsent draft remains here"
            peer.holdRefresh()
            let requested = peer.expectRefresh()
            let registered = peer.expectRegistration()
            let refused = try XCTUnwrap(InboundFrame.parse(#"{"type":"auth_required","reason":"expired"}"#))
            model.handleFrame(refused)
            model.handleFrame(refused)
            await fulfillment(of: [requested], timeout: 10)
            peer.releaseRefresh()
            await fulfillment(of: [registered], timeout: 10)
            try await waitUntil { model.connected }
            _ = try await model.rest.chats()
            XCTAssertEqual(peer.refreshCount, 1)
            XCTAssertEqual(peer.registrations.count, 2)
            XCTAssertTrue(peer.events.isEmpty)
            XCTAssertEqual(model.composerDraft, "Unsent draft remains here")
        }
    }

    func testValidShortLivedRefreshRegistersOnceWithoutMarginChurn() async throws {
        try await withModel { model, peer, store, _ in
            peer.configureRefresh(status: 200, lifetime: 30)
            let registered = peer.expectRegistration()
            model.handleFrame(try XCTUnwrap(InboundFrame.parse(#"{"type":"auth_required","reason":"expired"}"#)))
            await fulfillment(of: [registered], timeout: 10)
            try await waitUntil { model.connected }
            for _ in 0..<3 { _ = try await model.rest.chats() }
            XCTAssertTrue(model.signedIn)
            XCTAssertEqual(peer.refreshCount, 1)
            XCTAssertEqual(peer.registrations.count, 2)
            XCTAssertEqual(peer.registrations.last?.token, store.load()?.accessToken)
        }
    }

    func testQueuedExpiryRecoveryCannotReplaceANewerSocket() async throws {
        try await withModel { model, peer, store, _ in
            let registered = peer.expectRegistration()
            model.handleFrame(try XCTUnwrap(InboundFrame.parse(#"{"type":"auth_required","reason":"expired"}"#)))
            model.connected = false
            model.retryConnection()
            await fulfillment(of: [registered], timeout: 10)
            try await waitUntil { model.connected }
            _ = try await model.rest.chats()
            XCTAssertTrue(model.signedIn)
            XCTAssertEqual(peer.refreshCount, 0)
            XCTAssertEqual(peer.registrations.count, 2)
            XCTAssertEqual(store.load()?.accessToken, peer.originalToken)
        }
    }

    func testRejectedRefreshForReplacementSocketEndsTheExpiredSession() async throws {
        try await withModel { model, peer, store, clock in
            clock.advance(7200)
            peer.configureRefresh(status: 401)
            peer.holdRefresh()
            let requested = peer.expectRefresh()
            model.handleFrame(try XCTUnwrap(InboundFrame.parse(#"{"type":"auth_required","reason":"expired"}"#)))
            await fulfillment(of: [requested], timeout: 10)
            model.connected = false
            model.retryConnection()
            peer.releaseRefresh()
            try await waitUntil { !model.signedIn }
            XCTAssertNil(store.load())
            XCTAssertEqual(peer.registrations.count, 1)
            XCTAssertTrue(peer.events.isEmpty)
        }
    }

    func testUnsentProfileWriteKeepsCurrentFormAndNewerComposerDraft() async throws {
        try await withModel { model, peer, _, clock in
            model.openSurface("profile")
            try await waitUntil { peer.events.count == 1 }
            let generation = try XCTUnwrap(peer.events[0].frame.payload["request_generation"]?.stringValue)
            model.handleFrame(
                try XCTUnwrap(
                    InboundFrame.parse(
                        """
                        {"type":"chrome_surface","region":"modal","mode":"replace","surface_key":"profile","title":"Profile",
                        "request_generation":"\(generation)","components":[{"type":"param_picker","fields":[{"name":"name","kind":"text","default":"Current name"}],
                        "submit_action":"chrome_profile_save","submit_label":"Save"}]}
                        """)))
            let form = try XCTUnwrap(model.pendingSurface)
            model.composerDraft = "A newer composer draft"
            clock.advance(7200)
            let registered = peer.expectRegistration()
            XCTAssertTrue(
                model.submitParamPicker(
                    action: "chrome_profile_save", fields: ["name": .string("Entered name")], payload: [:]))
            await fulfillment(of: [registered], timeout: 10)
            try await waitUntil { model.connected && !model.paramPickerPending(action: "chrome_profile_save") }
            XCTAssertEqual(model.pendingSurface, form)
            XCTAssertEqual(model.composerDraft, "A newer composer draft")
            XCTAssertNotNil(model.surfaceFailureMessage)
            XCTAssertFalse(peer.events.contains { $0.frame.payload["action"]?.stringValue == "chrome_profile_save" })
        }
    }

    func testRejectedRefreshSignsOutWithoutReplayingARequest() async throws {
        try await withModel { model, peer, store, _ in
            peer.configureRefresh(status: 401)
            model.handleFrame(try XCTUnwrap(InboundFrame.parse(#"{"type":"auth_required","reason":"expired"}"#)))
            try await waitUntil { !model.signedIn }
            XCTAssertNil(store.load())
            XCTAssertEqual(peer.refreshCount, 1)
            XCTAssertEqual(peer.registrations.count, 1)
            XCTAssertTrue(peer.events.isEmpty)
        }
    }

    func testTransientRefreshNeverSendsExpiredReadAndRetryUsesFreshDefault() async throws {
        try await withModel { model, peer, store, clock in
            clock.advance(7200)
            peer.configureRefresh(status: 503)
            model.openSurface("guidance", params: .object(["mode": .string("list")]))
            try await waitUntil { model.guidanceFailed }
            XCTAssertTrue(model.signedIn)
            XCTAssertEqual(store.load()?.accessToken, peer.originalToken)
            XCTAssertTrue(peer.events.isEmpty)
            peer.configureRefresh(status: 200)
            let registered = peer.expectRegistration()
            model.retryGuidance()
            await fulfillment(of: [registered], timeout: 10)
            try await waitUntil { peer.events.count == 1 }
            XCTAssertEqual(
                GuidanceRequest(frameText: String(decoding: try peer.events[0].frame.payload.encoded(), as: UTF8.self)),
                .list)
            XCTAssertEqual(peer.refreshCount, 2)
        }
    }

    func testForeignOwnerRefreshIsRejectedWithoutPersistingTheToken() async throws {
        try await withModel { model, peer, store, clock in
            clock.advance(7200)
            peer.configureRefresh(status: 200, subject: "foreign")
            model.openSurface("guidance", params: .object(["mode": .string("list")]))
            try await waitUntil { !model.signedIn }
            XCTAssertNil(store.load())
            XCTAssertEqual(peer.registrations.count, 1)
            XCTAssertTrue(peer.events.isEmpty)
        }
    }

    func testUnsentProviderWriteKeepsFormAndComposerWithoutAutomaticSave() async throws {
        try await withModel { model, peer, _, clock in
            model.openSurface("llm")
            try await waitUntil { peer.events.count == 1 }
            let generation = try XCTUnwrap(peer.events[0].frame.payload["request_generation"]?.stringValue)
            model.handleFrame(
                try XCTUnwrap(
                    InboundFrame.parse(
                        """
                        {"type":"chrome_surface","region":"modal","mode":"replace","surface_key":"llm","title":"AI provider",
                        "request_generation":"\(generation)","components":[{"type":"param_picker","title":"Provider settings",
                        "fields":[{"name":"endpoint","kind":"text","default":"https://fixture.example.test"}],
                        "submit_action":"chrome_llm_save","submit_label":"Save"}]}
                        """)))
            let form = try XCTUnwrap(model.pendingSurface)
            model.composerDraft = "Unsent composer"
            clock.advance(7200)
            let registered = peer.expectRegistration()
            XCTAssertTrue(
                model.submitParamPicker(
                    action: "chrome_llm_save", fields: ["endpoint": .string("https://entered.example.test")],
                    payload: [:]))
            await fulfillment(of: [registered], timeout: 10)
            try await waitUntil { model.connected && !model.paramPickerPending(action: "chrome_llm_save") }
            XCTAssertEqual(model.pendingSurface, form)
            XCTAssertEqual(model.composerDraft, "Unsent composer")
            XCTAssertNotNil(model.surfaceFailureMessage)
            XCTAssertFalse(peer.events.contains { $0.frame.payload["action"]?.stringValue == "chrome_llm_save" })
            XCTAssertFalse(
                peer.events.contains { String(describing: $0.frame.payload).contains("entered.example.test") })
            XCTAssertNil(model.llmFirstLoginOperation)
        }
    }

    func testUnsentQueryRestoresComposerAndIsNeverReplayed() async throws {
        try await withModel { model, peer, _, clock in
            clock.advance(7200)
            let registered = peer.expectRegistration()
            model.sendChat("Review this unsent message")
            model.composerDraft = ""
            await fulfillment(of: [registered], timeout: 10)
            try await waitUntil { model.connected && model.errorBanner != nil }
            XCTAssertEqual(model.composerDraft, "Review this unsent message")
            XCTAssertTrue(peer.events.isEmpty)
            XCTAssertFalse(model.turnActive)
            XCTAssertEqual(peer.registrations.count, 2)
        }
    }

    func testHeldQueryRefreshCannotRestoreIntoANewerConversationOrDraft() async throws {
        for destination in ["empty", "draft", "other-chat"] {
            try await withModel { model, peer, _, clock in
                clock.advance(7200)
                peer.holdRefresh()
                let requested = peer.expectRefresh()
                model.sendChat("Retired original query")
                model.composerDraft = ""
                await fulfillment(of: [requested], timeout: 10)
                if destination == "other-chat" {
                    model.openChat("77777777-7777-4777-8777-777777777777")
                } else {
                    model.newChat()
                }
                let expectedDraft = destination == "draft" ? "A newer unsent draft" : ""
                model.composerDraft = expectedDraft
                model.turnActive = true
                model.statusText = "New conversation activity"
                let registered = peer.expectRegistration()
                peer.releaseRefresh()
                await fulfillment(of: [registered], timeout: 10)
                try await waitUntil { model.connected }
                _ = try await model.rest.chats()
                XCTAssertEqual(model.composerDraft, expectedDraft)
                XCTAssertTrue(model.turnActive)
                XCTAssertEqual(model.statusText, "New conversation activity")
                XCTAssertFalse(peer.events.contains { $0.frame.payload["action"]?.stringValue == "chat_message" })
                XCTAssertEqual(
                    model.activeChatId, destination == "other-chat" ? "77777777-7777-4777-8777-777777777777" : nil)
            }
        }
    }

    private func loadProviderForm(_ model: AppModel, peer: SocketAuthenticationPeer) async throws
        -> AppModel.SurfaceContent
    {
        model.openSurface("llm")
        try await waitUntil { peer.events.contains { $0.frame.payload["payload"]?["surface"]?.stringValue == "llm" } }
        let open = try XCTUnwrap(peer.events.last { $0.frame.payload["action"]?.stringValue == "chrome_open" })
        let generation = try XCTUnwrap(open.frame.payload["request_generation"]?.stringValue)
        peer.send(
            """
            {"type":"chrome_surface","region":"modal","mode":"replace","surface_key":"llm","title":"AI provider",
            "request_generation":"\(generation)","components":[{"type":"param_picker","fields":[
            {"name":"endpoint","kind":"text","default":"https://fixture.example.test"}],
            "submit_action":"chrome_llm_save","submit_label":"Save"}]}
            """, socket: open.socket)
        try await waitUntil { model.pendingSurface?.title == "AI provider" }
        return try XCTUnwrap(model.pendingSurface)
    }

    private func providerClose(_ generation: String) -> String {
        """
        {"type":"chrome_surface","region":"modal","mode":"replace","surface_key":"","title":"",
        "admin_only":false,"components":[],"request_generation":"\(generation)"}
        """
    }

    private func completeProviderSave(_ event: SocketAuthenticationPeer.Event, peer: SocketAuthenticationPeer) throws {
        let request = try XCTUnwrap(event.frame.payload["request_generation"]?.stringValue)
        let connection = try XCTUnwrap(peer.registrations.last { $0.socket == event.socket }?.generation)
        peer.send(
            """
            {"type":"operation_status","operation_id":"22222222-2222-4222-8222-222222222222",
            "action":"chrome_llm_save","surface":"llm_settings","chat_id":null,
            "connection_generation":"\(connection)","request_generation":"\(request)",
            "sequence":1,"state":"completed","phase":"completed","label":"Provider settings saved",
            "terminal":true,"retryable":false,"error":null,"retry_after_ms":null,"updated_at":"2026-10-05T18:00:00Z"}
            """, socket: event.socket)
        peer.send(providerClose(request), socket: event.socket)
    }

    func testProviderSaveAfterExpiredReconnectClosesTheRetainedFormOnce() async throws {
        try await withModel { model, peer, _, clock in
            let form = try await loadProviderForm(model, peer: peer)
            model.composerDraft = "Unsent composer remains"
            clock.advance(7200)
            peer.holdRefresh()
            let requested = peer.expectRefresh()
            let registered = peer.expectRegistration()
            let oldSocket = try XCTUnwrap(peer.registrations.last?.socket)
            peer.disconnect(socket: oldSocket)
            await fulfillment(of: [requested], timeout: 10)
            XCTAssertFalse(model.connected)
            XCTAssertEqual(model.pendingSurface, form)
            XCTAssertFalse(
                model.submitParamPicker(
                    action: "chrome_llm_save", fields: ["endpoint": .string("https://entered.example.test")],
                    payload: [:]))
            peer.releaseRefresh()
            await fulfillment(of: [registered], timeout: 10)
            try await waitUntil { model.connected }
            XCTAssertEqual(model.pendingSurface, form)
            XCTAssertEqual(peer.events.count, 1)
            XCTAssertTrue(
                model.submitParamPicker(
                    action: "chrome_llm_save", fields: ["endpoint": .string("https://entered.example.test")],
                    payload: [:]))
            XCTAssertFalse(
                model.submitParamPicker(
                    action: "chrome_llm_save", fields: ["endpoint": .string("https://entered.example.test")],
                    payload: [:]))
            try await waitUntil {
                peer.events.contains { $0.frame.payload["action"]?.stringValue == "chrome_llm_save" }
            }
            let save = try XCTUnwrap(peer.events.last { $0.frame.payload["action"]?.stringValue == "chrome_llm_save" })
            XCTAssertEqual(save.socket, peer.registrations.last?.socket)
            XCTAssertNotEqual(save.socket, oldSocket)
            XCTAssertEqual(
                save.frame.payload["payload"]?["fields"]?["endpoint"], .string("https://entered.example.test"))
            try completeProviderSave(save, peer: peer)
            try await waitUntil { model.screen == .chat }
            XCTAssertNil(model.pendingSurface)
            XCTAssertEqual(model.llmFirstLoginOperation?.state, .completed)
            XCTAssertEqual(model.composerDraft, "Unsent composer remains")
            XCTAssertEqual(peer.events.filter { $0.frame.payload["action"]?.stringValue == "chrome_llm_save" }.count, 1)
            XCTAssertEqual(peer.refreshCount, 1)
        }
    }

    func testHeldProviderRefreshCancelsTheUnsentWriteAndExplicitRetryOwnsItsClose() async throws {
        try await withModel { model, peer, _, clock in
            let form = try await loadProviderForm(model, peer: peer)
            clock.advance(7200)
            peer.holdRefresh()
            let requested = peer.expectRefresh()
            let registered = peer.expectRegistration()
            XCTAssertTrue(
                model.submitParamPicker(
                    action: "chrome_llm_save", fields: ["endpoint": .string("https://entered.example.test")],
                    payload: [:]))
            let retired = try XCTUnwrap(model.llmFirstLoginOperation?.requestGeneration)
            await fulfillment(of: [requested], timeout: 10)
            peer.releaseRefresh()
            await fulfillment(of: [registered], timeout: 10)
            try await waitUntil { model.connected && !model.paramPickerPending(action: "chrome_llm_save") }
            XCTAssertEqual(model.pendingSurface, form)
            XCTAssertNotNil(model.surfaceFailureMessage)
            XCTAssertFalse(peer.events.contains { $0.frame.payload["action"]?.stringValue == "chrome_llm_save" })
            XCTAssertTrue(
                model.submitParamPicker(
                    action: "chrome_llm_save", fields: ["endpoint": .string("https://entered.example.test")],
                    payload: [:]))
            try await waitUntil {
                peer.events.contains { $0.frame.payload["action"]?.stringValue == "chrome_llm_save" }
            }
            let save = try XCTUnwrap(peer.events.last { $0.frame.payload["action"]?.stringValue == "chrome_llm_save" })
            XCTAssertNotEqual(save.frame.payload["request_generation"]?.stringValue, retired)
            peer.send(providerClose(retired), socket: save.socket)
            peer.send(#"{"type":"notification","title":"Retired close observed"}"#, socket: save.socket)
            try await waitUntil { model.errorBanner == "Retired close observed" }
            XCTAssertEqual(model.screen, .surface)
            XCTAssertEqual(model.pendingSurface, form)
            try completeProviderSave(save, peer: peer)
            try await waitUntil { model.screen == .chat }
            XCTAssertEqual(model.llmFirstLoginOperation?.state, .completed)
            XCTAssertEqual(peer.events.filter { $0.frame.payload["action"]?.stringValue == "chrome_llm_save" }.count, 1)
            XCTAssertEqual(peer.refreshCount, 1)
        }
    }

    func testHeldOrdinaryReadRefreshAcceptsOnlyTheRenewedSocketGeneration() async throws {
        try await withModel { model, peer, _, clock in
            clock.advance(7200)
            peer.holdRefresh()
            let requested = peer.expectRefresh()
            let registered = peer.expectRegistration()
            var retired: String?
            model.outboundTap = { text in
                if retired == nil, let frame = InboundFrame.parse(text),
                    frame.payload["action"]?.stringValue == "chrome_open"
                {
                    retired = frame.payload["request_generation"]?.stringValue
                }
            }
            model.openSurface("authoring")
            await fulfillment(of: [requested], timeout: 10)
            XCTAssertTrue(peer.events.isEmpty)
            peer.releaseRefresh()
            await fulfillment(of: [registered], timeout: 10)
            try await waitUntil { peer.events.count == 1 }
            let read = try XCTUnwrap(peer.events.first)
            let current = try XCTUnwrap(read.frame.payload["request_generation"]?.stringValue)
            let previous = try XCTUnwrap(retired)
            XCTAssertNotEqual(current, previous)
            XCTAssertEqual(read.socket, peer.registrations.last?.socket)
            let content = "\"components\":[{\"type\":\"text\",\"text\":\"Authorized authoring controls\"}]"
            peer.send(
                "{\"type\":\"chrome_surface\",\"surface_key\":\"authoring\",\"title\":\"Current authoring\",\"request_generation\":\"\(current)\",\(content)}",
                socket: read.socket)
            try await waitUntil { model.pendingSurface?.title == "Current authoring" }
            for socket in [try XCTUnwrap(peer.registrations.first?.socket), read.socket] {
                peer.send(
                    "{\"type\":\"chrome_surface\",\"surface_key\":\"authoring\",\"title\":\"Retired authoring\",\"request_generation\":\"\(previous)\",\(content)}",
                    socket: socket)
            }
            peer.send(#"{"type":"notification","title":"Retired reads observed"}"#, socket: read.socket)
            try await waitUntil { model.errorBanner == "Retired reads observed" }
            XCTAssertEqual(model.pendingSurface?.title, "Current authoring")
            XCTAssertEqual(model.pendingSurfaceKey, "authoring")
            XCTAssertEqual(peer.events.count, 1)
            XCTAssertEqual(peer.refreshCount, 1)
        }
    }

    func testHeldProviderRefreshCannotSaveOrCloseForAReplacedOwner() async throws {
        try await withModel { model, peer, store, clock in
            let form = try await loadProviderForm(model, peer: peer)
            clock.advance(7200)
            peer.holdRefresh()
            let requested = peer.expectRefresh()
            let refresh = Task { try? await model.rest.chats() }
            XCTAssertTrue(
                model.submitParamPicker(
                    action: "chrome_llm_save", fields: ["endpoint": .string("https://entered.example.test")],
                    payload: [:]))
            let retired = try XCTUnwrap(model.llmFirstLoginOperation?.requestGeneration)
            await fulfillment(of: [requested], timeout: 10)
            let replacement = try XCTUnwrap(
                ConversationAccount(issuer: "https://issuer.example.test", subject: "replacement"))
            model.bindConversationAccount(replacement)
            peer.releaseRefresh()
            _ = await refresh.value
            model.handleFrame(try XCTUnwrap(InboundFrame.parse(providerClose(retired))))
            XCTAssertEqual(model.downloadOwner.account, replacement)
            XCTAssertEqual(model.pendingSurface, form)
            XCTAssertEqual(model.screen, .surface)
            XCTAssertEqual(store.load()?.accessToken, peer.originalToken)
            XCTAssertFalse(peer.events.contains { $0.frame.payload["action"]?.stringValue == "chrome_llm_save" })
            XCTAssertEqual(peer.registrations.count, 1)
        }
    }

    private func installConsole(_ model: AppModel) throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "chrome-console", withExtension: "json"))
        model.chromeMenu = try XCTUnwrap(ChromeMenuModel.fromJSON(try JSONValue.parse(Data(contentsOf: url))))
    }

    private func advancedResponse(_ generation: String) -> String {
        """
        {"type":"chrome_surface","region":"modal","mode":"replace","surface_key":"guidance",
        "title":"Advanced settings","admin_only":false,"request_generation":"\(generation)",
        "components":[{"type":"text","content":"Select agents, skills and private notes for this chat","variant":"body"}]}
        """
    }

    private func failAdvancedRead(_ model: AppModel, peer: SocketAuthenticationPeer) async throws -> String {
        let generation = try XCTUnwrap(model.guidanceState.generation)
        let submission = try XCTUnwrap(model.guidanceState.submissionId)
        peer.send(
            """
            {"type":"error","submission_id":"\(submission)","accepted":false,"code":"operation_failed",
            "message":"The server did not send the screen","retryable":true,"retry_after_ms":null}
            """
        )
        try await waitUntil { model.guidanceFailed }
        return generation
    }

    func testAdvancedReadRetryKeepsItsSelectionDestinationAndConversation() async throws {
        try await withModel { model, peer, _, _ in
            try installConsole(model)
            let chat = "77777777-7777-4777-8777-777777777777"
            model.activeChatId = chat
            let selection = TurnSelection.empty
            model.turnSelection = selection
            model.openSurface("guidance", params: .object(["view": .string("selection")]))
            try await waitUntil { peer.events.count == 1 }
            let retired = try await failAdvancedRead(model, peer: peer)
            model.retryGuidance()
            try await waitUntil { peer.events.count == 2 }
            let retry = try XCTUnwrap(peer.events.last)
            let text = String(decoding: try retry.frame.payload.encoded(), as: UTF8.self)
            XCTAssertEqual(GuidanceRequest(frameText: text), .selection)
            XCTAssertEqual(model.pendingSurfaceParams, .object(["view": .string("selection")]))
            XCTAssertEqual(model.activeChatId, chat)
            XCTAssertEqual(model.turnSelection, selection)
            let current = try XCTUnwrap(model.guidanceState.generation)
            XCTAssertNotEqual(current, retired)
            peer.send(advancedResponse(current), socket: retry.socket)
            try await waitUntil { model.pendingSurface?.title == "Advanced settings" }
            peer.send(advancedResponse(retired), socket: retry.socket)
            peer.send(#"{"type":"notification","title":"Retired advanced result observed"}"#, socket: retry.socket)
            try await waitUntil { model.errorBanner == "Retired advanced result observed" }
            XCTAssertEqual(model.pendingSurface?.title, "Advanced settings")
            XCTAssertEqual(model.pendingSurfaceParams, .object(["view": .string("selection")]))
            XCTAssertEqual(peer.events.map { $0.frame.payload["action"]?.stringValue }, ["chrome_open", "chrome_open"])
        }
    }

    func testAdvancedRetryRefusesARetiredEntryWithoutSwitchingToPrivateNotes() async throws {
        try await withModel { model, peer, _, _ in
            try installConsole(model)
            model.openSurface("guidance", params: .object(["view": .string("selection")]))
            try await waitUntil { peer.events.count == 1 }
            _ = try await failAdvancedRead(model, peer: peer)
            model.handleFrame(menu)
            model.retryGuidance()
            XCTAssertTrue(model.guidanceFailed)
            XCTAssertNil(model.guidanceState.generation)
            XCTAssertNotNil(model.surfaceFailureMessage)
            XCTAssertEqual(model.pendingSurfaceParams, .object(["view": .string("selection")]))
            _ = try await model.rest.chats()
            XCTAssertEqual(peer.events.count, 1)
            XCTAssertEqual(model.pendingSurfaceKey, "guidance")
            XCTAssertNil(model.pendingSurface)
        }
    }

    func testExpiredAdvancedReadReopensOnlyTheOriginalSelectionAfterHeldRefresh() async throws {
        try await withModel { model, peer, _, clock in
            try installConsole(model)
            let chat = "77777777-7777-4777-8777-777777777777"
            model.activeChatId = chat
            model.turnSelection = .empty
            clock.advance(7200)
            peer.holdRefresh()
            let requested = peer.expectRefresh()
            let registered = peer.expectRegistration()
            model.openSurface("guidance", params: .object(["view": .string("selection")]))
            await fulfillment(of: [requested], timeout: 10)
            XCTAssertTrue(peer.events.isEmpty)
            peer.releaseRefresh()
            await fulfillment(of: [registered], timeout: 10)
            try await waitUntil { peer.events.count == 1 }
            let read = try XCTUnwrap(peer.events.first)
            XCTAssertEqual(
                GuidanceRequest(frameText: String(decoding: try read.frame.payload.encoded(), as: UTF8.self)),
                .selection)
            XCTAssertEqual(read.socket, peer.registrations.last?.socket)
            XCTAssertEqual(model.pendingSurfaceParams, .object(["view": .string("selection")]))
            XCTAssertEqual(model.activeChatId, chat)
            XCTAssertEqual(model.turnSelection, .empty)
            peer.send(advancedResponse(try XCTUnwrap(model.guidanceState.generation)), socket: read.socket)
            try await waitUntil { model.pendingSurface?.title == "Advanced settings" }
            XCTAssertEqual(peer.events.count, 1)
            XCTAssertEqual(peer.refreshCount, 1)
            XCTAssertNil(model.surfaceFailureMessage)
        }
    }

    func testExpiredAdvancedRenewalRefusesARetiredSelectionEntryWithoutOpeningNotes() async throws {
        try await withModel { model, peer, _, clock in
            try installConsole(model)
            clock.advance(7200)
            peer.holdRefresh()
            let requested = peer.expectRefresh()
            let registered = peer.expectRegistration()
            model.openSurface("guidance", params: .object(["view": .string("selection")]))
            await fulfillment(of: [requested], timeout: 10)
            model.handleFrame(menu)
            peer.releaseRefresh()
            await fulfillment(of: [registered], timeout: 10)
            try await waitUntil { model.connected }
            XCTAssertTrue(model.guidanceFailed)
            XCTAssertNotNil(model.surfaceFailureMessage)
            XCTAssertEqual(model.pendingSurfaceParams, .object(["view": .string("selection")]))
            XCTAssertNil(model.pendingSurface)
            XCTAssertTrue(peer.events.isEmpty)
            XCTAssertEqual(peer.refreshCount, 1)
        }
    }
}

private final class CredentialTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private final class SocketAuthenticationPeer: @unchecked Sendable {
    struct Registration {
        let socket: Int
        let token: String
        let generation: String?
    }
    struct Event {
        let socket: Int
        let frame: InboundFrame
    }
    private final class Connection {
        let socket: Int
        let network: NWConnection
        var upgraded = false
        var buffer = Data()
        init(socket: Int, network: NWConnection) {
            self.socket = socket
            self.network = network
        }
    }

    let ready = XCTestExpectation(description: "local identity and socket peer ready")
    let listener: NWListener
    let originalToken: String
    private let clock: CredentialTestClock
    private let queue = DispatchQueue(label: "astral.socket-authentication.tests")
    private var connections: [Connection] = []
    private var observedRegistrations: [Registration] = []
    private var observedEvents: [Event] = []
    private var observedRefreshes = 0
    private var observedAuthorization: [String] = []
    private var registrationExpectation: XCTestExpectation?
    private var refreshExpectation: XCTestExpectation?
    private var holdsRefresh = false
    private var pendingRefresh: [Connection] = []
    private var refreshStatus = 200
    private var refreshedSubject = "owner"
    private var refreshLifetime: TimeInterval = 86400

    init(clock: CredentialTestClock, jwtLifetime: TimeInterval = 3600) throws {
        self.clock = clock
        originalToken = Self.token("original", subject: "owner", expiry: clock.now.addingTimeInterval(jwtLifetime))
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    private static func token(_ marker: String, subject: String, expiry: Date) -> String {
        let payload: [String: Any] = [
            "iss": "https://issuer.example.test", "sub": subject, "jti": marker,
            "exp": expiry.timeIntervalSince1970,
        ]
        return "fixture." + PKCE.base64url(try! JSONSerialization.data(withJSONObject: payload)) + ".fixture"
    }

    var registrations: [Registration] { queue.sync { observedRegistrations } }
    var events: [Event] { queue.sync { observedEvents } }
    var refreshCount: Int { queue.sync { observedRefreshes } }
    var restAuthorization: [String] { queue.sync { observedAuthorization } }

    func expectRegistration() -> XCTestExpectation {
        queue.sync {
            let value = XCTestExpectation(description: "next registered credential")
            registrationExpectation = value
            return value
        }
    }

    func expectRefresh() -> XCTestExpectation {
        queue.sync {
            let value = XCTestExpectation(description: "refresh request accepted by local peer")
            refreshExpectation = value
            return value
        }
    }

    func holdRefresh() { queue.sync { holdsRefresh = true } }
    func configureRefresh(status: Int, subject: String = "owner", lifetime: TimeInterval = 86400) {
        queue.sync {
            refreshStatus = status
            refreshedSubject = subject
            refreshLifetime = lifetime
        }
    }
    func releaseRefresh() {
        queue.async {
            self.holdsRefresh = false
            for connection in self.pendingRefresh { self.respondRefresh(connection) }
            self.pendingRefresh = []
        }
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in if case .ready = state { self?.ready.fulfill() } }
        listener.newConnectionHandler = { [weak self] network in
            guard let self else {
                network.cancel()
                return
            }
            let connection = Connection(socket: self.connections.count, network: network)
            self.connections.append(connection)
            network.start(queue: self.queue)
            self.receive(connection)
        }
        listener.start(queue: queue)
    }

    private func receive(_ connection: Connection) {
        connection.network.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, complete, error in
            guard let self, error == nil else {
                connection.network.cancel()
                return
            }
            if let data { connection.buffer.append(data) }
            if connection.upgraded { self.consumeSocket(connection) } else { self.consumeHTTP(connection) }
            if complete { connection.network.cancel() } else { self.receive(connection) }
        }
    }

    private func consumeHTTP(_ connection: Connection) {
        guard let boundary = connection.buffer.range(of: Data("\r\n\r\n".utf8)),
            let header = String(data: connection.buffer[..<boundary.lowerBound], encoding: .utf8)
        else { return }
        let lines = header.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1)
            if pieces.count == 2 { headers[pieces[0].lowercased()] = pieces[1].trimmingCharacters(in: .whitespaces) }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard connection.buffer.count >= boundary.upperBound + length else { return }
        connection.buffer.removeFirst(boundary.upperBound + length)
        if let key = headers["sec-websocket-key"] {
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
                .base64EncodedString()
            connection.upgraded = true
            connection.network.send(
                content: Data(
                    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
                        .utf8),
                completion: .contentProcessed { _ in })
            consumeSocket(connection)
        } else if lines[0].contains("/protocol/openid-connect/token ") {
            observedRefreshes += 1
            refreshExpectation?.fulfill()
            refreshExpectation = nil
            if holdsRefresh { pendingRefresh.append(connection) } else { respondRefresh(connection) }
        } else {
            observedAuthorization.append(headers["authorization"] ?? "")
            respond(connection, status: 200, payload: .array([]))
        }
    }

    private func respondRefresh(_ connection: Connection) {
        let token = Self.token(
            "rotated-\(observedRefreshes)", subject: refreshedSubject,
            expiry: clock.now.addingTimeInterval(refreshLifetime))
        respond(
            connection, status: refreshStatus,
            payload: refreshStatus == 200
                ? .object([
                    "access_token": .string(token), "refresh_token": .string("fixture-rotated-refresh"),
                    "expires_in": .number(refreshLifetime),
                ])
                : .object(["error": .string("fixture_denial")]))
    }

    private func respond(_ connection: Connection, status: Int, payload: JSONValue) {
        let body = try! payload.encoded()
        let header =
            "HTTP/1.1 \(status) Fixture\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.network.send(
            content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.network.cancel() })
    }

    private func consumeSocket(_ connection: Connection) {
        while connection.buffer.count >= 2 {
            let bytes = [UInt8](connection.buffer)
            let opcode = bytes[0] & 15
            let masked = bytes[1] & 128 != 0
            var length = Int(bytes[1] & 127)
            var offset = 2
            if length == 126 {
                guard bytes.count >= 4 else { return }
                length = Int(bytes[2]) * 256 + Int(bytes[3])
                offset = 4
            }
            guard length < 65536, length != 127 else {
                connection.network.cancel()
                return
            }
            let maskOffset = offset
            if masked { offset += 4 }
            guard bytes.count >= offset + length else { return }
            var body = Array(bytes[offset..<(offset + length)])
            if masked { for index in body.indices { body[index] ^= bytes[maskOffset + index % 4] } }
            connection.buffer.removeFirst(offset + length)
            if opcode == 8 {
                connection.network.cancel()
                return
            }
            guard opcode == 1, let text = String(bytes: body, encoding: .utf8), let frame = InboundFrame.parse(text)
            else { continue }
            if frame.name == "register_ui" {
                observedRegistrations.append(
                    Registration(
                        socket: connection.socket, token: frame.payload["token"]?.stringValue ?? "",
                        generation: frame.payload["connection_generation"]?.stringValue))
                registrationExpectation?.fulfill()
                registrationExpectation = nil
                send(#"{"type":"ready"}"#, to: connection)
            } else {
                observedEvents.append(Event(socket: connection.socket, frame: frame))
            }
        }
    }

    private func send(_ text: String, to connection: Connection) {
        let content = Data(text.utf8)
        var header = Data([129])
        if content.count < 126 {
            header.append(UInt8(content.count))
        } else {
            header.append(contentsOf: [126, UInt8(content.count >> 8), UInt8(content.count & 255)])
        }
        connection.network.send(content: header + content, completion: .contentProcessed { _ in })
    }

    func send(_ text: String, socket: Int? = nil) {
        queue.async {
            if let connection = self.connections.last(where: { $0.upgraded && (socket == nil || $0.socket == socket) })
            {
                self.send(text, to: connection)
            }
        }
    }

    func disconnect(socket: Int) {
        queue.sync { connections.first { $0.socket == socket }?.network.cancel() }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            for connection in connections { connection.network.cancel() }
        }
    }
}

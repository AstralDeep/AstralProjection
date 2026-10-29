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
        jwtLifetime: TimeInterval = 3600, liveness: LivenessPolicy? = nil,
        uiAuthRefreshSupported: Bool = false,
        advanceCredentialClockWhenTimerFires: TimeInterval? = nil,
        _ body: (AppModel, SocketAuthenticationPeer, InMemoryTokenStore, CredentialTestClock) async throws -> Void
    ) async throws {
        let clock = CredentialTestClock()
        let peer = try SocketAuthenticationPeer(clock: clock, jwtLifetime: jwtLifetime)
        peer.uiAuthRefreshSupported = uiAuthRefreshSupported
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
        if let advanceCredentialClockWhenTimerFires {
            model.uiAuthRefreshSleeper = { _ in clock.advance(advanceCredentialClockWhenTimerFires) }
        }
        if let liveness { model.socketLiveness = liveness }
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

    #if os(macOS)
        private func withServerCustodyModel(
            candidateSession: String, candidateScope: String = "openid profile",
            candidateClaims: [String: Any] = [:], reuseAccessToken: Bool = false,
            additionalReplyTokens: [String] = [],
            uiAuthRefreshSleeper: @escaping @Sendable (UInt64) async -> Void = {
                try? await Task.sleep(nanoseconds: $0)
            },
            _ body: (
                AppModel, SocketAuthenticationPeer, InMemoryMeshKeyStorage, CredentialTestClock,
                ServerSessionScope, ServerCustodyRefreshReplies
            ) async throws -> Void
        ) async throws {
            let clock = CredentialTestClock()
            let peer = try SocketAuthenticationPeer(clock: clock)
            peer.uiAuthRefreshSupported = true
            peer.start()
            defer { peer.stop() }
            await fulfillment(of: [peer.ready], timeout: 10)
            let port = try XCTUnwrap(peer.listener.port).rawValue
            let suite = "AppModelSocketAuthenticationTests.ServerCustody.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("https://server.test", forKey: "serverBase")
            defaults.set("https://issuer.example.test", forKey: "authority")

            let model = AppModel(
                tokenStore: InMemoryTokenStore(), defaults: defaults,
                webSocket: WSClient(url: URL(string: "ws://127.0.0.1:\(port)/ws")!),
                credentialClock: { clock.now })
            model.uiAuthRefreshSleeper = uiAuthRefreshSleeper
            let scope = try ServerSessionScope(server: model.serverBase, oidc: try XCTUnwrap(model.oidc))
            let initialSession = try ServerSession(
                scope: scope, owner: "owner", accessToken: peer.originalToken,
                cookie: "astral_session=synthetic", cookieExpiresAt: clock.now.addingTimeInterval(7200))
            let storage = InMemoryMeshKeyStorage()
            try storage.save(JSONEncoder().encode(initialSession), key: scope.storageKey)
            model.serverSessionStorage = storage

            let initialRefreshToken = serverCustodyJWT(
                issuer: scope.issuer, clientID: model.clientId, session: "fixture-session",
                expiry: clock.now.addingTimeInterval(120))
            let candidateToken =
                reuseAccessToken
                ? initialRefreshToken
                : serverCustodyJWT(
                    issuer: scope.issuer, clientID: model.clientId, session: candidateSession,
                    expiry: clock.now.addingTimeInterval(7200), marker: "candidate", scope: candidateScope,
                    extraClaims: candidateClaims)
            let replies = ServerCustodyRefreshReplies(
                tokens: [initialRefreshToken, candidateToken] + additionalReplyTokens)
            model.serverSessionTransport = { request in
                if request.httpMethod == "POST" {
                    return ServerSessionReply(
                        body: .object(["outcome": .string("revoked"), "revoked": .bool(true), "queued": .bool(false)]))
                }
                let token = await replies.next()
                return ServerSessionReply(
                    body: .object([
                        "authenticated": .bool(true), "access_token": .string(token),
                        "resumed": .bool(true), "user_id": .string("owner"),
                    ]))
            }

            let registered = peer.expectRegistration()
            await model.bootstrap()
            await fulfillment(of: [registered], timeout: 10)
            try await waitUntil { model.connected }
            do {
                try await body(model, peer, storage, clock, scope, replies)
            } catch {
                await model.signOut(revokeRemote: false)
                throw error
            }
            await model.signOut(revokeRemote: false)
        }

        private func serverCustodyJWT(
            issuer: String, clientID: String, session: String, expiry: Date, marker: String = "fixture",
            scope: String = "openid profile", extraClaims: [String: Any] = [:]
        ) -> String {
            var claims: [String: Any] = [
                "iss": issuer, "sub": "owner", "azp": clientID, "sid": session,
                "scope": scope, "jti": marker, "iat": expiry.timeIntervalSince1970 - 3600,
                "exp": expiry.timeIntervalSince1970,
            ]
            claims.merge(extraClaims) { _, replacement in replacement }
            return "fixture." + PKCE.base64url(try! JSONSerialization.data(withJSONObject: claims)) + ".fixture"
        }
    #endif

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

    #if os(macOS)
        func testServerCustodyRefreshRejectsChangedSessionBeforePersistingCandidate() async throws {
            try await withServerCustodyModel(candidateSession: "changed-session") {
                model, peer, storage, clock, scope, _ in
                let registered = try XCTUnwrap(peer.registrations.last)
                let priorData = try XCTUnwrap(storage.load(scope.storageKey))
                let priorSession = try JSONDecoder().decode(ServerSession.self, from: priorData)
                XCTAssertEqual(registered.token, priorSession.accessToken)

                clock.advance(180)
                _ = try? await model.rest.chats()

                let persistedData = try XCTUnwrap(storage.load(scope.storageKey))
                let persistedSession = try JSONDecoder().decode(ServerSession.self, from: persistedData)
                XCTAssertEqual(persistedSession.accessToken, priorSession.accessToken)
                XCTAssertTrue(peer.authRefreshes.isEmpty)
                XCTAssertEqual(peer.registrations.count, 1)
                XCTAssertTrue(model.signedIn)
            }
        }

        func testServerCustodyRefreshRejectsIdentityAndAuthorizationChangesBeforePersisting() async throws {
            let cases: [(String, [String: Any])] = [
                ("session", ["sid": "different-session"]),
                ("audience", ["aud": ["different-client"]]),
                ("malformed_audience", ["aud": ["astral-desktop", 7]]),
                ("scope", ["scope": "openid profile changed"]),
                ("malformed_scope", ["scope": ["openid", 7]]),
                ("malformed_roles", ["realm_access": ["roles": ["operator", 7]]]),
                ("malformed_resource_access", ["resource_access": ["astral-desktop": 7]]),
                ("subject", ["sub": "different-owner"]),
                ("issuer", ["iss": "https://different-issuer.example.test"]),
                ("client", ["azp": "different-client"]),
                ("client_key_fallback", ["azp": 7, "client_id": "astral-desktop"]),
                ("session_key_fallback", ["sid": 7, "session_state": "fixture-session"]),
                ("reused_token_id", ["jti": "fixture"]),
            ]
            for (label, claims) in cases {
                try await withServerCustodyModel(candidateSession: "fixture-session", candidateClaims: claims) {
                    model, peer, storage, clock, scope, _ in
                    let initial = try XCTUnwrap(peer.registrations.last)
                    let prior = try JSONDecoder().decode(
                        ServerSession.self, from: XCTUnwrap(storage.load(scope.storageKey)))
                    clock.advance(180)
                    _ = try? await model.rest.chats()

                    let persisted = try JSONDecoder().decode(
                        ServerSession.self, from: XCTUnwrap(storage.load(scope.storageKey)))
                    XCTAssertEqual(persisted.accessToken, prior.accessToken, label)
                    XCTAssertTrue(peer.authRefreshes.isEmpty, label)
                    XCTAssertEqual(peer.registrations.count, 1, label)
                    XCTAssertEqual(peer.registrations.first?.token, initial.token, label)
                    XCTAssertTrue(model.signedIn, label)
                }
            }
        }

        func testServerCustodyLateRefreshCannotRestoreAfterLogout() async throws {
            try await withServerCustodyModel(candidateSession: "fixture-session") {
                model, peer, storage, clock, scope, replies in
                await replies.holdNext()
                clock.advance(180)
                let refresh = Task { _ = try? await model.rest.chats() }
                await replies.waitUntilHeld()

                await model.signOut(revokeRemote: false)
                await replies.release()
                _ = await refresh.value

                XCTAssertFalse(model.signedIn)
                XCTAssertNil(try storage.load(scope.storageKey))
                XCTAssertEqual(peer.registrations.count, 1)
                XCTAssertTrue(peer.authRefreshes.isEmpty)
            }
        }

        func testServerCustodyLateRefreshCannotRestoreAfterServerScopeChange() async throws {
            try await withServerCustodyModel(candidateSession: "fixture-session") {
                model, peer, storage, clock, scope, replies in
                await replies.holdNext()
                clock.advance(180)
                let refresh = Task { _ = try? await model.rest.chats() }
                await replies.waitUntilHeld()

                model.serverBaseText = "https://foreign.test"
                await replies.release()
                _ = await refresh.value

                XCTAssertNil(try storage.load(scope.storageKey))
                XCTAssertEqual(peer.registrations.count, 1)
                XCTAssertTrue(peer.authRefreshes.isEmpty)
            }
        }

        func testServerCustodyRefreshKeepsCurrentSocketAuthorityUntilAcceptedAck() async throws {
            try await withServerCustodyModel(candidateSession: "fixture-session") {
                model, peer, storage, clock, scope, _ in
                let initial = try XCTUnwrap(peer.registrations.last)
                clock.advance(180)
                _ = try? await model.rest.chats()
                try await waitUntil { peer.authRefreshes.count == 1 }

                let refresh = try XCTUnwrap(peer.authRefreshes.first)
                XCTAssertEqual(refresh.socket, initial.socket)
                XCTAssertEqual(refresh.frame.payload["type"], .string("refresh_ui_auth"))
                XCTAssertEqual(peer.registrations.count, 1)
                let candidateToken = try XCTUnwrap(refresh.frame.payload["token"]?.stringValue)
                XCTAssertEqual(
                    try JSONDecoder().decode(ServerSession.self, from: XCTUnwrap(storage.load(scope.storageKey)))
                        .accessToken,
                    candidateToken)
                let state = model.uiAuthRefreshCredentialStateForTesting(matches: candidateToken)
                XCTAssertTrue(state.active)
                XCTAssertTrue(state.registered)
                XCTAssertTrue(model.connected)
            }
        }

        func testServerCustodyRefreshAcceptsSameStillValidJWTWithoutAnAuthFrame() async throws {
            try await withServerCustodyModel(candidateSession: "fixture-session", reuseAccessToken: true) {
                model, peer, storage, clock, scope, _ in
                let initial = try XCTUnwrap(peer.registrations.last)
                clock.advance(5)
                _ = try? await model.rest.chats()

                let persisted = try JSONDecoder().decode(
                    ServerSession.self, from: XCTUnwrap(storage.load(scope.storageKey)))
                XCTAssertEqual(persisted.accessToken, initial.token)
                XCTAssertTrue(peer.authRefreshes.isEmpty)
                XCTAssertEqual(peer.registrations.count, 1)
                let state = model.uiAuthRefreshCredentialStateForTesting(matches: initial.token)
                XCTAssertTrue(state.active)
                XCTAssertTrue(state.registered)
            }
        }

        func testServerCustodyTimerReschedulesAfterSameJWTThenRenewsOnCurrentSocket() async throws {
            let timer = ControlledCredentialSleeper()
            let sleeper: @Sendable (UInt64) async -> Void = { await timer.sleep($0) }
            try await withServerCustodyModel(
                candidateSession: "fixture-session", reuseAccessToken: true,
                additionalReplyTokens: [
                    serverCustodyJWT(
                        issuer: "https://issuer.example.test", clientID: AstralConfig.macosClientId,
                        session: "fixture-session", expiry: Date().addingTimeInterval(7_200), marker: "later")
                ],
                uiAuthRefreshSleeper: sleeper
            ) { model, peer, _, clock, _, _ in
                let initial = try XCTUnwrap(peer.registrations.last)
                await timer.waitUntilScheduled(1)
                clock.advance(80)
                await timer.fireNext()
                await timer.waitUntilScheduled(2)

                XCTAssertTrue(peer.authRefreshes.isEmpty)
                XCTAssertEqual(peer.registrations.count, 1)
                let unchangedState = model.uiAuthRefreshCredentialStateForTesting(matches: initial.token)
                XCTAssertTrue(unchangedState.active)
                XCTAssertTrue(unchangedState.registered)

                clock.advance(45)
                await timer.fireNext()
                try await waitUntil { peer.authRefreshes.count == 1 }

                let refresh = try XCTUnwrap(peer.authRefreshes.first)
                XCTAssertEqual(refresh.socket, initial.socket)
                XCTAssertEqual(refresh.frame.payload["connection_generation"], initial.generation.map(JSONValue.string))
                XCTAssertEqual(peer.registrations.count, 1)
                let freshToken = try XCTUnwrap(refresh.frame.payload["token"]?.stringValue)
                let updatedState = model.uiAuthRefreshCredentialStateForTesting(matches: freshToken)
                XCTAssertTrue(updatedState.active)
                XCTAssertTrue(updatedState.registered)
                XCTAssertTrue(model.connected)
            }
        }

        func testServerCustodyRefreshRefusalDoesNotReplaceCurrentSocketRegistration() async throws {
            try await withServerCustodyModel(candidateSession: "fixture-session") {
                model, peer, _, clock, _, _ in
                peer.configureAuthRefreshAck(.refused)
                let initial = try XCTUnwrap(peer.registrations.last)
                clock.advance(180)
                _ = try? await model.rest.chats()
                try await waitUntil { peer.authRefreshes.count == 1 }

                XCTAssertEqual(peer.authRefreshes.first?.socket, initial.socket)
                XCTAssertEqual(peer.registrations.count, 1)
                let state = model.uiAuthRefreshCredentialStateForTesting(matches: initial.token)
                XCTAssertTrue(state.active)
                XCTAssertTrue(state.registered)
                XCTAssertTrue(model.signedIn)
            }
        }

        func testServerCustodyTimeoutKeepsCurrentSocketAndTokenBeforeAndAfterAckWait() async throws {
            try await withServerCustodyModel(candidateSession: "fixture-session") {
                model, peer, storage, clock, scope, _ in
                peer.configureAuthRefreshAck(.omitted)
                model.uiAuthRefreshAcknowledgementTimeoutNanoseconds = 500_000_000
                let initial = try XCTUnwrap(peer.registrations.last)
                clock.advance(180)
                let refresh = Task { _ = try? await model.rest.chats() }
                try await waitUntil { peer.authRefreshes.count == 1 }

                let candidate = try JSONDecoder().decode(
                    ServerSession.self, from: XCTUnwrap(storage.load(scope.storageKey)))
                XCTAssertEqual(candidate.accessToken, peer.authRefreshes.first?.frame.payload["token"]?.stringValue)
                let stateBeforeAck = model.uiAuthRefreshCredentialStateForTesting(matches: initial.token)
                XCTAssertTrue(stateBeforeAck.active)
                XCTAssertTrue(stateBeforeAck.registered)
                XCTAssertEqual(peer.registrations.count, 1)

                _ = await refresh.value
                let stateAfterTimeout = model.uiAuthRefreshCredentialStateForTesting(matches: initial.token)
                XCTAssertTrue(stateAfterTimeout.active)
                XCTAssertTrue(stateAfterTimeout.registered)
                XCTAssertEqual(peer.registrations.count, 1)
                XCTAssertTrue(model.signedIn)
            }
        }

        func testServerCustodyAfterAckTimeoutStillChecksCandidateAgainstActiveSocketIdentity() async throws {
            try await withServerCustodyModel(candidateSession: "fixture-session") {
                model, peer, storage, clock, scope, replies in
                peer.configureAuthRefreshAck(.omitted)
                model.uiAuthRefreshAcknowledgementTimeoutNanoseconds = 100_000_000
                let initial = try XCTUnwrap(peer.registrations.last)
                clock.advance(180)
                let refresh = Task { _ = try? await model.rest.chats() }
                try await waitUntil { peer.authRefreshes.count == 1 }
                _ = await refresh.value

                let persistedCandidate = try JSONDecoder().decode(
                    ServerSession.self, from: XCTUnwrap(storage.load(scope.storageKey)))
                let initialState = model.uiAuthRefreshCredentialStateForTesting(matches: initial.token)
                XCTAssertTrue(initialState.active)
                XCTAssertTrue(initialState.registered)

                let changedIdentity = serverCustodyJWT(
                    issuer: scope.issuer, clientID: model.clientId, session: "different-session",
                    expiry: clock.now.addingTimeInterval(7200), marker: "next-candidate")
                await replies.append(changedIdentity)
                clock.advance(7200)
                _ = try? await model.rest.chats()

                let afterRejectedRefresh = try JSONDecoder().decode(
                    ServerSession.self, from: XCTUnwrap(storage.load(scope.storageKey)))
                XCTAssertEqual(afterRejectedRefresh.accessToken, persistedCandidate.accessToken)
                let finalState = model.uiAuthRefreshCredentialStateForTesting(matches: initial.token)
                XCTAssertTrue(finalState.active)
                XCTAssertTrue(finalState.registered)
                XCTAssertEqual(peer.authRefreshes.count, 1)
                XCTAssertEqual(peer.registrations.count, 1)
            }
        }

        func testComputerDenialWireTracksTheActualRegistrationAcrossCredentialRenewal() async throws {
            try await withModel { model, peer, _, clock in
                XCTAssertFalse(model.macComputerHost.available)
                var replies: [JSONValue] = []
                for index in 0..<2 {
                    if index == 1 {
                        clock.advance(7200)
                        let registered = peer.expectRegistration()
                        _ = try await model.rest.chats()
                        await fulfillment(of: [registered], timeout: 10)
                        try await waitUntil { model.connected }
                    }
                    let current = try XCTUnwrap(peer.registrations.last)
                    let generation = try XCTUnwrap(current.generation)
                    let request = "creq_" + String(repeating: index == 0 ? "c" : "d", count: 32)
                    let frame = JSONValue.object([
                        "type": .string("computer_request"), "request_id": .string(request),
                        "session_id": .string("22222222-2222-4222-8222-222222222222"),
                        "verb": .string("screenshot"), "args": .object([:]), "deadline_ms": .number(1000),
                    ])
                    peer.send(String(decoding: try frame.encoded(), as: UTF8.self), socket: current.socket)
                    try await waitUntil {
                        peer.events.contains { $0.frame.payload["payload"]?["request_id"] == .string(request) }
                    }
                    let event = try XCTUnwrap(
                        peer.events.first {
                            $0.frame.payload["payload"]?["request_id"] == .string(request)
                        })
                    let reply = event.frame.payload
                    XCTAssertEqual(event.socket, current.socket)
                    XCTAssertTrue(
                        ComputerHostOutbound.isBound(
                            String(decoding: try reply.encoded(), as: UTF8.self), connectionGeneration: generation))
                    XCTAssertEqual(reply["action"], .string("computer_response"))
                    XCTAssertEqual(reply["payload"]?["ok"], .bool(false))
                    XCTAssertEqual(reply["payload"]?["error"]?["code"], .string("permission_denied"))
                    replies.append(reply)
                }
                XCTAssertNotEqual(replies[0]["connection_generation"], replies[1]["connection_generation"])
                XCTAssertNotEqual(replies[0]["submission_id"], replies[1]["submission_id"])
                XCTAssertNotEqual(replies[0]["request_generation"], replies[1]["request_generation"])
            }
        }
    #endif

    func testEvidenceRenewalRetiresOriginalReadAndOnlyManualRetryUsesFreshRegisteredSocket() async throws {
        for params: JSONValue in [
            .object([:]), .object(["kind": .string("usage")]),
            .object(["kind": .string("source"), "reference": .string("obs_" + String(repeating: "a", count: 43))]),
        ] {
            try await withModel { model, peer, _, clock in
                clock.advance(7200)
                peer.holdRefresh()
                let requested = peer.expectRefresh()
                let registered = peer.expectRegistration()
                var original: String?
                model.outboundTap = { text in
                    if original == nil, let frame = InboundFrame.parse(text),
                        frame.payload["payload"]?["surface"]?.stringValue == "evidence"
                    {
                        original = frame.payload["request_generation"]?.stringValue
                    }
                }
                model.openSurface("evidence", params: params)
                await fulfillment(of: [requested], timeout: 10)
                XCTAssertTrue(peer.events.isEmpty)
                peer.releaseRefresh()
                await fulfillment(of: [registered], timeout: 10)
                try await waitUntil { model.connected }
                XCTAssertNil(model.pendingSurface)
                XCTAssertNil(model.evidenceReadGeneration)
                XCTAssertTrue(peer.events.isEmpty)
                model.openSurface("evidence", params: params)
                try await waitUntil { peer.events.count == 1 }
                let read = try XCTUnwrap(peer.events.first)
                let generation = try XCTUnwrap(read.frame.payload["request_generation"]?.stringValue)
                XCTAssertNotEqual(generation, original)
                XCTAssertEqual(read.socket, peer.registrations.last?.socket)
                XCTAssertEqual(read.frame.payload["session_id"], .null)
                XCTAssertEqual(
                    Set(read.frame.payload["payload"]!.objectValue!.keys),
                    ["surface", "params", "submission_id", "request_generation"])
                XCTAssertEqual(read.frame.payload["payload"]?["params"], params)
                var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                var fixture: JSONValue?
                for _ in 0..<8 {
                    let path = root.appendingPathComponent("contracts/fixtures/evidence/inspection_surface.json")
                    if FileManager.default.fileExists(atPath: path.path) {
                        fixture = try JSONValue.parse(Data(contentsOf: path))
                        break
                    }
                    root.deleteLastPathComponent()
                }
                var fields = try XCTUnwrap(fixture?["native_frame"]?.objectValue)
                fields["request_generation"] = .string(try XCTUnwrap(original))
                model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(fields)))
                XCTAssertNil(model.pendingSurface)
                fields["request_generation"] = .string(generation)
                peer.send(
                    String(decoding: try JSONEncoder().encode(JSONValue.object(fields)), as: UTF8.self),
                    socket: read.socket)
                try await waitUntil { model.pendingSurface != nil }
                XCTAssertEqual(
                    model.pendingSurface?.components.first { $0.type == "keyvalue" }?.keyValuePairs.first?.1,
                    fixture?["source_text"]?.stringValue)
                XCTAssertEqual(peer.events.count, 1)
            }
        }
    }

    func testTerminalReadsRetireOnCredentialRotationAndUseOnlyTheCurrentSocket() async throws {
        for params: JSONValue in [
            .object(["mode": .string("list")]),
            .object(["mode": .string("monitor"), "session_id": .string("term_fixture")]),
        ] {
            try await withModel { model, peer, _, clock in
                model.openSurface("terminal", params: params)
                try await waitUntil { peer.events.count == 1 }
                let original = try XCTUnwrap(peer.events[0].frame.payload["request_generation"]?.stringValue)
                var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                var fixture: JSONValue?
                for _ in 0..<8 {
                    let path = root.appendingPathComponent("contracts/fixtures/terminal/monitor_surface.json")
                    if FileManager.default.fileExists(atPath: path.path) {
                        fixture = try JSONValue.parse(Data(contentsOf: path))
                        break
                    }
                    root.deleteLastPathComponent()
                }
                var fields = try XCTUnwrap(fixture?["native_frame"]?.objectValue)
                fields["request_generation"] = .string(original)
                model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(fields)))
                XCTAssertNotNil(model.pendingSurface)
                clock.advance(7200)
                peer.holdRefresh()
                let requested = peer.expectRefresh()
                let registered = peer.expectRegistration()
                model.retryPendingSurface()
                XCTAssertNil(model.pendingSurface)
                await fulfillment(of: [requested], timeout: 10)
                peer.releaseRefresh()
                await fulfillment(of: [registered], timeout: 10)
                try await waitUntil { model.connected }
                XCTAssertNil(model.pendingSurface)
                XCTAssertNil(model.terminalReadGeneration)
                XCTAssertEqual(peer.events.count, 1)
                model.openSurface("terminal", params: params)
                try await waitUntil { peer.events.count == 2 }
                let read = peer.events[1]
                XCTAssertEqual(read.socket, peer.registrations.last?.socket)
                let generation = try XCTUnwrap(read.frame.payload["request_generation"]?.stringValue)
                XCTAssertNotEqual(generation, original)
                model.handleFrame(InboundFrame(name: "chrome_surface", payload: .object(fields)))
                XCTAssertNil(model.pendingSurface)
                fields["request_generation"] = .string(generation)
                peer.send(
                    String(decoding: try JSONEncoder().encode(JSONValue.object(fields)), as: UTF8.self),
                    socket: read.socket)
                try await waitUntil { model.pendingSurface != nil }
                XCTAssertEqual(peer.events.count, 2)
            }
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

    func testQueryAfterExpiryRenewsTheSocketAndIsSentOnceOnTheRenewedConnection() async throws {
        try await withModel { model, peer, _, clock in
            clock.advance(7200)
            let registered = peer.expectRegistration()
            model.sendChat("Sent after the idle renewal")
            model.composerDraft = ""
            await fulfillment(of: [registered], timeout: 10)
            try await waitUntil { peer.events.contains { $0.frame.payload["action"] == .string("chat_message") } }
            let renewed = try XCTUnwrap(peer.registrations.last)
            let sent = peer.events.filter { $0.frame.payload["action"] == .string("chat_message") }
            XCTAssertEqual(sent.count, 1)
            XCTAssertEqual(sent.first?.socket, renewed.socket)
            XCTAssertEqual(sent.first?.frame.payload["payload"]?["message"], .string("Sent after the idle renewal"))
            XCTAssertEqual(peer.registrations.count, 2)
            XCTAssertEqual(model.composerDraft, "")
            XCTAssertNil(model.errorBanner)
            XCTAssertTrue(model.turnActive)
        }
    }

    func testExpiredCredentialRefreshesInPlaceWithoutRetiringAnActiveLongTurn() async throws {
        try await withModel(jwtLifetime: 120, uiAuthRefreshSupported: true) { model, peer, store, clock in
            let initial = try XCTUnwrap(peer.registrations.last)
            XCTAssertTrue(initial.capabilities.contains("ui_auth_refresh_v1"))

            model.sendChat("Keep this long-running turn connected")
            try await waitUntil {
                peer.events.contains { $0.frame.payload["action"] == .string("chat_message") }
            }
            clock.advance(180)

            _ = try await model.rest.chats()

            try await waitUntil { peer.authRefreshes.count == 1 }
            let refreshed = try XCTUnwrap(peer.authRefreshes.first)
            XCTAssertEqual(refreshed.socket, initial.socket)
            XCTAssertEqual(
                refreshed.frame.payload["connection_generation"], .string(try XCTUnwrap(initial.generation)))
            XCTAssertEqual(refreshed.frame.payload["token"]?.stringValue, store.load()?.accessToken)
            XCTAssertEqual(peer.registrations.count, 1)
            XCTAssertTrue(model.turnActive)
            XCTAssertEqual(
                peer.events.filter { $0.frame.payload["action"] == .string("chat_message") }.count, 1)
        }
    }

    func testExpiryTimerRefreshesBeforeDeadlineOnTheExistingSocket() async throws {
        try await withModel(
            jwtLifetime: 120, uiAuthRefreshSupported: true,
            advanceCredentialClockWhenTimerFires: 60
        ) { model, peer, store, _ in
            let initial = try XCTUnwrap(peer.registrations.last)
            try await waitUntil { peer.authRefreshes.count == 1 && store.load()?.accessToken != initial.token }
            XCTAssertEqual(peer.registrations.count, 1)
            XCTAssertEqual(peer.authRefreshes.first?.socket, initial.socket)
            XCTAssertNil(model.errorBanner)
        }
    }

    func testAuthRequiredRenewsTheBoundSocketWithoutReplayingAnActiveTurn() async throws {
        try await withModel(jwtLifetime: 3600, uiAuthRefreshSupported: true) { model, peer, store, _ in
            let initial = try XCTUnwrap(peer.registrations.last)
            model.sendChat("Continue while the server renews this session")
            try await waitUntil {
                peer.events.contains { $0.frame.payload["action"] == .string("chat_message") }
            }
            peer.send(#"{"type":"auth_required","reason":"expired"}"#, socket: initial.socket)

            try await waitUntil { peer.authRefreshes.count == 1 && store.load()?.accessToken != initial.token }
            XCTAssertEqual(peer.registrations.count, 1)
            XCTAssertEqual(peer.authRefreshes.first?.socket, initial.socket)
            XCTAssertTrue(model.turnActive)
            XCTAssertEqual(
                peer.events.filter { $0.frame.payload["action"] == .string("chat_message") }.count, 1)
        }
    }

    func testRESTAndAuthRequiredShareOneInPlaceRefreshForAnActiveTurn() async throws {
        try await withModel(uiAuthRefreshSupported: true) { model, peer, store, clock in
            let initial = try XCTUnwrap(peer.registrations.last)
            model.sendChat("Keep the same active turn during a shared refresh")
            try await waitUntil {
                peer.events.contains { $0.frame.payload["action"] == .string("chat_message") }
            }
            clock.advance(7200)
            peer.holdRefresh()
            let refreshRequest = peer.expectRefresh()
            let restRead = Task { try? await model.rest.chats() }
            await fulfillment(of: [refreshRequest], timeout: 10)
            peer.send(#"{"type":"auth_required","reason":"expired"}"#, socket: initial.socket)
            try await Task.sleep(nanoseconds: 20_000_000)
            peer.releaseRefresh()

            try await waitUntil { peer.authRefreshes.count == 1 && store.load()?.accessToken != initial.token }
            _ = await restRead.value
            XCTAssertEqual(peer.refreshCount, 1)
            XCTAssertEqual(peer.registrations.count, 1)
            XCTAssertEqual(peer.authRefreshes.first?.socket, initial.socket)
            XCTAssertTrue(model.turnActive)
            XCTAssertEqual(
                peer.events.filter { $0.frame.payload["action"] == .string("chat_message") }.count, 1)
        }
    }

    func testUncorrelatedRefreshAcknowledgementTimesOutWithoutInstallingOrReconnecting() async throws {
        try await withModel(jwtLifetime: 120, uiAuthRefreshSupported: true) { model, peer, store, clock in
            model.uiAuthRefreshAcknowledgementTimeoutNanoseconds = 10_000_000
            peer.configureAuthRefreshAck(.wrongRequest)
            let initial = try XCTUnwrap(peer.registrations.last)
            clock.advance(180)
            let request = Task { try? await model.rest.chats() }
            try await waitUntil { peer.authRefreshes.count == 1 }
            try await waitUntil { model.surfaceFailureMessage != nil }
            XCTAssertEqual(peer.registrations.count, 1)
            XCTAssertEqual(store.load()?.accessToken, initial.token)
            XCTAssertNil(model.errorBanner)
            request.cancel()
        }
    }

    func testChangedStableSessionClaimDoesNotInstallCredentialOrSendRefreshFrame() async throws {
        try await withModel(jwtLifetime: 120, uiAuthRefreshSupported: true) { model, peer, store, clock in
            let initial = try XCTUnwrap(peer.registrations.last)
            peer.configureRefresh(status: 200, session: "different-session")
            clock.advance(180)
            let request = Task { try? await model.rest.chats() }
            try await waitUntil { model.surfaceFailureMessage != nil }
            XCTAssertTrue(peer.authRefreshes.isEmpty)
            XCTAssertEqual(peer.registrations.count, 1)
            XCTAssertEqual(store.load()?.accessToken, initial.token)
            request.cancel()
        }
    }

    func testRefreshedCredentialWithoutAStableSessionClaimIsNotInstalled() async throws {
        try await withModel(jwtLifetime: 120, uiAuthRefreshSupported: true) { model, peer, store, clock in
            let initial = try XCTUnwrap(peer.registrations.last)
            peer.configureRefresh(status: 200, includeSessionClaim: false)
            clock.advance(180)
            let request = Task { try? await model.rest.chats() }
            try await waitUntil { model.surfaceFailureMessage != nil }
            XCTAssertTrue(peer.authRefreshes.isEmpty)
            XCTAssertEqual(peer.registrations.count, 1)
            XCTAssertEqual(store.load()?.accessToken, initial.token)
            request.cancel()
        }
    }

    func testRefreshRefusalClosesTheSessionWithoutReplayingTheActiveQuery() async throws {
        try await withModel(uiAuthRefreshSupported: true) { model, peer, store, _ in
            let initial = try XCTUnwrap(peer.registrations.last)
            model.sendChat("Do not replay after an auth refusal")
            try await waitUntil {
                peer.events.contains { $0.frame.payload["action"] == .string("chat_message") }
            }
            peer.configureAuthRefreshAck(.refused)
            peer.send(#"{"type":"auth_required","reason":"expired"}"#, socket: initial.socket)

            try await waitUntil { !model.signedIn }
            XCTAssertEqual(peer.registrations.count, 1)
            XCTAssertNil(store.load())
            XCTAssertEqual(
                peer.events.filter { $0.frame.payload["action"] == .string("chat_message") }.count, 1)
        }
    }

    func testLogoutCancelsPendingSameSocketCredentialAcknowledgement() async throws {
        try await withModel(jwtLifetime: 120, uiAuthRefreshSupported: true) { model, peer, store, clock in
            peer.configureAuthRefreshAck(.omitted)
            clock.advance(180)
            let request = Task { _ = try? await model.rest.chats() }
            try await waitUntil { peer.authRefreshes.count == 1 }
            await model.signOut(revokeRemote: false)
            _ = await request.value

            XCTAssertFalse(model.signedIn)
            XCTAssertNil(store.load())
            XCTAssertEqual(peer.registrations.count, 1)
        }
    }

    func testDisconnectCancelsPendingSameSocketCredentialAcknowledgement() async throws {
        try await withModel(jwtLifetime: 120, uiAuthRefreshSupported: true) { model, peer, store, clock in
            peer.configureAuthRefreshAck(.omitted)
            clock.advance(180)
            let initial = try XCTUnwrap(peer.registrations.last)
            let request = Task { try? await model.rest.chats() }
            try await waitUntil { peer.authRefreshes.count == 1 }
            peer.disconnect(socket: initial.socket)
            try await waitUntil { model.surfaceFailureMessage != nil }
            XCTAssertEqual(store.load()?.accessToken, initial.token)
            XCTAssertEqual(peer.authRefreshes.count, 1)
            request.cancel()
        }
    }

    func testStaleSocketIsReplacedBeforeSendingAndTheQueryArrivesOnce() async throws {
        try await withModel(liveness: LivenessPolicy(interval: 3600, timeout: 0.5, freshness: 0)) {
            model, peer, _, _ in
            let original = try XCTUnwrap(peer.registrations.last).socket
            peer.silence(socket: original)
            let registered = peer.expectRegistration()
            model.sendChat("Sent after the socket went quiet")
            await fulfillment(of: [registered], timeout: 10)
            try await waitUntil { peer.events.contains { $0.frame.payload["action"] == .string("chat_message") } }
            let sent = peer.events.filter { $0.frame.payload["action"] == .string("chat_message") }
            XCTAssertEqual(sent.count, 1)
            XCTAssertNotEqual(sent.first?.socket, original)
            XCTAssertEqual(sent.first?.socket, peer.registrations.last?.socket)
            XCTAssertNil(model.errorBanner)
            XCTAssertEqual(model.composerDraft, "")
            try await waitUntil { model.connected }
        }
    }

    func testIdleKeepaliveShowsTheTrueStateAndReconnectsWithoutASend() async throws {
        try await withModel(liveness: LivenessPolicy(interval: 0.2, timeout: 0.3, freshness: 0.1)) {
            model, peer, _, _ in
            let original = try XCTUnwrap(peer.registrations.last).socket
            let registered = peer.expectRegistration()
            peer.silence(socket: original)
            try await waitUntil { !model.connected }
            await fulfillment(of: [registered], timeout: 10)
            try await waitUntil { model.connected }
            XCTAssertNotEqual(peer.registrations.last?.socket, original)
            XCTAssertFalse(peer.events.contains { $0.socket == original })
            XCTAssertNil(model.errorBanner)
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

private actor ServerCustodyRefreshReplies {
    private var tokens: [String]
    private var consumed = 0
    private var heldIndex: Int?
    private var currentlyHeld = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    init(tokens: [String]) { self.tokens = tokens }
    func append(_ token: String) { tokens.append(token) }
    func holdNext() { heldIndex = consumed }
    func next() async -> String {
        let index = consumed
        consumed += 1
        precondition(!tokens.isEmpty, "unexpected server custody refresh")
        let token = tokens.removeFirst()
        if heldIndex == index {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
                currentlyHeld = true
                for waiter in heldWaiters { waiter.resume() }
                heldWaiters.removeAll()
            }
        }
        return token
    }
    func waitUntilHeld() async {
        if currentlyHeld { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }
    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor ControlledCredentialSleeper {
    private var scheduled: [UInt64] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(_ nanoseconds: UInt64) async {
        await withCheckedContinuation { continuation in
            scheduled.append(nanoseconds)
            continuations.append(continuation)
            let ready = waiters.filter { $0.0 <= scheduled.count }
            waiters.removeAll { $0.0 <= scheduled.count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitUntilScheduled(_ count: Int) async {
        if scheduled.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func fireNext() {
        precondition(!continuations.isEmpty, "no scheduled credential timer")
        continuations.removeFirst().resume()
    }
}

private final class SocketAuthenticationPeer: @unchecked Sendable {
    enum AuthRefreshAckBehavior: Equatable {
        case accepted
        case wrongRequest
        case wrongGeneration
        case refused
        case omitted
    }
    struct Registration {
        let socket: Int
        let token: String
        let generation: String?
        let capabilities: Set<String>
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
    private var observedAuthRefreshes: [Event] = []
    private var observedRefreshes = 0
    private var observedAuthorization: [String] = []
    private var registrationExpectation: XCTestExpectation?
    private var refreshExpectation: XCTestExpectation?
    private var holdsRefresh = false
    private var pendingRefresh: [Connection] = []
    private var refreshStatus = 200
    private var refreshedSubject = "owner"
    private var refreshedSession = "fixture-session"
    private var refreshLifetime: TimeInterval = 86400
    private var includeSessionClaim = true
    private var silenced: Set<Int> = []
    var uiAuthRefreshSupported = false
    private var authRefreshAckBehavior = AuthRefreshAckBehavior.accepted

    init(clock: CredentialTestClock, jwtLifetime: TimeInterval = 3600) throws {
        self.clock = clock
        originalToken = Self.token(
            "original", subject: "owner", session: "fixture-session",
            expiry: clock.now.addingTimeInterval(jwtLifetime))
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    private static func token(_ marker: String, subject: String, session: String?, expiry: Date) -> String {
        var payload: [String: Any] = [
            "iss": "https://issuer.example.test", "sub": subject, "azp": "astral-desktop",
            "scope": "openid profile", "jti": marker, "iat": expiry.timeIntervalSince1970 - 3600,
            "exp": expiry.timeIntervalSince1970,
        ]
        if let session { payload["sid"] = session }
        return "fixture." + PKCE.base64url(try! JSONSerialization.data(withJSONObject: payload)) + ".fixture"
    }

    var registrations: [Registration] { queue.sync { observedRegistrations } }
    var events: [Event] { queue.sync { observedEvents } }
    var authRefreshes: [Event] { queue.sync { observedAuthRefreshes } }
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
    func configureAuthRefreshAck(_ behavior: AuthRefreshAckBehavior) {
        queue.sync { authRefreshAckBehavior = behavior }
    }
    func configureRefresh(
        status: Int, subject: String = "owner", session: String = "fixture-session", lifetime: TimeInterval = 86400,
        includeSessionClaim: Bool = true
    ) {
        queue.sync {
            refreshStatus = status
            refreshedSubject = subject
            refreshedSession = session
            refreshLifetime = lifetime
            self.includeSessionClaim = includeSessionClaim
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
            session: includeSessionClaim ? refreshedSession : nil,
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
            if silenced.contains(connection.socket) { continue }
            if opcode == 8 {
                connection.network.cancel()
                return
            }
            if opcode == 9 {
                write(Data(body), opcode: 10, to: connection)
                continue
            }
            guard opcode == 1, let text = String(bytes: body, encoding: .utf8), let frame = InboundFrame.parse(text)
            else { continue }
            if frame.name == "register_ui" {
                let capabilities = Set(frame.payload["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                observedRegistrations.append(
                    Registration(
                        socket: connection.socket, token: frame.payload["token"]?.stringValue ?? "",
                        generation: frame.payload["connection_generation"]?.stringValue,
                        capabilities: capabilities))
                registrationExpectation?.fulfill()
                registrationExpectation = nil
                send(#"{"type":"ready"}"#, to: connection)
                #if os(macOS)
                    send(
                        #"{"type":"rote_config","device_profile":{"device_type":"macos","console":{}}}"#,
                        to: connection)
                #endif
                if self.uiAuthRefreshSupported, capabilities.contains("ui_auth_refresh_v1"),
                    let generation = frame.payload["connection_generation"]?.stringValue
                {
                    send(
                        String(
                            decoding: try! JSONValue.object([
                                "type": .string("ui_auth_refresh_ready"),
                                "connection_generation": .string(generation),
                            ]).encoded(), as: UTF8.self),
                        to: connection)
                }
            } else if frame.name == "refresh_ui_auth" {
                observedAuthRefreshes.append(Event(socket: connection.socket, frame: frame))
                guard authRefreshAckBehavior != .omitted else { continue }
                var ackFields: [String: JSONValue] = [
                    "type": .string("ui_auth_refreshed"),
                    "request_id": frame.payload["request_id"] ?? .null,
                    "connection_generation": frame.payload["connection_generation"] ?? .null,
                    "accepted": .bool(authRefreshAckBehavior != .refused),
                ]
                if authRefreshAckBehavior == .wrongRequest {
                    ackFields["request_id"] = .string("55555555-5555-4555-8555-555555555555")
                } else if authRefreshAckBehavior == .wrongGeneration {
                    ackFields["connection_generation"] = .string("66666666-6666-4666-8666-666666666666")
                } else if authRefreshAckBehavior == .refused {
                    ackFields["closed_code"] = .string("identity_changed")
                }
                let ack = JSONValue.object(ackFields)
                send(String(decoding: try! ack.encoded(), as: UTF8.self), to: connection)
            } else {
                observedEvents.append(Event(socket: connection.socket, frame: frame))
            }
        }
    }

    private func send(_ text: String, to connection: Connection) {
        write(Data(text.utf8), opcode: 1, to: connection)
    }

    private func write(_ content: Data, opcode: UInt8, to connection: Connection) {
        var header = Data([128 | opcode])
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

    func silence(socket: Int) {
        queue.sync { _ = silenced.insert(socket) }
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

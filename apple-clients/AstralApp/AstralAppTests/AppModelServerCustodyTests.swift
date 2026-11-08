// Verifies protected server-session restoration cannot publish before real cookie authentication.
// Held refreshes and foreign identities exercise account/server retirement without provider network calls.

import AstralCore
import Foundation
import XCTest

@testable import AstralDeep

@MainActor final class AppModelServerCustodyTests: XCTestCase {
    private func model() throws -> (AppModel, InMemoryMeshKeyStorage, ServerSession) {
        let suite = "AppModelServerCustodyTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://server.test", forKey: "serverBase")
        defaults.set("https://iam.test/realms/astral", forKey: "authority")
        let model = AppModel(tokenStore: InMemoryTokenStore(), defaults: defaults)
        let scope = try ServerSessionScope(
            server: URL(string: "https://server.test")!,
            oidc: OIDCConfig(
                authority: URL(string: "https://iam.test/realms/astral")!, clientId: model.clientId,
                redirectURI: "com.personalailabs.astraldeep:/oauth2redirect"))
        let claims: JSONValue = .object([
            "iss": .string(scope.issuer), "sub": .string("owner"),
            "azp": .string(scope.clientID), "exp": .number(Date().addingTimeInterval(3600).timeIntervalSince1970),
        ])
        let access = "e30." + PKCE.base64url(try claims.encoded()) + ".c2ln"
        let session = try ServerSession(
            scope: scope, owner: "owner", accessToken: access,
            cookie: "astral_session=synthetic", cookieExpiresAt: Date().addingTimeInterval(3600))
        let storage = InMemoryMeshKeyStorage()
        try storage.save(JSONEncoder().encode(session), key: scope.storageKey)
        model.serverSessionStorage = storage
        return (model, storage, session)
    }

    func testHeldRestoreCannotPublishOrRestoreAfterSignOutOrServerChange() async throws {
        for change in ["signout", "server"] {
            let (model, storage, session) = try model()
            let entered = expectation(description: "real cookie authentication")
            let retired = change == "server" ? expectation(description: "old scoped cookie retirement") : nil
            let gate = Gate()
            model.serverSessionTransport = { request in
                if request.httpMethod == "POST" {
                    XCTAssertEqual(request.url?.absoluteString, "https://server.test/api/auth/logout")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), session.cookie)
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + session.accessToken)
                    if let retired { retired.fulfill() } else { XCTFail("local-only sign-out cannot revoke remotely") }
                    return ServerSessionReply(
                        body: .object(["outcome": .string("revoked"), "revoked": .bool(true), "queued": .bool(false)]))
                }
                XCTAssertEqual(request.url?.path, "/auth/session")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), session.cookie)
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                entered.fulfill()
                await gate.wait()
                return ServerSessionReply(
                    body: .object([
                        "authenticated": .bool(true),
                        "access_token": .string(session.accessToken), "resumed": .bool(true),
                        "user_id": .string("owner"),
                    ]))
            }
            let restore = Task { await model.bootstrap() }
            await fulfillment(of: [entered], timeout: 5)
            XCTAssertFalse(model.signedIn)
            XCTAssertFalse(model.connected)
            model.sendEvent("chrome_mesh_identity")
            XCTAssertNil(model.meshPublicIdentity)
            if change == "server" {
                model.serverBaseText = "https://foreign.test"
                await fulfillment(of: [retired!], timeout: 5)
            } else {
                await model.signOut(revokeRemote: false)
            }
            await gate.release()
            await restore.value
            XCTAssertFalse(model.signedIn)
            XCTAssertFalse(model.connected)
            XCTAssertNil(try storage.load(session.scope.storageKey))
        }
    }

    func testForeignCookieIdentityRefusesRestoreBeforeSocketCreation() async throws {
        let (model, storage, session) = try model()
        model.serverSessionTransport = { _ in
            ServerSessionReply(
                body: .object([
                    "authenticated": .bool(true), "access_token": .string(session.accessToken),
                    "resumed": .bool(true), "user_id": .string("foreign"),
                ]))
        }
        await model.bootstrap()
        XCTAssertFalse(model.signedIn)
        XCTAssertFalse(model.connected)
        XCTAssertNotNil(model.signInError)
        XCTAssertNil(try storage.load(session.scope.storageKey))
    }

    func testLaunchWithoutTheServerKeepsTheSessionAndResumesWhenItReturns() async throws {
        let (model, storage, session) = try model()
        model.serverSessionRetryBackoff = BackoffPolicy(base: 0.05, factor: 2, cap: 0.05)
        let server = RestoreServer()
        let reply = restoredReply(session)
        model.serverSessionTransport = { _ in
            guard await server.answer() else { throw ServerSessionError.unavailable }
            return reply
        }
        await model.bootstrap()
        XCTAssertTrue(model.signedIn)
        XCTAssertNil(model.signInError)
        XCTAssertNotNil(try storage.load(session.scope.storageKey))
        await model.signOut(revokeRemote: false)
    }

    func testServerStaysAwayWithoutPublishingOrLosingTheSession() async throws {
        let (model, storage, session) = try model()
        model.serverSessionRetryBackoff = BackoffPolicy(base: 60, factor: 2, cap: 60)
        let attempted = expectation(description: "restore attempt")
        model.serverSessionTransport = { _ in
            attempted.fulfill()
            throw ServerSessionError.unavailable
        }
        let restore = Task { await model.bootstrap() }
        await fulfillment(of: [attempted], timeout: 5)
        for _ in 0..<100 where model.signInError == nil { await Task.yield() }

        XCTAssertFalse(model.signedIn)
        XCTAssertFalse(model.connected)
        XCTAssertEqual(model.signInError, "The server can't be reached. Your sign-in is saved. Retrying…")
        XCTAssertNotNil(try storage.load(session.scope.storageKey))
        restore.cancel()
        await restore.value
    }

    func testUnavailableThenRejectedAtLaunchStillDeletesTheSession() async throws {
        for answer in ["401", "unauthenticated"] {
            let (model, storage, session) = try model()
            model.serverSessionRetryBackoff = BackoffPolicy(base: 0.05, factor: 2, cap: 0.05)
            let server = RestoreServer()
            model.serverSessionTransport = { _ in
                guard await server.answer() else { throw ServerSessionError.unavailable }
                if answer == "401" { throw ServerSessionError.retired }
                return ServerSessionReply(body: .object(["authenticated": .bool(false)]))
            }
            await model.bootstrap()
            XCTAssertFalse(model.signedIn, answer)
            XCTAssertFalse(model.connected, answer)
            XCTAssertEqual(model.signInError, "The saved server session could not be resumed. Sign in again.", answer)
            XCTAssertNil(try storage.load(session.scope.storageKey), answer)
            let attempts = await server.attempts
            XCTAssertEqual(attempts, 2, answer)
        }
    }

    func testWindowsOpenedDuringARetryShareOneRestore() async throws {
        let (model, storage, session) = try model()
        model.serverSessionRetryBackoff = BackoffPolicy(base: 60, factor: 2, cap: 60)
        let server = RestoreServer(failures: .max)
        let attempted = expectation(description: "first restore attempt")
        let repeated = expectation(description: "another window starts its own restore")
        repeated.isInverted = true
        model.serverSessionTransport = { _ in
            _ = await server.answer()
            if await server.attempts == 1 { attempted.fulfill() } else { repeated.fulfill() }
            throw ServerSessionError.unavailable
        }
        let first = Task { await model.bootstrap() }
        await fulfillment(of: [attempted], timeout: 5)
        let second = Task { await model.bootstrap() }
        await fulfillment(of: [repeated], timeout: 0.5)
        XCTAssertFalse(model.signedIn)
        XCTAssertNotNil(try storage.load(session.scope.storageKey))
        second.cancel()
        first.cancel()
        await first.value
        await second.value
        let attempts = await server.attempts
        XCTAssertEqual(attempts, 1)
        XCTAssertNotNil(try storage.load(session.scope.storageKey))
    }

    func testClosingOneWindowKeepsTheSharedRestoreRunning() async throws {
        let (model, storage, session) = try model()
        model.serverSessionRetryBackoff = BackoffPolicy(base: 0.4, factor: 2, cap: 0.4)
        let server = RestoreServer()
        let reply = restoredReply(session)
        let attempted = expectation(description: "first restore attempt")
        model.serverSessionTransport = { _ in
            guard await server.answer() else {
                attempted.fulfill()
                throw ServerSessionError.unavailable
            }
            return reply
        }
        let closed = Task { await model.bootstrap() }
        let open = Task { await model.bootstrap() }
        await fulfillment(of: [attempted], timeout: 5)
        closed.cancel()
        await open.value
        await closed.value
        XCTAssertTrue(model.signedIn)
        XCTAssertNil(model.signInError)
        XCTAssertNotNil(try storage.load(session.scope.storageKey))
        let attempts = await server.attempts
        XCTAssertEqual(attempts, 2)
        await model.signOut(revokeRemote: false)
    }

    func testRestoreRetriesBackOffExponentiallyWithJitterUpToTheCap() throws {
        var backoff = BackoffPolicy(base: 2, factor: 2, cap: 60)
        let ceilings = (0..<7).map { _ in AppModel.serverSessionRetryDelay(&backoff, jitter: 1) }
        XCTAssertEqual(ceilings, [2, 4, 8, 16, 32, 60, 60].map { UInt64($0) * 1_000_000_000 })
        var halved = BackoffPolicy(base: 2, factor: 2, cap: 60)
        XCTAssertEqual(AppModel.serverSessionRetryDelay(&halved, jitter: 0.5), 1_000_000_000)
        let (model, _, _) = try model()
        var jittered = model.serverSessionRetryBackoff
        var ceiling = model.serverSessionRetryBackoff
        for _ in 0..<10 {
            let delay = AppModel.serverSessionRetryDelay(&jittered)
            let top = AppModel.serverSessionRetryDelay(&ceiling, jitter: 1)
            XCTAssertGreaterThanOrEqual(delay, top / 2)
            XCTAssertLessThanOrEqual(delay, top)
        }
        XCTAssertEqual(AppModel.serverSessionRetryDelay(&ceiling, jitter: 1), 60_000_000_000)
    }

    func testARetiredSessionIsStillDeletedAtLaunch() async throws {
        let (model, storage, session) = try model()
        model.serverSessionTransport = { _ in throw ServerSessionError.retired }
        await model.bootstrap()
        XCTAssertFalse(model.signedIn)
        XCTAssertEqual(model.signInError, "The saved server session could not be resumed. Sign in again.")
        XCTAssertNil(try storage.load(session.scope.storageKey))
    }

    func testRestoredOwnerPreservesProtectedKeyAndRetiresForeignScopes() async throws {
        let (model, _, session) = try model()
        let storage = InMemoryMeshKeyStorage()
        let account = ConversationAccount(issuer: session.scope.issuer, subject: session.owner)!
        let scope = try MeshEnrollmentScope(server: session.scope.server, account: account)
        let custody = MeshEnrollmentCustody(scope: scope, storage: storage)
        let identity = try custody.publicIdentity(current: { true })
        let raw = try XCTUnwrap(storage.load(scope.storageKey))
        let foreign = try MeshEnrollmentScope(server: URL(string: "https://foreign.test")!, account: account)
        try storage.save(raw, key: foreign.storageKey)
        model.meshKeyStorage = storage
        model.serverSessionTransport = { _ in
            ServerSessionReply(
                body: .object([
                    "authenticated": .bool(true), "access_token": .string(session.accessToken),
                    "resumed": .bool(true), "user_id": .string(session.owner),
                ]))
        }
        await model.bootstrap()
        XCTAssertTrue(model.signedIn)
        XCTAssertNotNil(try storage.load(scope.storageKey))
        XCTAssertNil(try storage.load(foreign.storageKey))
        XCTAssertEqual(try custody.publicIdentity(current: { true }), identity)
        model.bindConversationAccount(ConversationAccount(issuer: account.issuer, subject: "other")!)
        XCTAssertNil(try storage.load(scope.storageKey))
        await model.signOut(revokeRemote: false)
    }

    func testLogoutReportsQueuedAndUnconfirmedWithoutKeepingLocalAuthority() async throws {
        for outcome in ["revoked", "queued", "unconfirmed", "offline"] {
            let (model, storage, session) = try model()
            model.serverSessionTransport = { request in
                if request.httpMethod == "GET" {
                    return ServerSessionReply(
                        body: .object([
                            "authenticated": .bool(true), "access_token": .string(session.accessToken),
                            "resumed": .bool(true), "user_id": .string(session.owner),
                        ]))
                }
                if outcome == "offline" { throw ServerSessionError.unavailable }
                return ServerSessionReply(
                    body: .object([
                        "outcome": .string(outcome), "revoked": .bool(outcome == "revoked"),
                        "queued": .bool(outcome == "queued"),
                    ]))
            }
            await model.bootstrap()
            await model.signOut()
            XCTAssertFalse(model.signedIn)
            XCTAssertFalse(model.connected)
            XCTAssertNil(try storage.load(session.scope.storageKey))
            if outcome == "revoked" {
                XCTAssertNil(model.signInError)
            } else if outcome == "queued" {
                XCTAssertEqual(model.signInError, "Signed out on this device. Server session revocation is queued.")
            } else {
                XCTAssertEqual(
                    model.signInError,
                    "Signed out on this device. The server could not confirm session revocation.")
            }
        }
    }

    func testOwnerMeshCallerKeepsEveryControlPayloadExactAtEncoding() async throws {
        let id = String(repeating: "a", count: 32)
        let cases: [String: JSONValue] = [
            "chrome_mesh_create": .object([
                "fields": .object([
                    "label": .string("Phone"),
                    "device_key": .string(
                        #"{"kty":"OKP","crv":"Ed25519","x":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}"#),
                    "scopes": .string("tools:read"), "ttl_seconds": .string("3600"),
                ])
            ]),
            "chrome_mesh_confirm": .object(["invite_id": .string(id)]),
            "chrome_mesh_reject": .object(["invite_id": .string(id)]),
            "chrome_mesh_remove_invitation": .object(["invite_id": .string(id)]),
            "chrome_mesh_revoke": .object(["member_id": .string(id)]),
            "chrome_mesh_rename": .object(["member_id": .string(id), "fields": .object(["label": .string("Desktop")])]),
        ]
        for (action, payload) in cases {
            let (model, _, session) = try model()
            model.serverSessionTransport = { _ in
                ServerSessionReply(
                    body: .object([
                        "authenticated": .bool(true), "access_token": .string(session.accessToken),
                        "resumed": .bool(true), "user_id": .string(session.owner),
                    ]))
            }
            await model.bootstrap()
            model.connected = true
            model.screen = .surface
            model.pendingSurfaceKey = "mesh"
            model.pendingSurface = AppModel.SurfaceContent(
                surfaceKey: "mesh", title: "Mesh devices",
                components: [
                    AstralComponent(
                        json: .object([
                            "type": .string("button"), "label": .string("Manage"),
                            "action": .string(action), "payload": payload,
                        ]))!
                ])
            var emitted: JSONValue?
            model.outboundTap = { emitted = try! JSONValue.parse(Data($0.utf8)) }
            model.sendEvent(action, payload)
            let frame = try XCTUnwrap(emitted, action)
            var fields = payload.objectValue!
            fields["surface"] = .string("mesh")
            XCTAssertEqual(frame["payload"], .object(fields), action)
            XCTAssertEqual(frame["session_id"], .null)
            XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(frame["submission_id"]?.stringValue)))
            XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(frame["request_generation"]?.stringValue)))
            await model.signOut(revokeRemote: false)
        }
    }

    private func restoredReply(_ session: ServerSession) -> ServerSessionReply {
        ServerSessionReply(
            body: .object([
                "authenticated": .bool(true), "access_token": .string(session.accessToken),
                "resumed": .bool(true), "user_id": .string(session.owner),
            ]))
    }

    private actor RestoreServer {
        private let failures: Int
        private(set) var attempts = 0
        init(failures: Int = 1) { self.failures = failures }
        func answer() -> Bool {
            attempts += 1
            return attempts > failures
        }
    }

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }
}

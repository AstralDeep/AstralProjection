// Verifies protected server-session restoration cannot publish before real cookie authentication.
// Held refreshes and foreign identities exercise account/server retirement without provider network calls.

import AstralCore
@testable import AstralDeep
import Foundation
import XCTest

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
            let gate = Gate()
            model.serverSessionTransport = { request in
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

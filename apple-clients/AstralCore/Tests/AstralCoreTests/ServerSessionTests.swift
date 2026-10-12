// Exercises fresh server custody exchange, scoped socket cookies, refresh, logout, and malformed responses.
// Synthetic JWTs and injected transport keep provider behavior deterministic.

@testable import AstralCore
import Foundation
import XCTest

final class ServerSessionTests: XCTestCase {
    private func scope(_ server: String = "https://example.test") throws -> ServerSessionScope {
        try ServerSessionScope(
            server: URL(string: server)!,
            oidc: OIDCConfig(
                authority: URL(string: "https://iam.test/realms/astral")!, clientId: "astral-mobile",
                redirectURI: "com.personalailabs.astraldeep:/oauth2redirect"))
    }

    private func access(
        owner: String = "owner", issuer: String = "https://iam.test/realms/astral", client: String = "astral-mobile",
        expiry: TimeInterval = Date().addingTimeInterval(3600).timeIntervalSince1970
    ) -> String {
        let claims: JSONValue = .object([
            "iss": .string(issuer), "sub": .string(owner), "azp": .string(client), "exp": .number(expiry),
        ])
        return "e30." + PKCE.base64url(try! claims.encoded()) + ".c2ln"
    }

    func testFreshExchangeNeverTransfersRefreshGrantAndScopesCookieToExactSocket() async throws {
        let scope = try scope()
        let access = access()
        let transport = ServerSessionTransport(scope: scope) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.test/auth/token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Astral-Session-Custody"), "server_v1")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(
                String(decoding: request.httpBody!, as: UTF8.self),
                "client_id=astral-mobile&code=fresh&code_verifier=" + String(repeating: "a", count: 43)
                    + "&grant_type=authorization_code&redirect_uri=com.personalailabs.astraldeep%3A%2Foauth2redirect&session_custody=server_v1"
            )
            return ServerSessionReply(
                body: .object([
                    "authenticated": .bool(true), "access_token": .string(access),
                    "token_type": .string("Bearer"), "expires_in": .number(3600), "user_id": .string("owner"),
                    "resumed": .bool(false),
                ]),
                cookies: ["astral_session=synthetic; Path=/; HttpOnly; Secure; SameSite=lax; Max-Age=3600"])
        }
        let session = try await transport.exchange(code: "fresh", verifier: String(repeating: "a", count: 43))
        XCTAssertNil(session.tokenSet.refreshToken)
        XCTAssertEqual(
            try session.socketHeaders(url: URL(string: "wss://example.test/ws")!, token: access),
            ["Cookie": "astral_session=synthetic", "Origin": "https://example.test"])
        for url in [
            "ws://example.test/ws", "wss://foreign.test/ws", "wss://example.test/ws?token=forged",
            "wss://example.test/other",
        ] {
            XCTAssertThrowsError(try session.socketHeaders(url: URL(string: url)!, token: access))
        }
        XCTAssertThrowsError(try session.socketHeaders(url: URL(string: "wss://example.test/ws")!, token: "foreign"))
        XCTAssertThrowsError(try session.validate(scope: self.scope("https://foreign.test")))
        let decoded = try JSONDecoder().decode(ServerSession.self, from: JSONEncoder().encode(session))
        try decoded.validate(scope: scope)
        XCTAssertEqual(decoded, session)
    }

    func testRefreshPreservesCookieAndOwnerAndLogoutUsesCurrentCustody() async throws {
        let scope = try scope()
        let access = access()
        let session = try ServerSession(
            scope: scope, owner: "owner", accessToken: access,
            cookie: "astral_session=synthetic", cookieExpiresAt: Date().addingTimeInterval(3600))
        let transport = ServerSessionTransport(scope: scope) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), session.cookie)
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            if request.httpMethod == "GET" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return ServerSessionReply(
                    body: .object([
                        "authenticated": .bool(true), "access_token": .string(access),
                        "resumed": .bool(true), "user_id": .string("owner"),
                    ]))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + access)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Astral-Session-Custody"), "server_v1")
            XCTAssertEqual(String(decoding: request.httpBody!, as: UTF8.self), "{\"session_custody\":\"server_v1\"}")
            return ServerSessionReply(
                body: .object(["outcome": .string("revoked"), "revoked": .bool(true), "queued": .bool(false)]))
        }
        let refreshed = try await transport.refresh(session)
        XCTAssertEqual(refreshed, session)
        let loggedOut = try await transport.logout(session)
        XCTAssertTrue(loggedOut)
    }

    func testMalformedScopeIdentityCookieAndRetiredSessionsFailClosed() async throws {
        for server in [
            "http://example.test", "https://example.test/path", "https://example.test?x=1", "https://u:p@example.test",
            "https://example.test#x",
        ] {
            XCTAssertThrowsError(try scope(server))
        }
        for cookie in [
            "", "other=x; Path=/; Secure; HttpOnly; SameSite=lax; Max-Age=3600",
            "astral_session=x; Path=/; HttpOnly; SameSite=lax; Max-Age=3600",
            "astral_session=x; Domain=example.test; Path=/; Secure; HttpOnly; SameSite=lax; Max-Age=3600",
            "astral_session=x; Path=/; Secure; HttpOnly; SameSite=lax; Max-Age=0",
            "astral_session=x; Path=/; Path=/; Secure; HttpOnly; SameSite=lax; Max-Age=3600",
        ] {
            XCTAssertThrowsError(try ServerSessionTransport.issuedCookie([cookie]))
        }
        XCTAssertThrowsError(try ServerSessionTransport.issuedCookie([]))
        XCTAssertThrowsError(try ServerSessionTransport.issuedCookie(["a", "b"]))
        let scope = try scope()
        for access in [
            "broken", self.access(owner: "foreign"), self.access(issuer: "https://foreign.test"),
            self.access(client: "foreign"), self.access(expiry: 1),
        ] {
            XCTAssertThrowsError(
                try ServerSession(
                    scope: scope, owner: "owner", accessToken: access,
                    cookie: "astral_session=x", cookieExpiresAt: Date().addingTimeInterval(3600)))
        }
        let denied = ServerSessionTransport(scope: scope) { _ in ServerSessionReply(body: .object([:])) }
        do {
            _ = try await denied.exchange(code: "fresh", verifier: String(repeating: "a", count: 43))
            XCTFail("accepted")
        } catch {}
        do {
            _ = try await denied.exchange(code: "fresh", verifier: "short")
            XCTFail("accepted")
        } catch {}
    }
    func testExpiredAccessRenewsCapturedCustodyBeforeLogoutAndReportsQueue() async throws {
        let scope = try scope()
        let original = try ServerSession(
            scope: scope, owner: "owner", accessToken: access(),
            cookie: "astral_session=synthetic", cookieExpiresAt: Date().addingTimeInterval(3600))
        var fields = try JSONValue.parse(JSONEncoder().encode(original)).objectValue!
        fields["accessToken"] = .string(access(expiry: 1))
        let expired = try JSONDecoder().decode(ServerSession.self, from: JSONValue.object(fields).encoded())
        let fresh = access()
        let calls = Requests()
        let transport = ServerSessionTransport(scope: scope) { request in
            await calls.append(request)
            if request.httpMethod == "GET" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), expired.cookie)
                return ServerSessionReply(
                    body: .object([
                        "authenticated": .bool(true), "access_token": .string(fresh),
                        "resumed": .bool(true), "user_id": .string("owner"),
                    ]))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + fresh)
            return ServerSessionReply(
                body: .object(["outcome": .string("queued"), "revoked": .bool(false), "queued": .bool(true)]))
        }
        let confirmed = try await transport.logout(expired)
        XCTAssertTrue(confirmed)
        let paths = await calls.paths
        XCTAssertEqual(paths, ["/auth/session", "/api/auth/logout"])
        for mode in ["offline", "foreign", "expired"] {
            let attempts = Requests()
            let denied = ServerSessionTransport(scope: scope) { request in
                await attempts.append(request)
                if mode == "offline" { throw ServerSessionError.unavailable }
                return ServerSessionReply(
                    body: .object([
                        "authenticated": .bool(true),
                        "access_token": .string(mode == "expired" ? expired.accessToken : fresh),
                        "resumed": .bool(true),
                        "user_id": .string(mode == "foreign" ? "other" : "owner"),
                    ]))
            }
            do {
                _ = try await denied.logout(expired)
                XCTFail("accepted " + mode)
            } catch {}
            let paths = await attempts.paths
            XCTAssertEqual(paths, ["/auth/session"])
        }
    }

    private actor Requests {
        var paths: [String] = []
        func append(_ request: URLRequest) { paths.append(request.url!.path) }
    }

}

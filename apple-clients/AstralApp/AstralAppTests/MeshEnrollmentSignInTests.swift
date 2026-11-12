// Verifies the enrollment authorization URL, the nonce, issuer, audience and expiry checks, and the code exchange against stubs.
// No network is used and no real sign-in happens.

import AstralCore
import XCTest

@testable import AstralDeep

private let authority = URL(string: "https://iam.test/realms/Astral")!
private let nonce = "bm9uY2UtYm91bmQtdG8ta2V5"

private nonisolated final class StubWeb: EnrollmentWebAuthenticating, @unchecked Sendable {
    var url: URL?
    let respond: @Sendable (URL) throws -> URL
    init(respond: @escaping @Sendable (URL) throws -> URL) { self.respond = respond }
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        self.url = url
        XCTAssertEqual(callbackScheme, "com.personalailabs.astraldeep")
        return try respond(url)
    }
}

private nonisolated final class StubTransport: EnrollmentTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    let status: Int
    let body: Data
    init(status: Int = 200, body: Data) {
        self.status = status
        self.body = body
    }
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        requests.append(request)
        return (body, status)
    }
}

private func jwt(_ claims: [String: Any]) -> String {
    func encode(_ object: Any) -> String {
        PKCE.base64url(try! JSONSerialization.data(withJSONObject: object))
    }
    return [encode(["alg": "RS256"]), encode(claims), "c2ln"].joined(separator: ".")
}

private func claims(
    iss: String = authority.absoluteString, aud: Any = "astral-desktop", nonce: String = nonce,
    exp: Double = 2_000_000_100
) -> [String: Any] {
    ["iss": iss, "aud": aud, "nonce": nonce, "exp": exp, "sub": "user"]
}

private func tokenBody(_ idToken: String?) -> Data {
    var json: [String: Any] = ["access_token": "a", "token_type": "Bearer"]
    if let idToken { json["id_token"] = idToken }
    return try! JSONSerialization.data(withJSONObject: json)
}

final class MeshEnrollmentSignInTests: XCTestCase {
    private let config = OIDCConfig(
        authority: authority, clientId: "astral-desktop", redirectURI: "com.personalailabs.astraldeep:/oauth2redirect",
        scope: "openid")

    private func flow(
        web: StubWeb, transport: StubTransport
    ) -> EnrollmentSignIn {
        EnrollmentSignIn(
            config: config, web: web, transport: transport,
            now: { Date(timeIntervalSince1970: 2_000_000_000) },
            makeSecret: { UUID().uuidString.replacingOccurrences(of: "-", with: "") })
    }

    private func echoState(_ code: String = "the-code") -> @Sendable (URL) throws -> URL {
        { url in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                .first { $0.name == "state" }!.value!
            return URL(string: "com.personalailabs.astraldeep:/oauth2redirect?code=\(code)&state=\(state)")!
        }
    }

    private func assertThrows(
        _ expected: EnrollmentSignInError, web: StubWeb, transport: StubTransport,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await flow(web: web, transport: transport).signIn(nonce: nonce)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? EnrollmentSignInError, expected, file: file, line: line)
        }
    }

    func testAuthorizationURLCarriesNonceAndPKCEAndOpenIDScope() {
        let sign = flow(web: StubWeb { $0 }, transport: StubTransport(body: Data()))
        let url = sign.authorizationURL(nonce: nonce, state: "st", challenge: "ch")
        let items = Dictionary(
            uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map {
                ($0.name, $0.value ?? "")
            })
        XCTAssertEqual(url.host, "iam.test")
        XCTAssertEqual(url.path, "/realms/Astral/protocol/openid-connect/auth")
        XCTAssertEqual(items["nonce"], nonce)
        XCTAssertEqual(items["state"], "st")
        XCTAssertEqual(items["code_challenge"], "ch")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["scope"], "openid")
        XCTAssertEqual(items["client_id"], "astral-desktop")
        XCTAssertEqual(items["redirect_uri"], "com.personalailabs.astraldeep:/oauth2redirect")
    }

    func testDefaultConfigUsesPlatformClientAndRedirect() {
        let config = EnrollmentSignIn.defaultConfig()
        #if os(iOS)
            XCTAssertEqual(config.clientId, "astral-mobile")
        #else
            XCTAssertEqual(config.clientId, "astral-desktop")
        #endif
        XCTAssertEqual(config.redirectURI, "com.personalailabs.astraldeep:/oauth2redirect")
        XCTAssertEqual(config.scope, "openid")
    }

    func testGoldenPathReturnsIdTokenAndExchangesCodeWithVerifier() async throws {
        let token = jwt(claims())
        let web = StubWeb(respond: echoState())
        let transport = StubTransport(body: tokenBody(token))
        let result = try await flow(web: web, transport: transport).signIn(nonce: nonce)
        XCTAssertEqual(result, token)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url, config.tokenEndpoint)
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)!
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=the-code"))
        XCTAssertTrue(body.contains("code_verifier="))
        let challenge = URLComponents(url: try XCTUnwrap(web.url), resolvingAgainstBaseURL: false)!.queryItems!
            .first { $0.name == "code_challenge" }!.value!
        let verifier = body.components(separatedBy: "&").first { $0.hasPrefix("code_verifier=") }!.dropFirst(14)
        XCTAssertEqual(PKCE.challenge(for: String(verifier)), challenge)
    }

    func testMismatchedNonceIsRefused() async {
        let token = jwt(claims(nonce: "someone-elses"))
        await assertThrows(.nonceMismatch, web: StubWeb(respond: echoState()), transport: StubTransport(body: tokenBody(token)))
    }

    func testMissingNonceIsRefused() async {
        var withoutNonce = claims()
        withoutNonce["nonce"] = nil
        await assertThrows(
            .nonceMismatch, web: StubWeb(respond: echoState()), transport: StubTransport(body: tokenBody(jwt(withoutNonce))))
    }

    func testWrongIssuerIsRefused() async {
        let token = jwt(claims(iss: "https://evil.test/realms/Astral"))
        await assertThrows(.issuerMismatch, web: StubWeb(respond: echoState()), transport: StubTransport(body: tokenBody(token)))
    }

    func testWrongAudienceIsRefused() async {
        let token = jwt(claims(aud: "astral-mobile"))
        await assertThrows(.audienceMismatch, web: StubWeb(respond: echoState()), transport: StubTransport(body: tokenBody(token)))
    }

    func testAudienceListContainingClientIsAccepted() async throws {
        let token = jwt(claims(aud: ["account", "astral-desktop"]))
        let result = try await flow(web: StubWeb(respond: echoState()), transport: StubTransport(body: tokenBody(token)))
            .signIn(nonce: nonce)
        XCTAssertEqual(result, token)
    }

    func testTrailingSlashOnIssuerIsAccepted() async throws {
        let token = jwt(claims(iss: authority.absoluteString + "/"))
        _ = try await flow(web: StubWeb(respond: echoState()), transport: StubTransport(body: tokenBody(token)))
            .signIn(nonce: nonce)
    }

    func testExpiredTokenIsRefused() async {
        let token = jwt(claims(exp: 1_999_999_999))
        await assertThrows(.expired, web: StubWeb(respond: echoState()), transport: StubTransport(body: tokenBody(token)))
    }

    func testMalformedTokenIsRefused() async {
        await assertThrows(
            .malformedIdToken, web: StubWeb(respond: echoState()), transport: StubTransport(body: tokenBody("not-a-jwt")))
    }

    func testMissingIdTokenIsRefused() async {
        await assertThrows(.missingIdToken, web: StubWeb(respond: echoState()), transport: StubTransport(body: tokenBody(nil)))
    }

    func testTokenEndpointErrorIsReported() async {
        let body = try! JSONSerialization.data(withJSONObject: ["error": "invalid_grant"])
        await assertThrows(
            .tokenExchangeFailed("invalid_grant"), web: StubWeb(respond: echoState()),
            transport: StubTransport(status: 400, body: body))
    }

    func testStateMismatchIsRefusedWithoutExchange() async {
        let transport = StubTransport(body: tokenBody(jwt(claims())))
        let web = StubWeb { _ in URL(string: "com.personalailabs.astraldeep:/oauth2redirect?code=c&state=forged")! }
        await assertThrows(.stateMismatch, web: web, transport: transport)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAuthorizationErrorAndMissingCode() async {
        let denied = StubWeb { _ in URL(string: "com.personalailabs.astraldeep:/oauth2redirect?error=access_denied")! }
        await assertThrows(.authorizationFailed("access_denied"), web: denied, transport: StubTransport(body: Data()))
        let noCode = StubWeb(respond: { url in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                .first { $0.name == "state" }!.value!
            return URL(string: "com.personalailabs.astraldeep:/oauth2redirect?state=\(state)")!
        })
        await assertThrows(.missingCode, web: noCode, transport: StubTransport(body: Data()))
    }

    func testCancellationPropagates() async {
        let web = StubWeb { _ in throw EnrollmentSignInError.cancelled }
        await assertThrows(.cancelled, web: web, transport: StubTransport(body: Data()))
    }
}

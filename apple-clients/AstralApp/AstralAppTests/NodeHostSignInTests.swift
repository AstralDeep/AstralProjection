// Verifies external node-service authorization URL, the nonce, issuer, audience and expiry checks, and the code exchange against stubs.
// No network is used and no real sign-in happens.

import AstralCore
import AuthenticationServices
import XCTest

@testable import AstralDeep

private let authority = URL(string: "https://iam.test/realms/Astral")!
private let nonce = "bm9uY2UtYm91bmQtdG8ta2V5"

private nonisolated final class StubWeb: NodeHostWebAuthenticating, @unchecked Sendable {
    var url: URL?
    let respond: @Sendable (URL) throws -> URL
    init(respond: @escaping @Sendable (URL) throws -> URL) { self.respond = respond }
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        self.url = url
        XCTAssertEqual(callbackScheme, "com.personalailabs.astraldeep")
        return try respond(url)
    }
}

private nonisolated final class StubTransport: NodeHostTransport, @unchecked Sendable {
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

@MainActor
private final class StubAuthenticationSession: NodeHostAuthenticationSession {
    let shouldStart: Bool
    private let callbackOnStart: URL?
    private var completion: NodeHostAuthenticationCompletion?
    private(set) var starts = 0
    private(set) var cancellations = 0
    var presentationContextProvider: ASWebAuthenticationPresentationContextProviding?
    var prefersEphemeralWebBrowserSession = true

    init(shouldStart: Bool, callbackOnStart: URL? = nil) {
        self.shouldStart = shouldStart
        self.callbackOnStart = callbackOnStart
    }

    func install(_ completion: @escaping NodeHostAuthenticationCompletion) { self.completion = completion }

    var installedCompletion: NodeHostAuthenticationCompletion? { completion }

    func start() -> Bool {
        starts += 1
        if let callbackOnStart { completion?(callbackOnStart, nil) }
        return shouldStart
    }

    func cancel() {
        cancellations += 1
        completion?(nil, ASWebAuthenticationSessionError(.canceledLogin))
    }

    func deliver(_ callback: URL?, error: Error? = nil) { completion?(callback, error) }
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

@MainActor
private func waitForNodeHostSession(_ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(condition())
}

final class NodeHostSignInTests: XCTestCase {
    private let config = OIDCConfig(
        authority: authority, clientId: "astral-desktop", redirectURI: "com.personalailabs.astraldeep:/oauth2redirect",
        scope: "openid")

    private func flow(
        web: StubWeb, transport: StubTransport
    ) -> NodeHostSignIn {
        NodeHostSignIn(
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
        _ expected: NodeHostSignInError, web: StubWeb, transport: StubTransport,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await flow(web: web, transport: transport).signIn(nonce: nonce)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? NodeHostSignInError, expected, file: file, line: line)
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
        let config = NodeHostSignIn.defaultConfig()
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
        await assertThrows(
            .nonceMismatch, web: StubWeb(respond: echoState()), transport: StubTransport(body: tokenBody(token)))
    }

    func testMissingNonceIsRefused() async {
        var withoutNonce = claims()
        withoutNonce["nonce"] = nil
        await assertThrows(
            .nonceMismatch, web: StubWeb(respond: echoState()),
            transport: StubTransport(body: tokenBody(jwt(withoutNonce))))
    }

    func testWrongIssuerIsRefused() async {
        let token = jwt(claims(iss: "https://evil.test/realms/Astral"))
        await assertThrows(
            .issuerMismatch, web: StubWeb(respond: echoState()), transport: StubTransport(body: tokenBody(token)))
    }

    func testWrongAudienceIsRefused() async {
        let token = jwt(claims(aud: "astral-mobile"))
        await assertThrows(
            .audienceMismatch, web: StubWeb(respond: echoState()), transport: StubTransport(body: tokenBody(token)))
    }

    func testAudienceListContainingClientIsAccepted() async throws {
        let token = jwt(claims(aud: ["account", "astral-desktop"]))
        let result = try await flow(
            web: StubWeb(respond: echoState()), transport: StubTransport(body: tokenBody(token))
        )
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
        await assertThrows(
            .expired, web: StubWeb(respond: echoState()), transport: StubTransport(body: tokenBody(token)))
    }

    func testMalformedTokenIsRefused() async {
        await assertThrows(
            .malformedIdToken, web: StubWeb(respond: echoState()),
            transport: StubTransport(body: tokenBody("not-a-jwt")))
    }

    func testMissingIdTokenIsRefused() async {
        await assertThrows(
            .missingIdToken, web: StubWeb(respond: echoState()), transport: StubTransport(body: tokenBody(nil)))
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
        let web = StubWeb { _ in throw NodeHostSignInError.cancelled }
        await assertThrows(.cancelled, web: web, transport: StubTransport(body: Data()))
    }

    @MainActor
    func testLateCallbackAfterAuthenticationSessionStartFailureDoesNotResumeTwice() async {
        let session = StubAuthenticationSession(shouldStart: false)
        let web = SystemNodeHostWebAuthenticator(sessionFactory: { _, _, completion in
            session.install(completion)
            return session
        })
        do {
            _ = try await web.authenticate(url: authority, callbackScheme: "com.personalailabs.astraldeep")
            XCTFail("A session that did not start must fail")
        } catch {
            XCTAssertEqual(error as? NodeHostSignInError, .unableToStart)
        }
        session.deliver(URL(string: "com.personalailabs.astraldeep:/oauth2redirect?code=late&state=late"))
        XCTAssertEqual(session.starts, 1)
    }

    @MainActor
    func testCallbackDeliveredBeforeFalseStartResultKeepsTheCallbackResult() async throws {
        let callback = URL(string: "com.personalailabs.astraldeep:/oauth2redirect?code=first&state=first")!
        let session = StubAuthenticationSession(shouldStart: false, callbackOnStart: callback)
        let web = SystemNodeHostWebAuthenticator(sessionFactory: { _, _, completion in
            session.install(completion)
            return session
        })

        let result = try await web.authenticate(url: authority, callbackScheme: "com.personalailabs.astraldeep")

        XCTAssertEqual(result, callback)
        XCTAssertEqual(session.starts, 1)
    }

    @MainActor
    func testAuthenticationCallbackReturnsURLWhenDeliveredOffMainActor() async throws {
        let callback = URL(string: "com.personalailabs.astraldeep:/oauth2redirect?code=accepted&state=accepted")!
        let session = StubAuthenticationSession(shouldStart: true)
        let web = SystemNodeHostWebAuthenticator(sessionFactory: { _, _, completion in
            session.install(completion)
            return session
        })
        let authentication = Task {
            try await web.authenticate(url: authority, callbackScheme: "com.personalailabs.astraldeep")
        }
        await waitForNodeHostSession { session.starts == 1 }
        let completion = try XCTUnwrap(session.installedCompletion)

        await Task.detached { completion(callback, nil) }.value

        let result = try await authentication.value
        XCTAssertEqual(result, callback)
    }

    @MainActor
    func testAuthenticationCallbackPreservesUnderlyingError() async {
        let expected = NSError(domain: "enrollment.test", code: 37)
        let session = StubAuthenticationSession(shouldStart: true)
        let web = SystemNodeHostWebAuthenticator(sessionFactory: { _, _, completion in
            session.install(completion)
            return session
        })
        let authentication = Task {
            try await web.authenticate(url: authority, callbackScheme: "com.personalailabs.astraldeep")
        }
        await waitForNodeHostSession { session.starts == 1 }
        session.deliver(nil, error: expected)

        do {
            _ = try await authentication.value
            XCTFail("The authentication callback error must propagate")
        } catch {
            XCTAssertEqual((error as NSError).domain, expected.domain)
            XCTAssertEqual((error as NSError).code, expected.code)
        }
    }

    @MainActor
    func testPreCancelledAuthenticationDoesNotStartASession() async {
        let session = StubAuthenticationSession(shouldStart: true)
        let web = SystemNodeHostWebAuthenticator(sessionFactory: { _, _, completion in
            session.install(completion)
            return session
        })
        let authentication = Task {
            try await web.authenticate(url: authority, callbackScheme: "com.personalailabs.astraldeep")
        }
        authentication.cancel()

        do {
            _ = try await authentication.value
            XCTFail("A pre-cancelled authentication must not start")
        } catch {
            XCTAssertEqual(error as? NodeHostSignInError, .cancelled)
        }
        XCTAssertEqual(session.starts, 0)
    }

    @MainActor
    func testCancellationCompletesOnceAndCancelsTheOwnedSession() async {
        let session = StubAuthenticationSession(shouldStart: true)
        let web = SystemNodeHostWebAuthenticator(sessionFactory: { _, _, completion in
            session.install(completion)
            return session
        })
        let authentication = Task {
            try await web.authenticate(url: authority, callbackScheme: "com.personalailabs.astraldeep")
        }
        await waitForNodeHostSession { session.starts == 1 }
        authentication.cancel()

        do {
            _ = try await authentication.value
            XCTFail("Cancelled authentication must not return a callback")
        } catch {
            XCTAssertEqual(error as? NodeHostSignInError, .cancelled)
        }
        XCTAssertEqual(session.cancellations, 1)
    }

    @MainActor
    func testConcurrentAuthenticationIsRejectedWithoutReplacingCurrentSession() async throws {
        let session = StubAuthenticationSession(shouldStart: true)
        let web = SystemNodeHostWebAuthenticator(sessionFactory: { _, _, completion in
            session.install(completion)
            return session
        })
        let active = Task {
            try await web.authenticate(url: authority, callbackScheme: "com.personalailabs.astraldeep")
        }
        await waitForNodeHostSession { session.starts == 1 }

        do {
            _ = try await web.authenticate(url: authority, callbackScheme: "com.personalailabs.astraldeep")
            XCTFail("A second simultaneous authentication must be rejected")
        } catch {
            XCTAssertEqual(error as? NodeHostSignInError, .alreadyAuthenticating)
        }
        let callback = URL(string: "com.personalailabs.astraldeep:/oauth2redirect?code=one&state=one")!
        session.deliver(callback)
        let result = try await active.value
        XCTAssertEqual(result, callback)
        XCTAssertEqual(session.starts, 1)
    }

    @MainActor
    func testLateCallbackFromRetiredAttemptCannotCancelOrCompleteTheNextAttempt() async {
        let first = StubAuthenticationSession(shouldStart: true)
        let second = StubAuthenticationSession(shouldStart: true)
        var sessions = [first, second]
        let web = SystemNodeHostWebAuthenticator(sessionFactory: { _, _, completion in
            let session = sessions.removeFirst()
            session.install(completion)
            return session
        })
        let firstAuthentication = Task {
            try await web.authenticate(url: authority, callbackScheme: "com.personalailabs.astraldeep")
        }
        await waitForNodeHostSession { first.starts == 1 }
        firstAuthentication.cancel()
        do {
            _ = try await firstAuthentication.value
            XCTFail("The retired first attempt must be cancelled")
        } catch {
            XCTAssertEqual(error as? NodeHostSignInError, .cancelled)
        }

        let secondAuthentication = Task {
            try await web.authenticate(url: authority, callbackScheme: "com.personalailabs.astraldeep")
        }
        await waitForNodeHostSession { second.starts == 1 }
        first.deliver(URL(string: "com.personalailabs.astraldeep:/oauth2redirect?code=stale&state=stale"))
        XCTAssertEqual(second.cancellations, 0)
        secondAuthentication.cancel()
        do {
            _ = try await secondAuthentication.value
            XCTFail("The second attempt must stay pending until its own result")
        } catch {
            XCTAssertEqual(error as? NodeHostSignInError, .cancelled)
        }
        XCTAssertEqual(first.cancellations, 1)
        XCTAssertEqual(second.cancellations, 1)
    }
}

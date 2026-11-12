// Runs the Keycloak PKCE sign-in for mesh enrollment with a caller-supplied nonce and returns an ID token that is bound to it.
// It reuses AstralCore's OIDCConfig and PKCE helpers, and the kernel computes the nonce from the identity key and the mesh id.

import AstralCore
import AuthenticationServices
import Foundation

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

nonisolated enum EnrollmentSignInError: Error, Equatable {
    case cancelled
    case authorizationFailed(String)
    case stateMismatch
    case missingCode
    case tokenExchangeFailed(String)
    case missingIdToken
    case malformedIdToken
    case issuerMismatch
    case audienceMismatch
    case nonceMismatch
    case expired
}

nonisolated protocol EnrollmentWebAuthenticating: Sendable {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

nonisolated protocol EnrollmentTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int)
}

nonisolated struct URLSessionEnrollmentTransport: EnrollmentTransport {
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

nonisolated struct EnrollmentSignIn: Sendable {
    let config: OIDCConfig
    let web: EnrollmentWebAuthenticating
    let transport: EnrollmentTransport
    let now: @Sendable () -> Date
    let makeSecret: @Sendable () -> String

    init(
        config: OIDCConfig = EnrollmentSignIn.defaultConfig(),
        web: EnrollmentWebAuthenticating,
        transport: EnrollmentTransport = URLSessionEnrollmentTransport(),
        now: @escaping @Sendable () -> Date = { Date() },
        makeSecret: @escaping @Sendable () -> String = { PKCE.makeVerifier() }
    ) {
        self.config = config
        self.web = web
        self.transport = transport
        self.now = now
        self.makeSecret = makeSecret
    }

    static func defaultConfig() -> OIDCConfig {
        #if os(iOS)
            let client = AstralConfig.iosClientId
        #else
            let client = AstralConfig.macosClientId
        #endif
        let authority = URL(string: AstralConfig.keycloakAuthority) ?? URL(string: AstralConfig.fallbackKeycloakAuthority)!
        return OIDCConfig(
            authority: authority, clientId: client, redirectURI: AstralConfig.redirectURI, scope: "openid")
    }

    func authorizationURL(nonce: String, state: String, challenge: String) -> URL {
        var parts = URLComponents(
            url: config.authorizeURL(state: state, challenge: challenge), resolvingAgainstBaseURL: false)!
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "nonce", value: nonce)]
        return parts.url!
    }

    func signIn(nonce: String) async throws -> String {
        let verifier = makeSecret()
        let state = makeSecret()
        let url = authorizationURL(nonce: nonce, state: state, challenge: PKCE.challenge(for: verifier))
        let callback = try await web.authenticate(url: url, callbackScheme: AstralConfig.redirectScheme)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw EnrollmentSignInError.authorizationFailed(error) }
        guard value("state") == state else { throw EnrollmentSignInError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw EnrollmentSignInError.missingCode }
        let idToken = try await exchange(code: code, verifier: verifier)
        try validate(idToken: idToken, nonce: nonce)
        return idToken
    }

    func validate(idToken: String, nonce: String) throws {
        let claims = try Self.claims(of: idToken)
        let issuer = config.authority.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let tokenIssuer = claims["iss"] as? String,
            tokenIssuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == issuer
        else { throw EnrollmentSignInError.issuerMismatch }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(config.clientId) else { throw EnrollmentSignInError.audienceMismatch }
        guard let tokenNonce = claims["nonce"] as? String, tokenNonce == nonce else {
            throw EnrollmentSignInError.nonceMismatch
        }
        guard let expiry = claims["exp"] as? Double, expiry > now().timeIntervalSince1970 else {
            throw EnrollmentSignInError.expired
        }
    }

    private func exchange(code: String, verifier: String) async throws -> String {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(config.tokenRequestBody(code: code, verifier: verifier).utf8)
        let (data, status) = try await transport.send(request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            throw EnrollmentSignInError.tokenExchangeFailed(json?["error"] as? String ?? "http_\(status)")
        }
        guard let idToken = json?["id_token"] as? String, !idToken.isEmpty else {
            throw EnrollmentSignInError.missingIdToken
        }
        return idToken
    }

    private static func claims(of token: String) throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw EnrollmentSignInError.malformedIdToken }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded += "=" }
        guard let data = Data(base64Encoded: encoded),
            let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw EnrollmentSignInError.malformedIdToken }
        return claims
    }
}

@MainActor
final class SystemEnrollmentWebAuthenticator: NSObject, EnrollmentWebAuthenticating,
    ASWebAuthenticationPresentationContextProviding
{
    private var session: ASWebAuthenticationSession?

    @MainActor
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        do {
            let callback = try await withTaskCancellationHandler {
                try await start(url: url, callbackScheme: callbackScheme)
            } onCancel: {
                Task { @MainActor in self.session?.cancel() }
            }
            session = nil
            return callback
        } catch {
            session = nil
            throw error
        }
    }

    private func start(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation(isolation: MainActor.shared) { continuation in
            MainActor.assumeIsolated {
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                    if let callback {
                        continuation.resume(returning: callback)
                    } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                        continuation.resume(throwing: EnrollmentSignInError.cancelled)
                    } else {
                        continuation.resume(throwing: error ?? EnrollmentSignInError.cancelled)
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                if !session.start() {
                    self.session = nil
                    continuation.resume(throwing: EnrollmentSignInError.cancelled)
                }
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
                NSApplication.shared.mainWindow ?? ASPresentationAnchor()
            #else
                UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                    .first ?? ASPresentationAnchor()
            #endif
        }
    }
}

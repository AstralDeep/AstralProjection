// Authenticates an external Mac node host with OIDC and PKCE, separately from mesh-key identity.
// MacNodeHostStore uses the nonce-bound token only for the node service; personal mesh creation never invokes this flow.

import AstralCore
import AuthenticationServices
import Foundation

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

nonisolated enum NodeHostSignInError: Error, Equatable {
    case cancelled
    case unableToStart
    case alreadyAuthenticating
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

nonisolated protocol NodeHostWebAuthenticating: Sendable {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

typealias NodeHostAuthenticationCompletion = @Sendable (URL?, Error?) -> Void

@MainActor
protocol NodeHostAuthenticationSession: AnyObject {
    var presentationContextProvider: ASWebAuthenticationPresentationContextProviding? { get set }
    var prefersEphemeralWebBrowserSession: Bool { get set }
    func start() -> Bool
    func cancel()
}

extension ASWebAuthenticationSession: NodeHostAuthenticationSession {}

typealias NodeHostAuthenticationSessionFactory =
    @MainActor (
        URL, String, @escaping NodeHostAuthenticationCompletion
    ) -> any NodeHostAuthenticationSession

private nonisolated final class NodeHostAuthenticationCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?

    func install(_ continuation: CheckedContinuation<URL, Error>) {
        let pending: Result<URL, Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(with: pending) }
    }

    func finish(_ result: Result<URL, Error>) {
        let continuation: CheckedContinuation<URL, Error>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    var isFinished: Bool { lock.withLock { result != nil } }
}

nonisolated protocol NodeHostTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int)
}

nonisolated struct URLSessionNodeHostTransport: NodeHostTransport {
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

nonisolated struct NodeHostSignIn: Sendable {
    let config: OIDCConfig
    let web: NodeHostWebAuthenticating
    let transport: NodeHostTransport
    let now: @Sendable () -> Date
    let makeSecret: @Sendable () -> String

    init(
        config: OIDCConfig = NodeHostSignIn.defaultConfig(),
        web: NodeHostWebAuthenticating,
        transport: NodeHostTransport = URLSessionNodeHostTransport(),
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
        let authority =
            URL(string: AstralConfig.keycloakAuthority) ?? URL(string: AstralConfig.fallbackKeycloakAuthority)!
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
        if let error = value("error") { throw NodeHostSignInError.authorizationFailed(error) }
        guard value("state") == state else { throw NodeHostSignInError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw NodeHostSignInError.missingCode }
        let idToken = try await exchange(code: code, verifier: verifier)
        try validate(idToken: idToken, nonce: nonce)
        return idToken
    }

    func validate(idToken: String, nonce: String) throws {
        let claims = try Self.claims(of: idToken)
        let issuer = config.authority.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let tokenIssuer = claims["iss"] as? String,
            tokenIssuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == issuer
        else { throw NodeHostSignInError.issuerMismatch }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(config.clientId) else { throw NodeHostSignInError.audienceMismatch }
        guard let tokenNonce = claims["nonce"] as? String, tokenNonce == nonce else {
            throw NodeHostSignInError.nonceMismatch
        }
        guard let expiry = claims["exp"] as? Double, expiry > now().timeIntervalSince1970 else {
            throw NodeHostSignInError.expired
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
            throw NodeHostSignInError.tokenExchangeFailed(json?["error"] as? String ?? "http_\(status)")
        }
        guard let idToken = json?["id_token"] as? String, !idToken.isEmpty else {
            throw NodeHostSignInError.missingIdToken
        }
        return idToken
    }

    private static func claims(of token: String) throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw NodeHostSignInError.malformedIdToken }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded += "=" }
        guard let data = Data(base64Encoded: encoded),
            let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw NodeHostSignInError.malformedIdToken }
        return claims
    }
}

@MainActor
final class SystemNodeHostWebAuthenticator: NSObject, NodeHostWebAuthenticating,
    ASWebAuthenticationPresentationContextProviding
{
    private var activeAttempt: UUID?
    private var session: (attempt: UUID, value: any NodeHostAuthenticationSession)?
    private let sessionFactory: NodeHostAuthenticationSessionFactory

    init(
        sessionFactory: @escaping NodeHostAuthenticationSessionFactory = { url, callbackScheme, completion in
            ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme, completionHandler: completion)
        }
    ) {
        self.sessionFactory = sessionFactory
    }

    @MainActor
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        guard !Task.isCancelled else { throw NodeHostSignInError.cancelled }
        guard activeAttempt == nil else { throw NodeHostSignInError.alreadyAuthenticating }
        let attemptID = UUID()
        let completion = NodeHostAuthenticationCompletionGate()
        activeAttempt = attemptID
        defer {
            if activeAttempt == attemptID {
                activeAttempt = nil
                session = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await start(url: url, callbackScheme: callbackScheme, attemptID: attemptID, completion: completion)
        } onCancel: {
            Task { @MainActor [weak self] in
                completion.finish(.failure(NodeHostSignInError.cancelled))
                self?.cancelSession(for: attemptID)
            }
        }
    }

    private func start(
        url: URL, callbackScheme: String, attemptID: UUID,
        completion: NodeHostAuthenticationCompletionGate
    ) async throws -> URL {
        try await withCheckedThrowingContinuation(isolation: MainActor.shared) { continuation in
            MainActor.assumeIsolated {
                completion.install(continuation)
                guard !Task.isCancelled else {
                    completion.finish(.failure(NodeHostSignInError.cancelled))
                    return
                }
                let session = sessionFactory(url, callbackScheme) { callback, error in
                    completion.finish(Self.result(callback: callback, error: error))
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                self.session = (attemptID, session)
                guard !completion.isFinished else { return }
                if !session.start() {
                    clearSession(for: attemptID)
                    completion.finish(.failure(NodeHostSignInError.unableToStart))
                }
            }
        }
    }

    private func cancelSession(for attemptID: UUID) {
        guard activeAttempt == attemptID, let session, session.attempt == attemptID else { return }
        session.value.cancel()
    }

    private func clearSession(for attemptID: UUID) {
        guard session?.attempt == attemptID else { return }
        session = nil
    }

    private nonisolated static func result(callback: URL?, error: Error?) -> Result<URL, Error> {
        if let callback { return .success(callback) }
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
            return .failure(NodeHostSignInError.cancelled)
        }
        return .failure(error ?? NodeHostSignInError.cancelled)
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

// Runs one connection sign-in: asks the Kernel to begin, opens the system browser, and hands the returned address to the Kernel untouched.
// The browser session sits behind a factory so tests supply a fake, and MeshConnectionsView builds the real one.

import AstralCore
import AuthenticationServices
import Foundation
import Observation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

@MainActor
protocol MeshConnectionSignInService: AnyObject {
    func beginConnectionSignIn(id: String, redirect: MeshSignInRedirect) async throws -> MeshSignInStart
    func completeConnectionSignIn(flow: String, redirectURL: String) async throws -> MeshConnectionState
    func cancelConnectionSignIn(flow: String) async throws
}

extension MeshRuntime: MeshConnectionSignInService {}

enum MeshWebAuthFailure: Error, Equatable {
    case cancelled
    case failed
}

@MainActor
protocol MeshWebAuthSession: AnyObject {
    func start() -> Bool
    func cancel()
}

typealias MeshWebAuthSessionFactory =
    @MainActor (_ url: URL, _ completion: @escaping @MainActor (Result<URL, MeshWebAuthFailure>) -> Void)
    -> any MeshWebAuthSession

nonisolated enum MeshConnectionSignInRoute: Equatable, Sendable {
    case browser
    case key
    case none
    case unsupported

    static let redirect: MeshSignInRedirect = .appLink

    static func of(_ connection: MeshConnection) -> MeshConnectionSignInRoute {
        guard connection.supportedHere else { return .unsupported }
        switch connection.scheme {
        case "oauth", "oidc", "openid", "openid-connect": return .browser
        case "key": return .key
        case nil, "none": return .none
        default: return .unsupported
        }
    }
}

@MainActor
@Observable
final class MeshConnectionSignIn {
    enum Phase: Equatable {
        case idle
        case starting
        case waiting
        case completing
        case signedIn(toolsPending: Bool)
        case cancelled
        case failed(String)
    }

    private let service: any MeshConnectionSignInService
    private let makeSession: MeshWebAuthSessionFactory
    private let availability: ConnectionCallback.Availability
    private var session: (any MeshWebAuthSession)?
    private var flow: String?
    private var waiter: CheckedContinuation<Result<URL, MeshWebAuthFailure>, Never>?
    private(set) var phase: Phase = .idle
    private(set) var connectionId: String?

    init(
        service: any MeshConnectionSignInService,
        availability: ConnectionCallback.Availability = ConnectionCallback.availabilityHere(),
        makeSession: @escaping MeshWebAuthSessionFactory
    ) {
        self.service = service
        self.availability = availability
        self.makeSession = makeSession
    }

    var isBusy: Bool {
        switch phase {
        case .starting, .waiting, .completing: return true
        default: return false
        }
    }

    func signIn(connection id: String) async {
        guard !isBusy else { return }
        connectionId = id
        if case .unavailable(let code) = availability {
            phase = .failed(KernelMapping.failureText(code: code))
            return
        }
        phase = .starting
        let start: MeshSignInStart
        do {
            start = try await service.beginConnectionSignIn(id: id, redirect: MeshConnectionSignInRoute.redirect)
        } catch {
            phase = .failed(MeshRuntime.describe(error))
            return
        }
        guard let text = start.authorizationURL, let url = URL(string: text) else {
            await abandon(start.flow)
            phase = .failed(KernelMapping.failureText(code: "oauth.no_authorization_url"))
            return
        }
        flow = start.flow
        phase = .waiting
        let result = await openBrowser(url)
        await finish(result, flow: start.flow)
    }

    func cancel() {
        guard phase == .waiting else { return }
        session?.cancel()
        resolve(.failure(.cancelled))
    }

    private func openBrowser(_ url: URL) async -> Result<URL, MeshWebAuthFailure> {
        await withCheckedContinuation { continuation in
            waiter = continuation
            let opened = makeSession(url) { [weak self] result in self?.resolve(result) }
            session = opened
            if !opened.start() { resolve(.failure(.failed)) }
        }
    }

    private func resolve(_ result: Result<URL, MeshWebAuthFailure>) {
        guard let pending = waiter else { return }
        waiter = nil
        pending.resume(returning: result)
    }

    private func finish(_ result: Result<URL, MeshWebAuthFailure>, flow id: String) async {
        session = nil
        flow = nil
        switch result {
        case .failure(.cancelled):
            await abandon(id)
            phase = .cancelled
        case .failure(.failed):
            await abandon(id)
            phase = .failed(KernelMapping.failureText(code: "oauth.browser_failed"))
        case .success(let callback):
            guard ConnectionCallback.matches(callback) else {
                await abandon(id)
                phase = .failed(KernelMapping.failureText(code: "oauth.wrong_callback"))
                return
            }
            await complete(callback, flow: id)
        }
    }

    private func complete(_ callback: URL, flow id: String) async {
        phase = .completing
        do {
            let state = try await service.completeConnectionSignIn(flow: id, redirectURL: callback.absoluteString)
            phase =
                state.state == "signed_in"
                ? .signedIn(toolsPending: state.toolsPending)
                : .failed(MeshConnectionAttentionFacts.text(reason: state.reason))
        } catch {
            phase = .failed(MeshRuntime.describe(error))
        }
    }

    private func abandon(_ id: String) async {
        try? await service.cancelConnectionSignIn(flow: id)
    }
}

@MainActor
private final class MeshSystemWebAuthSession: NSObject, MeshWebAuthSession,
    ASWebAuthenticationPresentationContextProviding
{
    private let session: ASWebAuthenticationSession

    init(session: ASWebAuthenticationSession) {
        self.session = session
        super.init()
        session.prefersEphemeralWebBrowserSession = false
        session.presentationContextProvider = self
    }

    func start() -> Bool { session.start() }

    func cancel() { session.cancel() }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        #else
            return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #endif
    }
}

@MainActor
private final class MeshUnavailableWebAuthSession: MeshWebAuthSession {
    func start() -> Bool { false }

    func cancel() {}
}

enum MeshSystemWebAuth {
    static let factory: MeshWebAuthSessionFactory = { url, completion in
        guard #available(iOS 17.4, macOS 14.4, *) else { return MeshUnavailableWebAuthSession() }
        let callback = ASWebAuthenticationSession.Callback.https(
            host: ConnectionCallback.host, path: ConnectionCallback.path)
        let session = ASWebAuthenticationSession(url: url, callback: callback) { result, error in
            let outcome: Result<URL, MeshWebAuthFailure>
            if let result {
                outcome = .success(result)
            } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                outcome = .failure(.cancelled)
            } else {
                outcome = .failure(.failed)
            }
            Task { @MainActor in completion(outcome) }
        }
        return MeshSystemWebAuthSession(session: session)
    }
}

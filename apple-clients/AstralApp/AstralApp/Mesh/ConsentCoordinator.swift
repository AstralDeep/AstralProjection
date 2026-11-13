// Queues consent requests for the sheet, authenticates the person with LocalAuthentication, and returns the outcome to the signer.
// A request ends in approval only through the on-screen Approve button after biometrics or passcode, never from voice or model output.

import Foundation
import LocalAuthentication
import Observation

nonisolated enum ConsentDenial: Error, Equatable, Sendable {
    case denied
    case timedOut
    case cancelled
}

nonisolated struct ConsentApproval: @unchecked Sendable {
    let context: LAContext?
}

nonisolated enum ConsentDecision: Sendable {
    case approved(ConsentApproval)
    case denied(ConsentDenial)
}

nonisolated struct ConsentPresentation: Sendable {
    fileprivate let presenter: UUID
    fileprivate let entry: UUID
    fileprivate let generation: UUID
    let prompt: ConsentPrompt
}

nonisolated protocol ConsentPresenting: Sendable {
    func requestConsent(_ prompt: ConsentPrompt) async -> ConsentDecision
}

nonisolated protocol ConsentAuthenticating: Sendable {
    func authenticate(reason: String, requiresBiometry: Bool) async throws -> LAContext
}

nonisolated struct LocalAuthenticator: ConsentAuthenticating {
    private let contextFactory: @Sendable () -> LAContext

    init(contextFactory: @escaping @Sendable () -> LAContext = { LAContext() }) {
        self.contextFactory = contextFactory
    }

    func authenticate(reason: String, requiresBiometry: Bool) async throws -> LAContext {
        let context = contextFactory()
        var policy = LAPolicy.deviceOwnerAuthentication
        if requiresBiometry {
            var probe: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &probe) else {
                throw ConsentDenial.denied
            }
            policy = .deviceOwnerAuthenticationWithBiometrics
            context.localizedFallbackTitle = ""
        }
        guard try await context.evaluatePolicy(policy, localizedReason: reason) else { throw ConsentDenial.denied }
        return context
    }
}

@MainActor
@Observable
final class ConsentCoordinator: ConsentPresenting {
    private struct Entry {
        let id: UUID
        let prompt: ConsentPrompt
        let continuation: CheckedContinuation<ConsentDecision, Never>
        let presenter: UUID?
    }

    private(set) var current: ConsentPrompt?
    private(set) var isAuthenticating = false
    private(set) var authenticationMessage: String?
    private(set) var presentationOwner: UUID?

    @ObservationIgnored private var queue: [Entry] = []
    @ObservationIgnored private var active: Entry?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private let authenticator: ConsentAuthenticating
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private var presenters: [(id: UUID, depth: Int)] = []
    @ObservationIgnored private var presentationGeneration = UUID()

    init(authenticator: ConsentAuthenticating = LocalAuthenticator(), timeout: Duration = .seconds(120)) {
        self.authenticator = authenticator
        self.timeout = timeout
    }

    func registerPresenter(_ id: UUID, depth: Int) {
        guard !presenters.contains(where: { $0.id == id && $0.depth == depth }) else { return }
        presenters.removeAll { $0.id == id }
        presenters.append((id, depth))
        updatePresentationOwner()
    }

    func releasePresenter(_ id: UUID) {
        var cancelled = queue.filter { $0.presenter == id }.map(\.id)
        if let active, active.presenter == id || presentationOwner == id { cancelled.append(active.id) }
        presenters.removeAll { $0.id == id }
        updatePresentationOwner()
        for entry in cancelled { finish(entry, .denied(.cancelled)) }
    }

    func presentation(for presenter: UUID) -> ConsentPresentation? {
        guard presenter == presentationOwner, let active, let current else { return nil }
        return ConsentPresentation(
            presenter: presenter, entry: active.id, generation: presentationGeneration, prompt: current)
    }

    private func updatePresentationOwner() {
        let depth = presenters.map(\.depth).max()
        let next = presenters.last { $0.depth == depth }?.id
        guard next != presentationOwner else { return }
        if isAuthenticating, let active { finish(active.id, .denied(.cancelled)) }
        presentationGeneration = UUID()
        presentationOwner = next
    }

    private func isCurrent(_ presentation: ConsentPresentation) -> Bool {
        presentation.presenter == presentationOwner && presentation.entry == active?.id
            && presentation.generation == presentationGeneration
    }

    func requestConsent(_ prompt: ConsentPrompt) async -> ConsentDecision {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation(isolation: MainActor.shared) { continuation in
                MainActor.assumeIsolated {
                    guard !Task.isCancelled else {
                        continuation.resume(returning: .denied(.cancelled))
                        return
                    }
                    queue.append(
                        Entry(id: id, prompt: prompt, continuation: continuation, presenter: presentationOwner))
                    advance()
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(id, .denied(.cancelled)) }
        }
    }

    func approve(_ presentation: ConsentPresentation) async {
        guard isCurrent(presentation), let entry = active, !isAuthenticating else { return }
        isAuthenticating = true
        authenticationMessage = nil
        do {
            let context = try await authenticator.authenticate(
                reason: entry.prompt.actionTitle, requiresBiometry: entry.prompt.requiresBiometry)
            guard isCurrent(presentation) else { return }
            finish(entry.id, .approved(ConsentApproval(context: context)))
        } catch {
            guard isCurrent(presentation) else { return }
            isAuthenticating = false
            authenticationMessage = "Authentication did not complete. Try again or deny."
        }
    }

    func deny(_ presentation: ConsentPresentation) {
        guard isCurrent(presentation), let entry = active else { return }
        finish(entry.id, .denied(.denied))
    }

    private func advance() {
        guard active == nil, !queue.isEmpty else { return }
        let entry = queue.removeFirst()
        active = entry
        current = entry.prompt
        authenticationMessage = nil
        let wait = timeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.finish(entry.id, .denied(.timedOut))
        }
    }

    private func finish(_ id: UUID, _ decision: ConsentDecision) {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index).continuation.resume(returning: decision)
            return
        }
        guard let entry = active, entry.id == id else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        active = nil
        current = nil
        isAuthenticating = false
        authenticationMessage = nil
        entry.continuation.resume(returning: decision)
        advance()
    }
}

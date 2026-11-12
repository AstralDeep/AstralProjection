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

nonisolated protocol ConsentPresenting: Sendable {
    func requestConsent(_ prompt: ConsentPrompt) async -> ConsentDecision
}

nonisolated protocol ConsentAuthenticating: Sendable {
    func authenticate(reason: String, requiresBiometry: Bool) async throws -> LAContext
}

nonisolated struct LocalAuthenticator: ConsentAuthenticating {
    func authenticate(reason: String, requiresBiometry: Bool) async throws -> LAContext {
        let context = LAContext()
        var policy = LAPolicy.deviceOwnerAuthentication
        if requiresBiometry {
            var probe: NSError?
            if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &probe) {
                policy = .deviceOwnerAuthenticationWithBiometrics
                context.localizedFallbackTitle = ""
            }
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
    }

    private(set) var current: ConsentPrompt?
    private(set) var isAuthenticating = false
    private(set) var authenticationMessage: String?

    @ObservationIgnored private var queue: [Entry] = []
    @ObservationIgnored private var active: Entry?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private let authenticator: ConsentAuthenticating
    @ObservationIgnored private let timeout: Duration

    init(authenticator: ConsentAuthenticating = LocalAuthenticator(), timeout: Duration = .seconds(120)) {
        self.authenticator = authenticator
        self.timeout = timeout
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
                    queue.append(Entry(id: id, prompt: prompt, continuation: continuation))
                    advance()
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(id, .denied(.cancelled)) }
        }
    }

    func approve() async {
        guard let entry = active, !isAuthenticating else { return }
        isAuthenticating = true
        authenticationMessage = nil
        do {
            let context = try await authenticator.authenticate(
                reason: entry.prompt.actionTitle, requiresBiometry: entry.prompt.requiresBiometry)
            finish(entry.id, .approved(ConsentApproval(context: context)))
        } catch {
            guard active?.id == entry.id else { return }
            isAuthenticating = false
            authenticationMessage = "Authentication did not complete. Try again or deny."
        }
    }

    func deny() {
        guard let entry = active else { return }
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

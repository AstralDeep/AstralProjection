// Defines the host signing interface the Rust kernel calls and implements it over DeviceKeys and the consent flow.
// The kernel lane later conforms AstralHostSigning to the generated HostSigner callback with the same method names.

import Foundation

nonisolated enum HostSigningError: Error, Equatable {
    case consentDenied(ConsentDenial)
    case digestMismatch
    case calledOnMainThread
}

nonisolated protocol AstralHostSigning: Sendable {
    func identityPublicKey() throws -> Data
    func identitySign(_ message: Data) throws -> Data
    func presencePublicKey() throws -> Data
    func presenceSign(prompt: ConsentPrompt, message: Data) throws -> Data
    func hardwareBacked() -> Bool
}

nonisolated final class MeshHostSigner: AstralHostSigning {
    private let keys: DeviceKeys
    private let presenter: ConsentPresenting

    init(keys: DeviceKeys, presenter: ConsentPresenting) {
        self.keys = keys
        self.presenter = presenter
    }

    func identityPublicKey() throws -> Data { try keys.identityPublicKey() }

    func identitySign(_ message: Data) throws -> Data { try keys.identitySign(message) }

    func presencePublicKey() throws -> Data { try keys.presencePublicKey() }

    func hardwareBacked() -> Bool { keys.hardwareBacked }

    func presenceSign(prompt: ConsentPrompt, message: Data) throws -> Data {
        guard !Thread.isMainThread else { throw HostSigningError.calledOnMainThread }
        guard prompt.isBound(to: message) else { throw HostSigningError.digestMismatch }
        let outcome = DecisionBox()
        let presenter = presenter
        Task.detached {
            outcome.set(await presenter.requestConsent(prompt))
        }
        switch outcome.wait() {
        case .approved(let approval):
            return try keys.presenceSign(message, authentication: approval.context)
        case .denied(let reason):
            throw HostSigningError.consentDenied(reason)
        }
    }
}

private nonisolated final class DecisionBox: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var decision: ConsentDecision = .denied(.cancelled)

    func set(_ value: ConsentDecision) {
        decision = value
        semaphore.signal()
    }

    func wait() -> ConsentDecision {
        semaphore.wait()
        return decision
    }
}

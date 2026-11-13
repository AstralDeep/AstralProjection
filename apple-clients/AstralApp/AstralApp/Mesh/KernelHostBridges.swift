// Adapts the host's signing, on-device model, local tools and change callbacks to the callback interfaces the generated kernel bindings declare.
// RealMeshKernel hands these to Kernel.open, and each one keeps the policy decisions on the host side: the consent sheet draws only what was parsed from the exact signing input.

import AstralKernel
import Foundation

nonisolated final class KernelHostSigner: AstralKernel.HostSigner, @unchecked Sendable {
    private let signer: any AstralHostSigning

    init(_ signer: any AstralHostSigning) { self.signer = signer }

    func identityPublicKey() -> Data { (try? signer.identityPublicKey()) ?? Data() }

    func identitySign(message: Data) throws -> Data {
        do { return try signer.identitySign(message) } catch { throw Self.signerError(error) }
    }

    func presencePublicKey() -> Data { (try? signer.presencePublicKey()) ?? Data() }

    func hardwareBacked() -> Bool { signer.hardwareBacked() }

    func presenceSign(prompt: AstralKernel.ConsentPrompt, message: Data) throws -> Data {
        let display: ConsentPrompt
        do { display = try Self.display(for: prompt, message: message) } catch {
            throw HostSignerError.Failed(message: "consent.unreadable: the request could not be shown, so nothing was signed")
        }
        do { return try signer.presenceSign(prompt: display, message: message) } catch { throw Self.signerError(error) }
    }

    static func display(for prompt: AstralKernel.ConsentPrompt, message: Data) throws -> ConsentPrompt {
        guard prompt.signingInput == message else { throw ConsentPromptError.invalidInput }
        let built: ConsentPrompt
        switch prompt.kind {
        case .rosterAdd, .rosterRemove, .stop, .resume:
            built = try ConsentPrompt.roster(signingInput: message)
            let expected = [
                .rosterAdd: "roster.add", .rosterRemove: "roster.remove", .stop: "roster.stop",
                .resume: "roster.resume",
            ][prompt.kind]
            guard built.effect == expected else { throw ConsentPromptError.invalidInput }
        case .other where prompt.title == "create_mesh":
            built = try ConsentPrompt.roster(signingInput: message)
            guard built.effect == "roster.genesis" else { throw ConsentPromptError.invalidInput }
        case .toolEffect:
            if prompt.title == "run.takeover" {
                built = try ConsentPrompt.takeover(canonicalAction: prompt.canonicalAction, signingInput: message)
            } else if ConsentPrompt.isGrant(canonicalAction: prompt.canonicalAction) {
                built = try ConsentPrompt.grant(
                    canonicalAction: prompt.canonicalAction, canonicalArguments: prompt.canonicalArguments,
                    signingInput: message)
            } else {
                built = try ConsentPrompt.action(
                    canonicalAction: prompt.canonicalAction, canonicalArguments: prompt.canonicalArguments,
                    signingInput: message)
            }
        case .other:
            throw ConsentPromptError.invalidInput
        }
        return built.requiringBiometry(prompt.requiresBiometry)
    }

    private static func signerError(_ error: Error) -> HostSignerError {
        if let signing = error as? HostSigningError {
            switch signing {
            case .consentDenied: return .Denied(message: "the owner declined")
            case .digestMismatch: return .Failed(message: "consent.digest_mismatch")
            case .calledOnMainThread: return .Unavailable(message: "consent.main_thread")
            }
        }
        if error is DeviceKeysError || error is MeshSecretStoreError {
            return .Unavailable(message: "the device keys are not usable")
        }
        return .Failed(message: "the device refused to sign")
    }
}

nonisolated final class KernelOnDeviceModel: AstralKernel.OnDeviceModel, @unchecked Sendable {
    private let model: any AstralOnDeviceModel

    init(_ model: any AstralOnDeviceModel) { self.model = model }

    func available() -> Bool { model.available() }

    func complete(request: AstralKernel.OnDeviceRequest) throws -> AstralKernel.OnDeviceResponse {
        let messages = try request.messages.map { message -> OnDeviceMessage in
            guard let role = OnDeviceMessage.Role(rawValue: message.role) else {
                throw HostCallError.Failed(message: "on_device.bad_role")
            }
            return OnDeviceMessage(role: role, text: message.content)
        }
        let local = OnDeviceRequest(
            messages: messages, schemaJSON: request.jsonSchema, maxTokens: Int(request.maxTokens))
        let model = model
        switch BlockingBridge.run({ await model.complete(local) }) {
        case .text(let text), .json(let text):
            return AstralKernel.OnDeviceResponse(text: text)
        case .refused:
            throw HostCallError.Failed(message: "on_device.refused")
        case .unavailable(let reason):
            throw HostCallError.Failed(message: "on_device.unavailable: " + reason.rawValue)
        case .failed(let failure):
            throw HostCallError.Failed(message: "on_device." + failure.rawValue)
        }
    }
}

nonisolated final class KernelLocalTools: AstralKernel.LocalTools, @unchecked Sendable {
    private let tools: any MeshLocalTools

    init(_ tools: any MeshLocalTools) { self.tools = tools }

    func list() throws -> [LocalToolSpec] { tools.list().map(Self.native) }

    static func native(_ spec: MeshLocalToolSpec) -> LocalToolSpec {
        LocalToolSpec(
            name: spec.name, description: spec.summary, inputSchemaJson: spec.schemaJSON,
            annotationsJson: spec.annotationsJSON, effect: effect(spec.effect),
            confidentiality: confidentiality(spec.confidentiality))
    }

    func call(name: String, argumentsJson: String, ticket: String) throws -> String {
        do {
            return try tools.call(name: name, argumentsJSON: argumentsJson, ticket: Data(ticket.utf8))
        } catch let error as MeshKernelError {
            throw HostCallError.Failed(message: error.message)
        } catch {
            throw HostCallError.Unknown(message: "tool.unknown_outcome")
        }
    }

    static func effect(_ effect: MeshToolEffect) -> LocalToolEffect {
        switch effect {
        case .meshRead: return .meshRead
        case .meshWrite: return .meshWrite
        case .outwardRead: return .outwardRead
        case .outsideEffect: return .outsideEffect
        }
    }

    static func meshEffect(_ effect: LocalToolEffect) -> MeshToolEffect {
        switch effect {
        case .meshRead: return .meshRead
        case .meshWrite: return .meshWrite
        case .outwardRead: return .outwardRead
        case .outsideEffect: return .outsideEffect
        }
    }

    private static func confidentiality(_ value: MeshToolConfidentiality) -> LocalToolConfidentiality {
        switch value {
        case .public: return .public
        case .private: return .private
        case .phi: return .phi
        case .secret: return .secret
        }
    }
}

nonisolated final class KernelChangeBridge: AstralKernel.KernelListener, AstralKernel.RunListener, @unchecked Sendable {
    private let listener: any MeshKernelListening
    private let onEnrollment: @Sendable () -> Void

    init(listener: any MeshKernelListening, onEnrollment: @escaping @Sendable () -> Void) {
        self.listener = listener
        self.onEnrollment = onEnrollment
    }

    func onChange(change: KernelChange) {
        if KernelMapping.isEnrollmentComplete(change) { onEnrollment() }
        for mapped in KernelMapping.changes(change) { listener.onChange(mapped) }
    }

    func onProgress(progress: RunProgressInfo) {
        listener.onChange(.runProgress(runId: progress.runId))
    }
}

nonisolated enum BlockingBridge {
    private final class Slot<T: Sendable>: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var value: T?
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let slot = Slot<T>()
        Task.detached {
            slot.value = await work()
            slot.semaphore.signal()
        }
        slot.semaphore.wait()
        return slot.value!
    }
}

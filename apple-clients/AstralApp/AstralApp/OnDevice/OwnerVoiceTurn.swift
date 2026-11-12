// Labels a spoken transcript with its integrity and defines the narrow interface through which the kernel receives voice turns.
// The interface has no approval path on purpose, so a spoken yes can never authorize a pending risky action.

import Foundation

nonisolated enum VoiceAudioSource: Equatable, Sendable {
    case deviceMicrophone
    case file
    case call
    case other
}

nonisolated enum VoiceSessionTrigger: Equatable, Sendable {
    case ownerGesture
    case pushToTalk
    case programmatic
}

nonisolated enum VoiceTranscriptIntegrity: String, Equatable, Sendable {
    case owner
    case untrusted
}

nonisolated struct OwnerVoiceTurn: Equatable, Sendable {
    let text: String
    let integrity: VoiceTranscriptIntegrity
    let source: VoiceAudioSource
    let riskyActionPending: Bool

    var approvalEligible: Bool { false }

    @MainActor static func make(
        text: String, source: VoiceAudioSource, trigger: VoiceSessionTrigger,
        riskyActionPending: Bool
    ) -> OwnerVoiceTurn? {
        guard let canonical = canonicalizeLocalFinal(text) else { return nil }
        let ownerSpoken = source == .deviceMicrophone && trigger != .programmatic
        return OwnerVoiceTurn(
            text: canonical, integrity: ownerSpoken ? .owner : .untrusted, source: source,
            riskyActionPending: riskyActionPending)
    }
}

nonisolated enum VoiceSpokenKind: Equatable, Sendable {
    case answer
    case acknowledgement
}

nonisolated struct VoiceSpokenRecord: Equatable, Sendable {
    let kind: VoiceSpokenKind
    let text: String
}

@MainActor
protocol VoiceKernelLink: AnyObject {
    func submit(turn: OwnerVoiceTurn)
    func cancelTurn()
    func cancelTool(id: String)
    func record(spoken: VoiceSpokenRecord)
}

// Names the distinct reasons a spoken reply cannot be produced by a voice, and the contract every switchable voice implements.
// LocalVoiceSpeech and SystemVoiceSpeech conform to SwitchableVoice, and AutomaticVoiceSpeech chooses between them from these reasons.

import Foundation

nonisolated enum VoiceSpeechUnavailability: Equatable, Sendable {
    case operatingSystemTooOld
    case notInstalled
    case loadFailed
    case synthesisFailed
    case noSystemVoice(ConversationLanguage)
}

nonisolated struct VoiceSpeechUnavailable: Error, Equatable, Sendable {
    let reason: VoiceSpeechUnavailability
}

nonisolated protocol SwitchableVoice: VoiceSpeaking {
    func unavailability() async -> VoiceSpeechUnavailability?
    func warmUp() async throws
    func cancel() async
}

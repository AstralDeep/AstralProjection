// Gathers the recognizer, the local text generator and the one shared voice that every voice pipeline is built from, with the calls that open, close and unload the models around a conversation.
// OnDeviceVoiceController builds the phone pipeline from it and PairedWatchVoiceRelay builds the Watch pipeline from the same parts.

import AstralVoiceSpeech
import Foundation

nonisolated struct VoiceSessionParts: Sendable {
    let recognizer: any VoiceRecognizing
    let textGenerator: any VoiceTextGenerating
    let speech: any VoiceSpeaking
    let begin: @Sendable () async throws -> Void
    let end: @Sendable () async -> Void
    let unload: @Sendable () async -> Void

    static func standard(
        folder: @escaping LocalVoiceSpeech.FolderProvider, models: RumbleVoiceModels = .shared,
        synthesizer: any SpeechSynthesizer = PhononSpeech(), system: any SwitchableVoice = SystemVoiceSpeech(),
        language: @escaping @Sendable () -> ConversationLanguage = { ConversationLanguage.saved() }
    ) -> VoiceSessionParts {
        let local = LocalVoiceSpeech(synthesizer: synthesizer, folder: folder)
        models.owner.unloadObservers.add { await local.unload() }
        let speech = AutomaticVoiceSpeech(
            local: local, system: system,
            language: language,
            englishChoice: { .automatic },
            onSwitch: { _ in })
        return VoiceSessionParts(
            recognizer: models.recognizer, textGenerator: models.textGenerator, speech: speech,
            begin: {
                Task { await speech.warmUp() }
                await models.beginSession()
                _ = try await models.owner.recognizer()
                _ = try await models.owner.textGenerator()
            },
            end: { await models.endSession() },
            unload: {
                await speech.cancel()
                await local.unload(force: true)
                await models.owner.unload()
            })
    }

    func transcriber() -> RumbleTranscriber {
        RumbleTranscriber(recognizer: recognizer)
    }

    @MainActor
    func fastPath() -> VoiceFastPath {
        VoiceFastPath(model: VoiceAcknowledgementModel(generator: textGenerator))
    }

    @MainActor
    func pipeline(link: VoiceKernelLink) -> VoicePipeline {
        VoicePipeline(
            audio: VoiceDuplexEngine(speech: speech), transcriber: transcriber(), fastPath: fastPath(), link: link)
    }
}

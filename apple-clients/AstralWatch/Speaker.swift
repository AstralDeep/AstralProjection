// Requests speech from the paired phone's verified on-device model and tracks actual Watch playback.
// The Watch holds only the most recent ephemeral text for replay and never uses platform synthesis.

import AstralCore
import Observation

typealias AstralSpeech = AstralCore.Speech

@MainActor
@Observable
final class Speaker {
    var onSpeak: ((String) -> Void)?
    var onStop: (() -> Void)?
    private var lastSpokenKey: String?
    private var lastText: String?
    private(set) var isSpeaking = false

    func remember(_ speech: AstralSpeech?) {
        guard let text = speech?.text, !text.isEmpty, text != lastSpokenKey else { return }
        lastSpokenKey = text
        lastText = text
    }

    func replay() {
        guard let lastText else { return }
        stop()
        onSpeak?(lastText)
    }

    func stop() {
        onStop?()
        isSpeaking = false
    }

    func playbackChanged(_ speaking: Bool) { isSpeaking = speaking }
    func clear() {
        stop()
        lastSpokenKey = nil
        lastText = nil
    }
}

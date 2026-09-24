// On-device text-to-speech for the server's spoken turn rendition (SSML via AVSpeechUtterance, with
// plain-text fallback); stops immediately on navigation and never re-speaks a turn, used by WatchModel and
// WatchChatView.

import AVFoundation
import AstralCore
import Observation

typealias AstralSpeech = AstralCore.Speech

@Observable
final class Speaker: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var lastSpokenKey: Int?
    @ObservationIgnored private var lastSpeech: SpeechPayload?

    struct SpeechPayload {
        let ssml: String
        let text: String
    }

    var isSpeaking = false

    override init() {
        super.init()
        synthesizer.delegate = self
        #if os(watchOS)
            try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.duckOthers])
        #endif
    }

    func speak(_ speech: AstralSpeech?) {
        guard let speech else { return }
        let key = speech.text.hashValue
        guard key != lastSpokenKey else { return }
        lastSpokenKey = key
        let payload = SpeechPayload(ssml: speech.ssml, text: speech.text)
        lastSpeech = payload
        utter(payload)
    }

    func replay() {
        guard let last = lastSpeech else { return }
        stop()
        utter(last)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func utter(_ payload: SpeechPayload) {
        let utterance: AVSpeechUtterance
        if !payload.ssml.isEmpty,
            let ssml = AVSpeechUtterance(ssmlRepresentation: payload.ssml)
        {
            utterance = ssml
        } else if !payload.text.isEmpty {
            utterance = AVSpeechUtterance(string: payload.text)
        } else {
            return
        }
        isSpeaking = true
        synthesizer.speak(utterance)
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        isSpeaking = false
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        isSpeaking = false
    }
}

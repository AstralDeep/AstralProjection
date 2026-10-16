// Fences synthesis delegate progress to the current utterance owned by SystemAppleLocalSpeechEngine.
// Terminal callbacks release that ownership before another announcement can begin.

@MainActor
final class AppleLocalSpeechProgress {
    private var utterance: AnyObject?
    private var onPhase: (@MainActor (String) -> Void)?
    private var started = false

    func begin(_ utterance: AnyObject, onPhase: @escaping @MainActor (String) -> Void) {
        self.utterance = utterance
        self.onPhase = onPhase
        started = false
    }

    func start(_ utterance: AnyObject) {
        guard self.utterance === utterance, !started else { return }
        started = true
        onPhase?("started")
    }

    func finish(_ utterance: AnyObject, phase: String) {
        guard self.utterance === utterance else { return }
        let callback = onPhase
        clear()
        callback?(phase)
    }

    func clear() {
        utterance = nil
        onPhase = nil
        started = false
    }
}

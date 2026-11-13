// Runs one on-device voice session: capture, voice activity, streaming transcription, end-of-turn, speculative acknowledgement, streamed speech and barge-in.
// The kernel connects through VoiceKernelLink for turns going out and the answer methods for text coming back, and no path here approves an action or contacts a voice server.

import AVFoundation
import Foundation

nonisolated struct VoicePipelineConfiguration: Equatable, Sendable {
    var finalTimeout: TimeInterval = 8
    var tickInterval: Duration = .milliseconds(20)
    var bargeIn = BargeInConfiguration()
    var turn = VoiceTurnConfiguration()
}

nonisolated enum VoicePipelineError: Error, Equatable {
    case alreadyRunning
}

@MainActor
final class VoicePipeline {
    private struct AwaitingFinal {
        let deadline: TimeInterval
        let segmentID: UUID?
    }

    var onFailure: ((String) -> Void)?
    var onSpeechIdle: (() -> Void)?

    private let audio: VoiceDuplexAudio
    private let transcriber: VoiceStreamingTranscriber
    private let fastPath: VoiceFastPath?
    private weak var link: VoiceKernelLink?
    private let clock: VoiceClock
    private let configuration: VoicePipelineConfiguration
    private let barge: BargeInController
    private let detector: VoiceEndOfTurnDetector
    private var splitter = VoiceSentenceSplitter()
    private var trigger: VoiceSessionTrigger = .programmatic
    private var running = false
    private var segmentOpen = false
    private var segmentHadVoice = false
    private var holdingKey = false
    private var awaitingFinal: AwaitingFinal?
    private var turnID = 0
    private var answerStarted = false
    private var acceptingAnswer = false
    private var answerFinishedStreaming = false
    private var riskyActionPending = false
    private var acknowledgementPlaying: String?
    private var deferredSpeak: BargeInAction?
    private var userTalking = false
    private var ticker: Task<Void, Never>?
    private var microphonePreRoll: [AVAudioPCMBuffer] = []

    init(
        audio: VoiceDuplexAudio, transcriber: VoiceStreamingTranscriber, fastPath: VoiceFastPath?,
        link: VoiceKernelLink, clock: VoiceClock = SystemVoiceClock(),
        configuration: VoicePipelineConfiguration = VoicePipelineConfiguration()
    ) {
        self.audio = audio
        self.transcriber = transcriber
        self.fastPath = fastPath
        self.link = link
        self.clock = clock
        self.configuration = configuration
        barge = BargeInController(configuration: configuration.bargeIn, clock: clock)
        detector = VoiceEndOfTurnDetector(configuration: configuration.turn, clock: clock)
    }

    var isRunning: Bool { running }

    func start(trigger: VoiceSessionTrigger, mode: VoiceCaptureMode = .handsFree) throws {
        guard !running else { throw VoicePipelineError.alreadyRunning }
        self.trigger = trigger
        detector.setMode(mode)
        holdingKey = false
        audio.onMicrophone = { [weak self] buffer in self?.captureMicrophone(buffer) }
        audio.onVoiceActivity = { [weak self] active in self?.handleVoiceActivity(active) }
        audio.onFailure = { [weak self] reason in self?.onFailure?(reason) }
        audio.onEvent = { [weak self] event in self?.handleSpeech(event) }
        transcriber.setEventHandler { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleRecognizer(event) } }
        }
        do {
            try audio.start()
        } catch {
            audio.stop()
            transcriber.shutdown()
            throw error
        }
        running = true
        if mode == .handsFree { openSegment() }
        let warming = fastPath
        Task { await warming?.warm() }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.configuration.tickInterval ?? .milliseconds(20))
                self?.tick()
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        ticker?.cancel()
        ticker = nil
        transcriber.shutdown()
        audio.stop()
        fastPath?.discard()
        barge.reset()
        detector.reset()
        splitter.reset()
        segmentOpen = false
        segmentHadVoice = false
        awaitingFinal = nil
        acknowledgementPlaying = nil
        deferredSpeak = nil
        acceptingAnswer = false
        microphonePreRoll = []
    }

    func beginPushToTalk() {
        guard running, detector.mode == .pushToTalk, !holdingKey else { return }
        holdingKey = true
        detector.reset()
        stopAcknowledgement()
        openSegment()
        segmentHadVoice = true
    }

    func endPushToTalk() {
        guard running, holdingKey else { return }
        holdingKey = false
        handle(detector.release())
    }

    func answerDelta(_ text: String) {
        guard running, acceptingAnswer, !text.isEmpty else { return }
        if !answerStarted {
            answerStarted = true
            fastPath?.discard()
        }
        for sentence in splitter.append(text) { enqueue(sentence) }
    }

    func answerFinished() {
        guard running, acceptingAnswer else { return }
        for sentence in splitter.flush() { enqueue(sentence) }
        answerFinishedStreaming = true
        notifyIdleIfDrained()
    }

    func toolStarted(id: String, cancelSafe: Bool) { barge.toolStarted(id: id, cancelSafe: cancelSafe) }

    func toolFinished(id: String) { barge.toolFinished(id: id) }

    func setRiskyActionPending(_ pending: Bool) {
        riskyActionPending = pending
        barge.setRiskyActionPending(pending)
    }

    func handleVoiceActivity(_ active: Bool) {
        guard running else { return }
        userTalking = active
        if active, segmentOpen { segmentHadVoice = true }
        if !active { transcriber.flushPartial() }
        if active { stopAcknowledgement() }
        syncPlayedProgress()
        perform(barge.voiceActivity(active: active))
        handle(detector.voiceActivity(active: active))
    }

    func handleRecognizer(_ event: VoiceRecognizerEvent) {
        guard running else { return }
        switch event {
        case .partial(let text, let segmentID):
            guard segmentHadVoice else { return }
            guard segmentID == nil || segmentID == transcriber.segmentID else { return }
            syncPlayedProgress()
            perform(barge.partialTranscript(text))
            if !barge.isSpeaking { handle(detector.partial(text)) }
        case .final(let text, let segmentID):
            if let waiting = awaitingFinal {
                guard segmentID == nil || segmentID == waiting.segmentID else { return }
                awaitingFinal = nil
                submitTurn(text)
            } else {
                guard segmentHadVoice else { return }
                guard segmentID == nil || segmentID == transcriber.segmentID else { return }
                if !segmentOpen { openSegment() }
                submitTurn(text)
            }
        case .failed(let reason):
            segmentOpen = false
            onFailure?(reason)
        }
    }

    func handleSpeech(_ event: VoiceSpeechEvent) {
        guard running else { return }
        switch event {
        case .started:
            break
        case .finished(let index):
            if index < 0 {
                finishAcknowledgement(completed: true)
            } else {
                perform(barge.sentenceFinished(index: index, completed: true))
                notifyIdleIfDrained()
            }
        case .failed(let index):
            if index < 0 {
                finishAcknowledgement(completed: false)
            } else {
                perform(barge.sentenceFinished(index: index, completed: false))
                notifyIdleIfDrained()
            }
            onFailure?("voice_synthesis_failed")
        }
    }

    func tick() {
        guard running else { return }
        syncPlayedProgress()
        perform(barge.tick())
        handle(detector.tick())
        if let waiting = awaitingFinal, clock.now >= waiting.deadline {
            awaitingFinal = nil
            fastPath?.discard()
            detector.reset()
            onFailure?("voice_recognition_timed_out")
        }
    }

    private func captureMicrophone(_ buffer: AVAudioPCMBuffer) {
        guard running, detector.mode == .handsFree || holdingKey else { return }
        if detector.mode == .handsFree, !userTalking {
            microphonePreRoll.append(buffer)
            while microphonePreRoll.count > 1,
                microphonePreRoll.reduce(0, { $0 + Double($1.frameLength) / $1.format.sampleRate }) > 0.15
            {
                microphonePreRoll.removeFirst()
            }
            return
        }
        for onset in microphonePreRoll { transcriber.append(onset) }
        microphonePreRoll = []
        transcriber.append(buffer)
    }

    private func openSegment() {
        guard !segmentOpen else { return }
        do {
            try transcriber.beginSegment()
            segmentOpen = true
            segmentHadVoice = false
        } catch {
            onFailure?("transcriber_segment_failed")
        }
    }

    private func handle(_ signals: [VoiceTurnSignal]) {
        for signal in signals {
            switch signal {
            case .speculate(let text):
                fastPath?.speculate(text)
            case .discardDraft:
                fastPath?.discard()
            case .endOfTurn:
                awaitingFinal = AwaitingFinal(
                    deadline: clock.now + configuration.finalTimeout, segmentID: transcriber.segmentID)
                transcriber.endSegment()
                segmentOpen = false
                if detector.mode == .handsFree { openSegment() }
            }
        }
    }

    private func submitTurn(_ text: String) {
        detector.reset()
        barge.transcriptSegmentReset()
        guard
            let transcript = OwnerVoiceTurn.make(
                text: text, source: .deviceMicrophone, trigger: trigger,
                riskyActionPending: riskyActionPending)
        else {
            fastPath?.discard()
            return
        }
        turnID += 1
        answerStarted = false
        answerFinishedStreaming = false
        acceptingAnswer = true
        splitter.reset()
        link?.submit(turn: transcript)
        requestAcknowledgement(for: transcript.text, turn: turnID)
    }

    private func requestAcknowledgement(for text: String, turn: Int) {
        guard let fastPath, fastPath.isEnabled else { return }
        Task { [weak self] in
            guard let acknowledgement = await fastPath.acknowledgement(forFinal: text) else { return }
            self?.speakAcknowledgement(acknowledgement, turn: turn)
        }
    }

    private func speakAcknowledgement(_ text: String, turn: Int) {
        guard running, turn == turnID, !answerStarted, !userTalking, !barge.isSpeaking,
            acknowledgementPlaying == nil
        else { return }
        acknowledgementPlaying = text
        audio.speak(index: -1, text: text)
    }

    private func stopAcknowledgement() {
        guard acknowledgementPlaying != nil else { return }
        acknowledgementPlaying = nil
        audio.stopSpeaking()
        runDeferredSpeak()
    }

    private func finishAcknowledgement(completed: Bool) {
        guard let text = acknowledgementPlaying else { return }
        acknowledgementPlaying = nil
        if completed { link?.record(spoken: VoiceSpokenRecord(kind: .acknowledgement, text: text)) }
        runDeferredSpeak()
    }

    private func runDeferredSpeak() {
        guard let action = deferredSpeak else { return }
        deferredSpeak = nil
        perform([action])
    }

    private func enqueue(_ sentence: String) {
        syncPlayedProgress()
        perform(barge.enqueue(sentence: sentence, speech: VoiceSpeechText.clean(sentence)))
    }

    private func syncPlayedProgress() {
        guard let progress = audio.playedProgress(), progress.index >= 0 else { return }
        barge.sentenceProgress(index: progress.index, characters: progress.characters)
    }

    private func perform(_ actions: [BargeInAction]) {
        for action in actions {
            switch action {
            case .duck(let volume):
                audio.setVolume(volume)
            case .restoreVolume:
                audio.setVolume(1)
            case .speak:
                if acknowledgementPlaying != nil {
                    deferredSpeak = action
                } else if case .speak(let index, let text) = action {
                    audio.speak(index: index, text: text)
                }
            case .stopSpeech:
                deferredSpeak = nil
                audio.stopSpeaking()
            case .cancelModelStream:
                link?.cancelTurn()
            case .cancelTool(let id):
                link?.cancelTool(id: id)
            case .recordSpoken(let text):
                link?.record(spoken: VoiceSpokenRecord(kind: .answer, text: text))
            case .beginUserTurn:
                acceptingAnswer = false
                splitter.reset()
                answerStarted = false
                fastPath?.discard()
            }
        }
    }

    private func notifyIdleIfDrained() {
        if answerFinishedStreaming, !barge.isSpeaking, acknowledgementPlaying == nil { onSpeechIdle?() }
    }
}

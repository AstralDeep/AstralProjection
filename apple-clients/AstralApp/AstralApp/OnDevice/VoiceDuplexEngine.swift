// One AVAudioEngine graph with voice processing for echo cancellation that carries microphone capture and synthesized speech together.
// VoicePipeline reads cleaned microphone buffers and voice activity from it and plays sentences through it so the echo canceller hears the reference signal.

import AVFoundation
import Foundation

@MainActor
protocol VoiceDuplexAudio: VoiceSpeechOutput {
    var onMicrophone: ((AVAudioPCMBuffer) -> Void)? { get set }
    var onVoiceActivity: ((Bool) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func start() throws
    func stop()
}

nonisolated enum VoiceDuplexError: Error, Equatable {
    case voiceProcessingUnavailable
    case noInputFormat
}

private nonisolated final class VoiceActivityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var detector = EnergyVoiceActivityDetector()

    func process(level: Float, duration: TimeInterval) -> Bool? {
        lock.withLock { detector.process(level: level, duration: duration) }
    }

    func reset() { lock.withLock { detector.reset() } }
}

@MainActor
final class VoiceDuplexEngine: VoiceDuplexAudio {
    private final class Playback {
        let index: Int
        let text: String
        var rawMarkers: [(range: NSRange, offset: Double)] = []
        var sourceFormat: AVAudioFormat?
        var scheduled = 0
        var played = 0
        var synthesisDone = false
        var started = false
        var finished = false

        init(index: Int, text: String) {
            self.index = index
            self.text = text
        }
    }

    var onEvent: ((VoiceSpeechEvent) -> Void)?
    var onMicrophone: ((AVAudioPCMBuffer) -> Void)?
    var onVoiceActivity: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let synthesizer = AVSpeechSynthesizer()
    private let activity = VoiceActivityBox()
    private let playbackFormat: AVAudioFormat
    private let locale: String
    private var playback: Playback?
    private var generation = 0
    private var converter: AVAudioConverter?
    private var running = false
    private var configurationObserver: (any NSObjectProtocol)?

    init(locale: String? = nil) {
        self.locale = locale ?? AppleLocalSpeechObservation.configuredLocale
        playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    }

    func start() throws {
        guard !running else { return }
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: [])
        #endif
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            throw VoiceDuplexError.voiceProcessingUnavailable
        }
        input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: false, duckingLevel: .min)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw VoiceDuplexError.noInputFormat }
        let box = activity
        box.reset()
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            let duration = Double(buffer.frameLength) / buffer.format.sampleRate
            let change = box.process(level: EnergyVoiceActivityDetector.level(of: buffer), duration: duration)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    self.onMicrophone?(buffer)
                    if let change { self.onVoiceActivity?(change) }
                }
            }
        }
        engine.prepare()
        try engine.start()
        running = true
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAfterConfigurationChange() }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        haltPlayback()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.detach(player)
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    func setVolume(_ volume: Float) {
        player.volume = volume
    }

    func speak(index: Int, text: String) {
        guard running, let voice = AVSpeechSynthesisVoice(language: locale) else {
            onEvent?(.failed(index: index))
            return
        }
        haltPlayback()
        generation += 1
        let token = generation
        let current = Playback(index: index, text: text)
        playback = current
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        synthesizer.write(
            utterance,
            toBufferCallback: { [weak self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.receive(buffer: pcm, token: token) }
                }
            },
            toMarkerCallback: { [weak self] markers in
                let words = markers.filter { $0.mark == .word }
                    .map { (range: $0.textRange, offset: Double($0.byteSampleOffset)) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.receive(markers: words, token: token) }
                }
            })
    }

    func stopSpeaking() { haltPlayback() }

    func playedProgress() -> VoiceSpeechProgress? {
        guard let current = playback, current.started, !current.finished,
            let format = current.sourceFormat,
            let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return nil }
        let heard = max(0, Double(playerTime.sampleTime) / playerTime.sampleRate)
        let bytesPerFrame = Double(max(1, format.streamDescription.pointee.mBytesPerFrame))
        let timeline = VoiceSpeechTimeline.make(
            text: current.text, wordRanges: current.rawMarkers,
            secondsPerOffsetUnit: 1 / (bytesPerFrame * format.sampleRate))
        return VoiceSpeechProgress(index: current.index, characters: timeline.charactersSpoken(atSeconds: heard))
    }

    private func haltPlayback() {
        generation += 1
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        player.stop()
        playback = nil
    }

    private func receive(markers: [(range: NSRange, offset: Double)], token: Int) {
        guard token == generation, let current = playback else { return }
        current.rawMarkers += markers
    }

    private func receive(buffer: AVAudioPCMBuffer, token: Int) {
        guard token == generation, let current = playback else { return }
        if buffer.frameLength == 0 {
            current.synthesisDone = true
            completeIfDrained(current)
            return
        }
        current.sourceFormat = buffer.format
        guard let converted = convert(buffer) else {
            current.finished = true
            onEvent?(.failed(index: current.index))
            return
        }
        current.scheduled += 1
        player.scheduleBuffer(converted, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, token == self.generation, let playing = self.playback else { return }
                    playing.played += 1
                    self.completeIfDrained(playing)
                }
            }
        }
        if !current.started {
            current.started = true
            player.play()
            onEvent?(.started(index: current.index))
        }
    }

    private func completeIfDrained(_ current: Playback) {
        guard current.synthesisDone, current.played >= current.scheduled, !current.finished else { return }
        current.finished = true
        onEvent?(.finished(index: current.index))
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == playbackFormat { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: playbackFormat)
        }
        guard let converter else { return nil }
        let ratio = playbackFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: capacity) else {
            return nil
        }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || failure != nil ? nil : output
    }

    private func restartAfterConfigurationChange() {
        guard running, !engine.isRunning else { return }
        do {
            try engine.start()
            if playback?.started == true { player.play() }
        } catch {
            onFailure?("audio_engine_restart_failed")
        }
    }
}

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
    private let inference: any VoiceModelInference
    private let activity = VoiceActivityBox()
    private let playbackFormat: AVAudioFormat
    private var playback: Playback?
    private var synthesis: Task<Void, Never>?
    private var receiving: Task<Void, Never>?
    private var generation = 0
    private var running = false
    private var hasTap = false
    private var playerAttached = false
    private var configurationObserver: (any NSObjectProtocol)?

    init(inference: any VoiceModelInference) {
        self.inference = inference
        playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    }

    func start() throws {
        guard !running else { return }
        defer { if !running { stop() } }
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
        playerAttached = true
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw VoiceDuplexError.noInputFormat }
        let box = activity
        box.reset()
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            let duration = Double(buffer.frameLength) / buffer.format.sampleRate
            let change = box.process(level: EnergyVoiceActivityDetector.level(of: buffer), duration: duration)
            guard let copied = Self.copyMicrophoneBuffer(buffer) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    self.onMicrophone?(copied)
                    if let change { self.onVoiceActivity?(change) }
                }
            }
        }
        hasTap = true
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
        running = false
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        haltPlayback()
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        engine.stop()
        if playerAttached {
            engine.detach(player)
            playerAttached = false
        }
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    nonisolated static func copyMicrophoneBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            return nil
        }
        destination.frameLength = source.frameLength
        let inputs = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let outputs = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        for index in inputs.indices {
            guard let input = inputs[index].mData, let output = outputs[index].mData else { return nil }
            output.copyMemory(from: input, byteCount: Int(inputs[index].mDataByteSize))
        }
        return destination
    }

    func setVolume(_ volume: Float) {
        player.volume = volume
    }

    func speak(index: Int, text: String) {
        guard running, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onEvent?(.failed(index: index))
            return
        }
        haltPlayback()
        generation += 1
        let token = generation
        let current = Playback(index: index, text: text)
        playback = current
        let (stream, continuation) = AsyncStream<SynthesisEvent>.makeStream()
        let inference = inference
        synthesis = Task.detached {
            do {
                try await inference.synthesize(text) { samples in continuation.yield(.audio(samples)) }
                if !Task.isCancelled { continuation.yield(.finished) }
            } catch {
                if !Task.isCancelled { continuation.yield(.failed) }
            }
            continuation.finish()
        }
        receiving = Task { [weak self] in
            for await event in stream {
                guard let self, token == self.generation, !Task.isCancelled else { return }
                switch event {
                case .audio(let samples): self.receive(samples: samples, token: token)
                case .finished:
                    current.synthesisDone = true
                    self.completeIfDrained(current)
                case .failed:
                    self.haltPlayback()
                    self.onEvent?(.failed(index: index))
                }
            }
        }
    }

    func stopSpeaking() { haltPlayback() }

    func playedProgress() -> VoiceSpeechProgress? {
        guard let current = playback, current.started, !current.finished else { return nil }
        // The model emits no word alignment, so interrupted speech never claims an estimated prefix was heard.
        return VoiceSpeechProgress(index: current.index, characters: 0)
    }

    private func haltPlayback() {
        generation += 1
        synthesis?.cancel()
        receiving?.cancel()
        synthesis = nil
        receiving = nil
        player.stop()
        playback = nil
    }

    private enum SynthesisEvent: Sendable {
        case audio([Float])
        case finished
        case failed
    }

    private func receive(samples: [Float], token: Int) {
        guard token == generation, let current = playback else { return }
        guard !samples.isEmpty else { return }
        guard
            let converted = AVAudioPCMBuffer(
                pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = converted.floatChannelData?[0]
        else {
            current.finished = true
            onEvent?(.failed(index: current.index))
            return
        }
        converted.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
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
        onEvent?(current.scheduled > 0 ? .finished(index: current.index) : .failed(index: current.index))
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

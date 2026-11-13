// One AVAudioEngine graph with voice processing for echo cancellation that carries microphone capture and synthesized speech together.
// VoicePipeline reads cleaned microphone buffers and voice activity from it and plays sentences through it so the echo canceller hears the reference signal.

import AVFoundation
import Foundation
import OSLog

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
    case audioStartFailed
}

@MainActor
final class VoiceSentenceAudio {
    private let player: AVAudioPlayerNode
    private let format: AVAudioFormat
    private var buffers: [AVAudioPCMBuffer] = []
    private var frames = 0
    private var played = false
    var count: Int { buffers.count }

    init(player: AVAudioPlayerNode, format: AVAudioFormat) {
        self.player = player
        self.format = format
    }

    func append(_ samples: [Float]) -> Bool {
        guard !played, samples.allSatisfy(\.isFinite), frames + samples.count <= 2_880_000 else { return false }
        guard !samples.isEmpty else { return true }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        buffers.append(buffer)
        frames += samples.count
        return true
    }

    func play(onPlayed: @escaping @Sendable () -> Void) {
        guard !played else { return }
        played = true
        for buffer in buffers {
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in onPlayed() }
        }
        buffers.removeAll()
        player.play()
    }
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
    private static let log = Logger(subsystem: "com.personalailabs.astraldeep.voice", category: "duplex")
    private final class Playback {
        let index: Int
        let text: String
        var scheduled = 0
        var played = 0
        var synthesisDone = false
        var started = false
        var finished = false
        let audio: VoiceSentenceAudio

        init(index: Int, text: String, audio: VoiceSentenceAudio) {
            self.index = index
            self.text = text
            self.audio = audio
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
        let inputFormat = input.outputFormat(forBus: 0)
        let format = try Self.captureFormat(sampleRate: inputFormat.sampleRate, channelCount: inputFormat.channelCount)
        Self.connectPlayback(in: engine, player: player, playbackFormat: playbackFormat, duplexFormat: format)
        Self.log.info(
            "audio_format source_channels=\(inputFormat.channelCount, privacy: .public) capture_hz=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public) pcm=\(format.commonFormat.rawValue, privacy: .public) interleaved=\(format.isInterleaved, privacy: .public) speech_hz=\(self.playbackFormat.sampleRate, privacy: .public)"
        )
        let box = activity
        box.reset()
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard buffer.format.channelCount == 1, buffer.floatChannelData != nil else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.running else { return }
                        self.onFailure?("audio_capture_format_unavailable")
                    }
                }
                return
            }
            let duration = Double(buffer.frameLength) / buffer.format.sampleRate
            let level = EnergyVoiceActivityDetector.level(of: buffer)
            let change = box.process(level: level, duration: duration)
            guard let copied = Self.copyMicrophoneBuffer(buffer) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    self.onMicrophone?(copied)
                    if let change {
                        Self.log.info(
                            "audio_voice_activity active=\(change, privacy: .public) rms=\(level, privacy: .public) buffer_seconds=\(duration, privacy: .public)"
                        )
                        self.onVoiceActivity?(change)
                    }
                }
            }
        }
        hasTap = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            let failure = error as NSError
            Self.log.error(
                "audio_start failed domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)")
            throw VoiceDuplexError.audioStartFailed
        }
        running = true
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAfterConfigurationChange() }
        }
    }

    static func connectPlayback(
        in engine: AVAudioEngine, player: AVAudioPlayerNode, playbackFormat: AVAudioFormat,
        duplexFormat: AVAudioFormat
    ) {
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: duplexFormat)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
    }

    static func captureFormat(sampleRate: Double, channelCount: AVAudioChannelCount) throws -> AVAudioFormat {
        guard sampleRate.isFinite, sampleRate > 0, channelCount > 0,
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        else { throw VoiceDuplexError.noInputFormat }
        return format
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
        let current = Playback(
            index: index, text: text, audio: VoiceSentenceAudio(player: player, format: playbackFormat))
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
                    self.play(current, token: token)
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
        guard current.audio.append(samples) else {
            current.finished = true
            onEvent?(.failed(index: current.index))
            return
        }
    }

    private func play(_ current: Playback, token: Int) {
        current.scheduled = current.audio.count
        guard current.scheduled > 0 else { return }
        current.started = true
        current.audio.play { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, token == self.generation, let playing = self.playback else { return }
                    playing.played += 1
                    self.completeIfDrained(playing)
                }
            }
        }
        onEvent?(.started(index: current.index))
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

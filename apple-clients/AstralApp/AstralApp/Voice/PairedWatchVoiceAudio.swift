// Adapts paired-Watch PCM to the same on-device recognizer and sends locally synthesized PCM back for Watch playback.
// Speech is recorded as finished only after the Watch acknowledges its actual audio completion.

import AVFoundation
import AstralCore
import AstralVoiceSpeech
import Foundation

private nonisolated final class PairedWatchSpeechBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var valid = true

    func append(_ next: [Float]) {
        lock.withLock {
            guard valid, next.count <= 2_880_000 - samples.count, next.allSatisfy(\.isFinite) else {
                valid = false
                samples.removeAll()
                return
            }
            samples.append(contentsOf: next)
        }
    }

    func take() throws -> [Float] {
        try lock.withLock {
            guard valid, !samples.isEmpty else { throw CompanionVoiceError.invalidPacket }
            let result = samples
            samples.removeAll()
            return result
        }
    }
}

@MainActor
final class PairedWatchVoiceAudio: VoiceDuplexAudio {
    typealias Send = @MainActor (CompanionVoicePacket.Kind, Data) async throws -> Void
    var onEvent: ((VoiceSpeechEvent) -> Void)?
    var onMicrophone: ((AVAudioPCMBuffer) -> Void)?
    var onVoiceActivity: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var onPlaybackFinished: (() -> Void)?
    private let voice: any VoiceSpeaking
    private let send: Send
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var detector = EnergyVoiceActivityDetector()
    private var running = false
    private var synthesis: Task<Void, Never>?
    private var generation = 0
    private var speech: CompanionVoiceSpeech?
    private var pendingSpeechId: UUID?
    private var started = false

    init(voice: any VoiceSpeaking, send: @escaping Send) {
        self.voice = voice
        self.send = send
    }

    func start() throws {
        running = true
        detector.reset()
    }

    func stop() {
        running = false
        stopSpeaking()
        detector.reset()
    }

    func receiveCapture(_ pcm: Data) throws {
        guard running, !pcm.isEmpty, pcm.count <= 3_200, pcm.count.isMultiple(of: 2) else {
            throw CompanionVoiceError.invalidPacket
        }
        let frames = pcm.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
            let output = buffer.floatChannelData?[0]
        else { throw CompanionVoiceError.invalidPacket }
        buffer.frameLength = AVAudioFrameCount(frames)
        let bytes = [UInt8](pcm)
        for frame in 0..<frames {
            let sample = UInt16(bytes[frame * 2]) | UInt16(bytes[frame * 2 + 1]) << 8
            output[frame] = Float(Int16(bitPattern: sample)) / 32_768
        }
        let change = detector.process(
            level: EnergyVoiceActivityDetector.level(of: buffer), duration: Double(frames) / 16_000)
        onMicrophone?(buffer)
        if let change { onVoiceActivity?(change) }
    }

    func speak(index: Int, text: String) {
        stopSpeaking()
        guard running else { return }
        let token = generation
        let speechId = UUID()
        pendingSpeechId = speechId
        let voice = voice
        synthesis = Task { [weak self] in
            do {
                let buffer = PairedWatchSpeechBuffer()
                for try await piece in try await voice.speak(text) {
                    guard piece.sampleRate == 24_000 else {
                        throw SpeechSynthesisError.synthesisFailed("unsupported sample rate \(piece.sampleRate)")
                    }
                    buffer.append(piece.samples)
                }
                try Task.checkCancellation()
                let samples = try buffer.take()
                guard let self, self.running, self.generation == token else { return }
                let speech = CompanionVoiceSpeech(id: speechId, index: index, text: text, frames: samples.count)
                self.speech = speech
                self.pendingSpeechId = nil
                self.started = false
                try await self.send(.speechStart, speech.encoded())
                var pcm = Data(count: samples.count * 2)
                pcm.withUnsafeMutableBytes { storage in
                    let bytes = storage.bindMemory(to: UInt8.self)
                    for position in samples.indices {
                        let value = UInt16(bitPattern: Int16((max(-1, min(1, samples[position])) * 32_767).rounded()))
                        bytes[position * 2] = UInt8(value & 255)
                        bytes[position * 2 + 1] = UInt8(value >> 8)
                    }
                }
                for offset in stride(from: 0, to: pcm.count, by: 4_800) {
                    try Task.checkCancellation()
                    guard self.running, self.generation == token else { return }
                    try await self.send(.speechPCM, pcm.subdata(in: offset..<min(offset + 4_800, pcm.count)))
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == token else { return }
                self.speech = nil
                self.onEvent?(.failed(index: index))
                self.onFailure?("watch_audio_unavailable")
            }
        }
    }

    func receivePlayback(_ packet: CompanionVoicePacket) throws {
        guard let text = String(data: packet.payload, encoding: .utf8), let id = UUID(uuidString: text)
        else { throw CompanionVoiceError.invalidPacket }
        guard let speech, speech.id == id else { return }
        switch packet.kind {
        case .playbackStarted:
            guard !started else { throw CompanionVoiceError.invalidSequence }
            started = true
            onEvent?(.started(index: speech.index))
        case .playbackFinished:
            guard started else { throw CompanionVoiceError.invalidSequence }
            self.speech = nil
            onEvent?(.finished(index: speech.index))
            onPlaybackFinished?()
        default: throw CompanionVoiceError.invalidPacket
        }
    }

    func playedProgress() -> VoiceSpeechProgress? {
        guard let speech, started else { return nil }
        return VoiceSpeechProgress(index: speech.index, characters: 0)
    }

    func stopSpeaking() {
        let id = speech?.id ?? pendingSpeechId
        generation &+= 1
        synthesis?.cancel()
        synthesis = nil
        speech = nil
        pendingSpeechId = nil
        started = false
        guard let id else { return }
        let send = send
        Task { try? await send(.stopSpeech, Data(id.uuidString.utf8)) }
    }

    func stopSpeaking(id: UUID) -> Bool {
        guard speech?.id == id || pendingSpeechId == id else { return false }
        stopSpeaking()
        return true
    }

    func setVolume(_ volume: Float) {
        guard volume.isFinite, (0...1).contains(volume) else {
            onFailure?("watch_audio_unavailable")
            return
        }
        guard let id = speech?.id ?? pendingSpeechId else { return }
        let send = send
        Task { try? await send(.volume, Data(id.uuidString.utf8) + Data([UInt8((volume * 100).rounded())])) }
    }
}

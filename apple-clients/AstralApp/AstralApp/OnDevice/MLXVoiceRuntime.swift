// Adapts the downloaded LFM3 model to the voice pipeline's recognition, speech and acknowledgement interfaces.
// Every inference stays in MLX on this device; cancellation fences results from retired microphone segments.

import AVFoundation
import AstralVoiceModel
import AstralVoiceRuntime
import AstralVoiceSpeech
import Foundation

nonisolated struct MLXVoiceInference: VoiceRecognizing, VoiceSpeaking, VoiceTextGenerating {
    let engine: LFM3AudioEngine

    func recognize(_ audio: [Float], language: RecognitionLanguage) async throws -> String {
        // LFM3 detects the spoken language itself, so the requested language is unused here.
        var options = LFM3Sampling()
        options.maxNewTokens = 256
        return try await engine.transcribe(audio: audio, options: options, handlers: LFM3Handlers()).text
    }

    func speak(_ sentence: String) async throws -> AsyncThrowingStream<SpeechAudioBuffer, Error> {
        let engine = engine
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let handlers = LFM3Handlers(onAudio: {
                        continuation.yield(SpeechAudioBuffer(samples: $0, sampleRate: 24_000))
                    })
                    let result = try await engine.synthesize(text: sentence, handlers: handlers)
                    guard !result.stoppedByLength else {
                        throw LFM3Error.invalidInput("speech exceeded its token limit")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func generate(_ request: OnDeviceRequest) -> AsyncThrowingStream<String, Error> {
        let engine = engine
        let messages = Self.messages(for: request)
        var options = LFM3Sampling()
        options.maxNewTokens = request.maxTokens
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await engine.chat(messages: messages, options: options).text
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func messages(for request: OnDeviceRequest) -> [LFM3Message] {
        request.messages.map { message in
            switch message.role {
            case .system: LFM3Message(role: .system, text: message.text)
            case .user: LFM3Message(role: .user, text: message.text)
            case .assistant: LFM3Message(role: .assistant, text: message.text)
            case .tool: LFM3Message(role: .user, text: "[Untrusted tool output]\n" + message.text)
            }
        }
    }
}

nonisolated struct MLXVoiceAcknowledgementModel: AstralOnDeviceModel {
    let inference: any VoiceTextGenerating

    func available() -> Bool { true }

    func complete(_ request: OnDeviceRequest) async -> OnDeviceResponse {
        guard request.schemaJSON == nil else { return .failed(.schemaUnsupported) }
        guard !request.messages.isEmpty else { return .failed(.emptyRequest) }
        do {
            try Task.checkCancellation()
            let text = try await inference.generate(request).collected()
            try Task.checkCancellation()
            return .text(text)
        } catch is CancellationError {
            return .failed(.cancelled)
        } catch {
            return .failed(.generationFailed)
        }
    }
}

nonisolated final class MLXVoiceTranscriber: VoiceStreamingTranscriber, @unchecked Sendable {
    private final class Segment {
        let id = UUID()
        var samples: [Float] = []
        var lastRequested = 0
        var partial: Task<Void, Never>?
        var needsFlush = false
    }

    let kind = VoiceTranscriberKind.mlx
    private let inference: any VoiceRecognizing
    private let language: RecognitionLanguage
    private let lock = NSLock()
    private var handler: (@Sendable (VoiceRecognizerEvent) -> Void)?
    private var current: Segment?
    private var finals: [UUID: Task<Void, Never>] = [:]
    private var converter: AVAudioConverter?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private let maximumSamples = 30 * 16_000
    private let partialInterval = 8_000

    init(inference: any VoiceRecognizing, language: RecognitionLanguage = .english) {
        self.inference = inference
        self.language = language
    }

    var segmentID: UUID? { lock.withLock { current?.id } }

    func setEventHandler(_ handler: @escaping @Sendable (VoiceRecognizerEvent) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func prepare() async throws { try Task.checkCancellation() }

    func beginSegment() throws {
        lock.withLock {
            current?.partial?.cancel()
            current = Segment()
            converter?.reset()
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let current else { return }
            guard let samples = samples(from: buffer) else {
                handler?(.failed("voice_audio_format_unavailable"))
                return
            }
            guard current.samples.count + samples.count <= maximumSamples else {
                current.partial?.cancel()
                self.current = nil
                handler?(.failed("voice_segment_too_long"))
                return
            }
            current.samples.append(contentsOf: samples)
            if current.samples.count - current.lastRequested >= partialInterval { requestPartial(current) }
        }
    }

    func flushPartial() {
        lock.withLock {
            guard let current, !current.samples.isEmpty else { return }
            if current.partial != nil { current.needsFlush = true } else { requestPartial(current) }
        }
    }

    private func requestPartial(_ segment: Segment) {
        guard segment.partial == nil else { return }
        segment.needsFlush = false
        segment.lastRequested = segment.samples.count
        let audio = segment.samples
        let id = segment.id
        let inference = inference
        let language = language
        segment.partial = Task { [weak self] in
            do {
                let text = try await inference.recognize(audio, language: language)
                guard !Task.isCancelled else { return }
                self?.partialFinished(id: id, text: text)
            } catch {
                if !Task.isCancelled { self?.partialFinished(id: id, text: nil) }
            }
        }
    }

    func endSegment() {
        lock.withLock {
            guard let current else { return }
            self.current = nil
            current.partial?.cancel()
            let id = current.id
            let audio = current.samples
            let inference = inference
            finals[id] = Task { [weak self] in
                do {
                    let text = audio.isEmpty ? "" : try await inference.recognize(audio, language: language)
                    guard !Task.isCancelled else { return }
                    self?.finalFinished(id: id, event: .final(text, segmentID: id))
                } catch {
                    if !Task.isCancelled { self?.finalFinished(id: id, event: .failed("voice_recognition_failed")) }
                }
            }
        }
    }

    func cancelSegment() {
        lock.withLock {
            current?.partial?.cancel()
            current = nil
        }
    }

    func shutdown() {
        lock.withLock {
            current?.partial?.cancel()
            current = nil
            for task in finals.values { task.cancel() }
            finals = [:]
            handler = nil
            converter = nil
        }
    }

    private func partialFinished(id: UUID, text: String?) {
        let callback = lock.withLock { () -> (@Sendable (VoiceRecognizerEvent) -> Void)? in
            guard current?.id == id else { return nil }
            current?.partial = nil
            if let current, current.needsFlush, current.samples.count > current.lastRequested {
                requestPartial(current)
            }
            return handler
        }
        if let text { callback?(.partial(text, segmentID: id)) }
    }

    private func finalFinished(id: UUID, event: VoiceRecognizerEvent) {
        let callback = lock.withLock { () -> (@Sendable (VoiceRecognizerEvent) -> Void)? in
            guard finals.removeValue(forKey: id) != nil else { return nil }
            return handler
        }
        callback?(event)
    }

    private func samples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        if buffer.format == format, let data = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter,
            let output = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 1_024
            )
        else { return nil }
        var supplied = false
        var failure: NSError?
        let result = converter.convert(to: output, error: &failure) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard result != .error, failure == nil, let data = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}

@MainActor
enum MLXVoiceRuntime {
    static func pipeline(directory: URL, link: VoiceKernelLink) async throws -> VoicePipeline {
        let inference = try await VoiceInferenceCache.shared.inference(directory: directory)
        try Task.checkCancellation()
        return VoicePipeline(
            audio: VoiceDuplexEngine(speech: inference), transcriber: MLXVoiceTranscriber(inference: inference),
            fastPath: VoiceFastPath(model: MLXVoiceAcknowledgementModel(inference: inference)), link: link)
    }
}

// Streams microphone audio through any VoiceRecognizing as growing-segment partials and one final transcript per segment, in the language the owner chose for the conversation.
// VoicePipeline drives it as a VoiceStreamingTranscriber and MLXVoiceTranscriber is a thin subclass of it; a segment that has ended or been cancelled never delivers a result.

import AVFoundation
import AstralVoiceRuntime
import Foundation

nonisolated class RumbleTranscriber: VoiceStreamingTranscriber, @unchecked Sendable {
    private final class Segment {
        let id = UUID()
        var samples: [Float] = []
        var lastRequested = 0
        var partial: Task<Void, Never>?
        var needsFlush = false
    }

    let kind: VoiceTranscriberKind
    private let inference: any VoiceRecognizing
    private let language: @Sendable () -> RecognitionLanguage
    private let lock = NSLock()
    private var handler: (@Sendable (VoiceRecognizerEvent) -> Void)?
    private var current: Segment?
    private var finals: [UUID: Task<Void, Never>] = [:]
    private var converter: AVAudioConverter?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private let maximumSamples = 30 * 16_000
    private let partialInterval = 8_000

    init(
        recognizer: any VoiceRecognizing, kind: VoiceTranscriberKind = .rumble,
        language: @escaping @Sendable () -> RecognitionLanguage = { ConversationLanguage.saved().recognitionLanguage }
    ) {
        inference = recognizer
        self.kind = kind
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
        let language = language()
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
            let language = language()
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

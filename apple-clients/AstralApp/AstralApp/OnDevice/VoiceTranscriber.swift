// Streaming on-device transcription: SpeechAnalyzer with SpeechTranscriber on the newest systems and SFSpeechRecognizer with partial results before that.
// VoicePipeline feeds microphone buffers in and reads partial and final transcript events out, and no audio or text leaves the device.

import AVFoundation
import Foundation
import Speech

nonisolated enum VoiceRecognizerEvent: Equatable, Sendable {
    case partial(String, segmentID: UUID? = nil)
    case final(String, segmentID: UUID? = nil)
    case failed(String)
}

nonisolated enum VoiceTranscriberKind: String, Equatable, Sendable {
    case mlx
    case speechAnalyzer = "speech_analyzer"
    case onDeviceRecognizer = "on_device_recognizer"
}

nonisolated enum VoiceTranscriberError: Error, Equatable {
    case permissionNotGranted
    case recognizerUnavailable
    case onDeviceRecognitionUnsupported
    case assetsNotInstalled
    case noCompatibleAudioFormat
}

nonisolated protocol VoiceStreamingTranscriber: AnyObject, Sendable {
    var kind: VoiceTranscriberKind { get }
    var segmentID: UUID? { get }
    func setEventHandler(_ handler: @escaping @Sendable (VoiceRecognizerEvent) -> Void)
    func prepare() async throws
    func beginSegment() throws
    func append(_ buffer: AVAudioPCMBuffer)
    func flushPartial()
    func endSegment()
    func cancelSegment()
    func shutdown()
}

extension VoiceStreamingTranscriber {
    nonisolated var segmentID: UUID? { nil }
    nonisolated func flushPartial() {}
}

nonisolated struct VoiceTranscriberSelection {
    let transcriber: any VoiceStreamingTranscriber
    let fallbackReason: String?
}

nonisolated enum VoiceTranscriberFactory {
    static func select(locale: Locale) async -> Result<VoiceTranscriberSelection, VoiceTranscriberError> {
        var fallbackReason: String?
        if #available(iOS 26.0, macOS 26.0, *) {
            let analyzer = SpeechAnalyzerTranscriber(locale: locale)
            do {
                try await analyzer.prepare()
                return .success(VoiceTranscriberSelection(transcriber: analyzer, fallbackReason: nil))
            } catch let error as VoiceTranscriberError {
                fallbackReason = "speech_analyzer_\(error)"
            } catch {
                fallbackReason = "speech_analyzer_failed"
            }
        } else {
            fallbackReason = "os_version_too_old"
        }
        let recognizer = SFSpeechStreamingTranscriber(locale: locale)
        do {
            try await recognizer.prepare()
            return .success(
                VoiceTranscriberSelection(transcriber: recognizer, fallbackReason: fallbackReason))
        } catch let error as VoiceTranscriberError {
            return .failure(error)
        } catch {
            return .failure(.recognizerUnavailable)
        }
    }
}

nonisolated final class SFSpeechStreamingTranscriber: VoiceStreamingTranscriber, @unchecked Sendable {
    private nonisolated final class Segment {
        let request = SFSpeechAudioBufferRecognitionRequest()
        var task: SFSpeechRecognitionTask?
        var ended = false
        var lastText = ""
    }

    let kind = VoiceTranscriberKind.onDeviceRecognizer
    private let locale: Locale
    private let lock = NSLock()
    private var recognizer: SFSpeechRecognizer?
    private var handler: (@Sendable (VoiceRecognizerEvent) -> Void)?
    private var segment: Segment?

    init(locale: Locale) {
        self.locale = locale
    }

    func setEventHandler(_ handler: @escaping @Sendable (VoiceRecognizerEvent) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func prepare() async throws {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw VoiceTranscriberError.permissionNotGranted
        }
        guard let candidate = SFSpeechRecognizer(locale: locale), candidate.isAvailable else {
            throw VoiceTranscriberError.recognizerUnavailable
        }
        guard candidate.supportsOnDeviceRecognition else {
            throw VoiceTranscriberError.onDeviceRecognitionUnsupported
        }
        lock.withLock { recognizer = candidate }
    }

    func beginSegment() throws {
        guard let recognizer = lock.withLock({ self.recognizer }) else {
            throw VoiceTranscriberError.recognizerUnavailable
        }
        let current = Segment()
        current.request.shouldReportPartialResults = true
        current.request.requiresOnDeviceRecognition = true
        current.request.addsPunctuation = true
        current.task = recognizer.recognitionTask(with: current.request) { [weak self, weak current] result, error in
            guard let self, let current else { return }
            self.consume(result, error: error, segment: current)
        }
        lock.withLock {
            segment?.task?.cancel()
            segment = current
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { segment }?.request.append(buffer)
    }

    func endSegment() {
        lock.withLock {
            segment?.ended = true
            segment?.request.endAudio()
            segment = nil
        }
    }

    func cancelSegment() {
        lock.withLock {
            segment?.task?.cancel()
            segment = nil
        }
    }

    func shutdown() {
        cancelSegment()
        lock.withLock { handler = nil }
    }

    private func consume(_ result: SFSpeechRecognitionResult?, error: (any Error)?, segment: Segment) {
        let (handler, ended) = lock.withLock { (self.handler, segment.ended) }
        if let result {
            let text = result.bestTranscription.formattedString
            segment.lastText = text
            if result.isFinal {
                handler?(.final(text))
            } else if !ended {
                handler?(.partial(text))
            }
            return
        }
        guard error != nil else { return }
        if ended {
            handler?(.final(segment.lastText))
        } else if !lock.withLock({ self.segment !== segment }) {
            handler?(.failed("local_recognition_failed"))
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
nonisolated final class SpeechAnalyzerTranscriber: VoiceStreamingTranscriber, @unchecked Sendable {
    private nonisolated final class Segment {
        let analyzer: SpeechAnalyzer
        let input: AsyncStream<AnalyzerInput>.Continuation
        var tasks: [Task<Void, Never>] = []
        var ended = false
        var converter: AVAudioConverter?

        init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation) {
            self.analyzer = analyzer
            self.input = input
        }
    }

    let kind = VoiceTranscriberKind.speechAnalyzer
    private let locale: Locale
    private let lock = NSLock()
    private var resolvedLocale: Locale?
    private var analyzerFormat: AVAudioFormat?
    private var handler: (@Sendable (VoiceRecognizerEvent) -> Void)?
    private var segment: Segment?

    init(locale: Locale) {
        self.locale = locale
    }

    func setEventHandler(_ handler: @escaping @Sendable (VoiceRecognizerEvent) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func prepare() async throws {
        guard SpeechTranscriber.isAvailable,
            let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else { throw VoiceTranscriberError.recognizerUnavailable }
        let module = Self.makeTranscriber(locale: supported)
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw VoiceTranscriberError.assetsNotInstalled
        }
        _ = try? await AssetInventory.reserve(locale: supported)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw VoiceTranscriberError.noCompatibleAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: format)
        lock.withLock {
            resolvedLocale = supported
            analyzerFormat = format
        }
    }

    func beginSegment() throws {
        guard let resolved = lock.withLock({ resolvedLocale }) else {
            throw VoiceTranscriberError.recognizerUnavailable
        }
        let module = Self.makeTranscriber(locale: resolved)
        let analyzer = SpeechAnalyzer(modules: [module])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let current = Segment(analyzer: analyzer, input: continuation)
        current.tasks.append(
            Task { try? await analyzer.start(inputSequence: stream) })
        current.tasks.append(
            Task { [weak self, weak current] in
                var finalized = ""
                do {
                    for try await result in module.results {
                        guard let self, let current else { return }
                        let text = String(result.text.characters)
                        if result.isFinal {
                            finalized = Self.join(finalized, text)
                            self.emit(.partial(finalized), segment: current)
                        } else {
                            self.emit(.partial(Self.join(finalized, text)), segment: current)
                        }
                    }
                    if let self, let current { self.emit(.final(finalized), segment: current, force: true) }
                } catch {
                    if let self, let current {
                        self.emit(
                            current.ended ? .final(finalized) : .failed("local_recognition_failed"),
                            segment: current, force: true)
                    }
                }
            })
        lock.withLock {
            segment?.input.finish()
            segment = current
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let (current, format) = lock.withLock { (segment, analyzerFormat) }
        guard let current, let format, let converted = Self.convert(buffer, to: format, segment: current)
        else { return }
        current.input.yield(AnalyzerInput(buffer: converted))
    }

    func endSegment() {
        let current = lock.withLock { () -> Segment? in
            let finished = segment
            finished?.ended = true
            segment = nil
            return finished
        }
        guard let current else { return }
        current.input.finish()
        Task { try? await current.analyzer.finalizeAndFinishThroughEndOfInput() }
    }

    func cancelSegment() {
        let current = lock.withLock { () -> Segment? in
            let finished = segment
            segment = nil
            return finished
        }
        current?.input.finish()
        for task in current?.tasks ?? [] { task.cancel() }
        if let analyzer = current?.analyzer { Task { await analyzer.cancelAndFinishNow() } }
    }

    func shutdown() {
        cancelSegment()
        lock.withLock { handler = nil }
    }

    private func emit(_ event: VoiceRecognizerEvent, segment: Segment, force: Bool = false) {
        let (handler, ended) = lock.withLock { (self.handler, segment.ended) }
        if case .partial = event, ended, !force { return }
        handler?(event)
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }

    private static func join(_ head: String, _ tail: String) -> String {
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.isEmpty { return trimmed }
        return trimmed.isEmpty ? head : head + " " + trimmed
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, segment: Segment
    ) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if segment.converter == nil || segment.converter?.inputFormat != buffer.format {
            segment.converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter = segment.converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
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
}

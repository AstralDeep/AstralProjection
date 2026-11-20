// Transcribes 16 kHz mono audio with a Qwen3-ASR style model and its audio encoder, streaming text as tokens are produced.
// A voice pipeline calls it repeatedly on a growing segment and cancels stale calls; each call takes a scheduler slot, pads the clip with AudioPadding and honours cooperative cancellation.
import CAstralLlama
import Dispatch
import Foundation

public struct Transcription: Sendable, Equatable {
    public let text: String
    public let tokenCount: Int
    public let stop: StopReason
    public let paddedSampleCount: Int
}

public struct RecognitionStyle: Sendable, Equatable {
    public var digits = true
    public var fillers = false
    public var verbatim = true

    public init(digits: Bool = true, fillers: Bool = false, verbatim: Bool = true) {
        self.digits = digits
        self.fillers = fillers
        self.verbatim = verbatim
    }

    var tags: String {
        (digits ? "<digits>" : "<nodigits>") + (fillers ? "<filler>" : "<nofiller>") + (verbatim ? "<verbatim>" : "<noverbatim>")
    }
}

public actor SpeechRecognizer {
    public static let maximumSeconds = 30

    private let native: NativeModel
    private let queue: DispatchSerialQueue
    private let scheduler: RuntimeScheduler

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private init(native: NativeModel, queue: DispatchSerialQueue, scheduler: RuntimeScheduler) {
        self.native = native
        self.queue = queue
        self.scheduler = scheduler
    }

    public static func load(
        model: URL,
        audioEncoder: URL,
        configuration: RuntimeConfiguration = RuntimeConfiguration(),
        scheduler: RuntimeScheduler = .shared
    ) async throws -> SpeechRecognizer {
        let queue = ModelQueue.make("recognition")
        let native = try await ModelQueue.load(on: queue) {
            try NativeModel.load(model: model, encoder: audioEncoder, configuration: configuration)
        }
        return SpeechRecognizer(native: native, queue: queue, scheduler: scheduler)
    }

    public func unload() {
        native.close()
    }

    public nonisolated func transcribe(
        _ samples: [Float],
        language: RecognitionLanguage,
        style: RecognitionStyle = RecognitionStyle(),
        maxTokens: Int = 160,
        onText: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Transcription {
        guard !samples.isEmpty else { throw VoiceRuntimeError.emptyAudio }
        guard samples.count <= Self.maximumSeconds * AudioPadding.sampleRate else {
            throw VoiceRuntimeError.audioTooLong(maximumSeconds: Self.maximumSeconds)
        }
        guard maxTokens > 0 else { throw VoiceRuntimeError.invalidTokenLimit(maxTokens) }
        let padded = AudioPadding.padded(samples)
        let prompt = "<|im_start|>system\n\(style.tags)<|im_end|>\n<|im_start|>user\n<__media__><|im_end|>\n<|im_start|>assistant\nlanguage \(language.englishName)<asr_text>"
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await scheduler.perform(.recognition) {
                try await self.run(prompt: prompt, samples: padded, limit: maxTokens, flag: flag, onText: onText)
            }
        } onCancel: {
            flag.raise()
        }
    }

    public nonisolated func stream(
        _ samples: [Float],
        language: RecognitionLanguage,
        style: RecognitionStyle = RecognitionStyle(),
        maxTokens: Int = 160
    ) -> AsyncThrowingStream<String, Error> {
        textStream { emit in
            _ = try await self.transcribe(samples, language: language, style: style, maxTokens: maxTokens, onText: emit)
        }
    }

    private func run(prompt: String, samples: [Float], limit: Int, flag: CancelFlag, onText: @Sendable (String) -> Void) throws -> Transcription {
        try Task.checkCancellation()
        let outcome = try native.recognize(prompt: prompt, samples: samples, limit: limit, cancel: flag, onText: onText)
        return Transcription(text: outcome.text, tokenCount: outcome.tokenCount, stop: outcome.stop, paddedSampleCount: samples.count)
    }
}

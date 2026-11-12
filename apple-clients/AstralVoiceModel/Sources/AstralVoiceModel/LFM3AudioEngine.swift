// The public entry point of the voice model: loads the downloaded files, then runs speech recognition, speech synthesis, speech-to-speech and text chat with streamed text and PCM callbacks.
// The Apple app shares one engine whose request-local cursors yield between slots, letting microphone recognition interrupt synthesis; cancelling the calling task retires that request.

import Foundation
import MLX
import MLXNN

public struct LFM3Sampling: Sendable {
    public var maxNewTokens = 2048
    public var temperature: Float = 0
    public var topK = 0
    public var topP: Float = 1
    public var repetitionPenalty: Float = 1
    public var audioTemperature: Float = 1
    public var audioTopK = 128
    public var audioRepetitionPenalty: Float = 1.1
    public var seed: UInt64?

    public init() {}
}

public struct LFM3Result: Sendable {
    public var text: String
    public var tokenIDs: [Int]
    public var audioFrames: [[Int32]]
    public var stoppedByLength: Bool
    public var generationSeconds: Double
}

public struct LFM3Handlers: Sendable {
    public var onText: (@Sendable (String) -> Void)?
    public var onAudio: (@Sendable ([Float]) -> Void)?

    public init(onText: (@Sendable (String) -> Void)? = nil, onAudio: (@Sendable ([Float]) -> Void)? = nil) {
        self.onText = onText
        self.onAudio = onAudio
    }
}

public actor LFM3AudioEngine {
    public nonisolated let sampleRate: Int
    nonisolated(unsafe) let model: LFM3AudioModel
    let tokenizer: BPETokenizer
    let prompts: PromptBuilder
    nonisolated(unsafe) let codec: LiquidCodec
    private let firstChunkFrames = 3
    private let chunkFrames = 4

    public static let requiredFiles = [
        "config.json", "model.safetensors", "tokenizer.json", "audio_tokenizer/config.json",
        "audio_tokenizer/model.safetensors",
    ]

    public init(directory: URL) throws {
        for file in Self.requiredFiles
        where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) {
            throw LFM3Error.modelFiles("missing \(file)")
        }
        let config = try ModelConfiguration.load(from: directory.appendingPathComponent("config.json"))
        tokenizer = try BPETokenizer(contentsOf: directory.appendingPathComponent("tokenizer.json"))
        prompts = PromptBuilder(tokenizer: tokenizer, audioTokenID: config.audioTokenID)
        let model = LFM3AudioModel(config)
        let weights = try loadArrays(url: directory.appendingPathComponent("model.safetensors"))
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(model)
        self.model = model
        codec = try LiquidCodec.load(
            directory: directory.appendingPathComponent("audio_tokenizer"), dtype: model.weightDType)
        sampleRate = codec.config.sampleRate
    }

    public static func peakMemoryBytes() -> Int { Memory.peakMemory }
    public static func activeMemoryBytes() -> Int { Memory.activeMemory }
    public static func resetPeakMemory() { Memory.peakMemory = 0 }

    public func transcribe(
        audio: [Float], language: String = "English", options: LFM3Sampling = LFM3Sampling(),
        handlers: LFM3Handlers = LFM3Handlers()
    ) async throws -> LFM3Result {
        let messages = [
            LFM3Message(role: .system, text: "Perform ASR in \(language)."),
            LFM3Message(role: .user, parts: [.audio(audio)]),
        ]
        return try await run(messages, mode: .text, options: options, handlers: handlers)
    }

    public func synthesize(
        text: String, language: String = "English", voice: String = "female", options: LFM3Sampling = LFM3Sampling(),
        handlers: LFM3Handlers = LFM3Handlers()
    ) async throws -> LFM3Result {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LFM3Error.invalidInput("speech needs text")
        }
        let messages = [
            LFM3Message(role: .system, text: "Perform TTS in \(language) using a \(voice) voice."),
            LFM3Message(role: .user, text: text),
        ]
        return try await run(messages, mode: .audio, options: options, handlers: handlers)
    }

    public func chat(
        messages: [LFM3Message], options: LFM3Sampling = LFM3Sampling(), handlers: LFM3Handlers = LFM3Handlers()
    ) async throws -> LFM3Result {
        try await run(messages, mode: .text, options: options, handlers: handlers)
    }

    public func speechToSpeech(
        audio: [Float], systemPrompt: String = "Respond with interleaved text and audio.",
        options: LFM3Sampling = LFM3Sampling(), handlers: LFM3Handlers = LFM3Handlers()
    ) async throws -> LFM3Result {
        let messages = [
            LFM3Message(role: .system, text: systemPrompt), LFM3Message(role: .user, parts: [.audio(audio)]),
        ]
        return try await run(messages, mode: nil, options: options, handlers: handlers)
    }

    func run(
        _ messages: [LFM3Message], mode: GenerationMode?, options: LFM3Sampling, handlers: LFM3Handlers,
        frameOrder: [[Int]]? = nil
    ) async throws -> LFM3Result {
        let started = Date()
        let prepared = try prompts.prepare(messages)
        var features: MLXArray?
        if let clip = prepared.clips.first {
            guard prepared.clips.count == 1 else { throw LFM3Error.invalidInput("one audio clip per request") }
            let mel = LogMel.features(clip)
            features = MLXArray(mel.values, [1, LogMel.melBins, mel.frames])
        }
        var generation = GenerationOptions()
        generation.maxNewTokens = options.maxNewTokens
        generation.seed = options.seed
        generation.frameOrder = frameOrder
        generation.text = SamplerSettings(
            temperature: options.temperature, topK: options.topK, topP: options.topP,
            repetitionPenalty: options.repetitionPenalty)
        generation.audio = SamplerSettings(
            temperature: options.audioTemperature, topK: options.audioTopK,
            repetitionPenalty: options.audioRepetitionPenalty)
        let eosCode = Int32(model.config.audioEOSCode)
        let streamer = StreamingCodecDecoder(codec: codec)
        var textTokens = [Int]()
        var allTokens = [Int]()
        var emittedText = ""
        var frames = [[Int32]]()
        var flushed = false
        let cursor = try model.generation(ids: prepared.tokenIDs, features: features, mode: mode, options: generation)
        while let slot = try cursor.next() {
            allTokens.append(slot.token)
            if let codes = slot.codes {
                if codes[0] == eosCode { break }
                frames.append(codes)
                streamer.append(codes)
                if let onAudio = handlers.onAudio, streamer.pendingCount >= (flushed ? chunkFrames : firstChunkFrames) {
                    let pcm = try streamer.flush(final: false)
                    flushed = true
                    if !pcm.isEmpty { onAudio(pcm) }
                }
            } else {
                textTokens.append(slot.token)
                let decoded = tokenizer.decode(textTokens)
                if decoded.count > emittedText.count, !decoded.hasSuffix("\u{FFFD}"), decoded.hasPrefix(emittedText) {
                    handlers.onText?(String(decoded.dropFirst(emittedText.count)))
                    emittedText = decoded
                }
            }
            await Task.yield()
        }
        try Task.checkCancellation()
        if let onAudio = handlers.onAudio, !frames.isEmpty {
            let pcm = try streamer.flush(final: true)
            if !pcm.isEmpty { onAudio(pcm) }
        }
        let text = tokenizer.decode(textTokens)
        if text.count > emittedText.count, text.hasPrefix(emittedText) {
            handlers.onText?(String(text.dropFirst(emittedText.count)))
        }
        return LFM3Result(
            text: text, tokenIDs: allTokens, audioFrames: frames,
            stoppedByLength: allTokens.count >= options.maxNewTokens,
            generationSeconds: Date().timeIntervalSince(started))
    }
}

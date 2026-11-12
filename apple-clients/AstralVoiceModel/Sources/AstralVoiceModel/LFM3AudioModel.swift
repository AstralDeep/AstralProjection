// The LFM3-Audio network: language model, speech encoder and projector, codebook embeddings and depth decoder, with the slot-by-slot generation loop for text, speech and interleaved output.
// LFM3AudioEngine loads it from the downloaded files and drives streamSlots for each task, and the unit tests run it with tiny random weights.

import Foundation
import MLX
import MLXNN

enum GenerationMode {
    case text, audio, interleaved
}

struct GenerationOptions: Sendable {
    var maxNewTokens = 2048
    var text = SamplerSettings(temperature: 0)
    var audio = SamplerSettings(temperature: 1, topK: 128, repetitionPenalty: 1.1)
    var audioRepetitionWindow = 4096
    var textRepetitionWindow = 32
    var seed: UInt64?
    var frameOrder: [[Int]]?
}

struct GeneratedSlot {
    let token: Int
    let codes: [Int32]?
}

final class LanguageModelShell: Module {
    @ModuleInfo(key: "model") var model: BackboneModel
    @ModuleInfo(key: "lm_head") var head: Linear?

    init(_ config: BackboneConfiguration) {
        _model.wrappedValue = BackboneModel(config, embeddings: true)
        if !config.tieWordEmbeddings {
            _head.wrappedValue = Linear(config.hiddenSize, config.vocabSize, bias: false)
        }
        super.init()
    }
}

public final class LFM3AudioModel: Module {
    let config: ModelConfiguration

    @ModuleInfo(key: "language_model") var languageModel: LanguageModelShell
    @ModuleInfo(key: "audio_tower") var audioTower: AudioEncoder
    @ModuleInfo(key: "audio_projector") var audioProjector: AudioProjector
    @ModuleInfo(key: "codebook_embedding") var codebookEmbedding: Embedding
    @ModuleInfo(key: "depth_decoder") var depthDecoder: DepthDecoder

    init(_ config: ModelConfiguration) {
        self.config = config
        _languageModel.wrappedValue = LanguageModelShell(config.text)
        _audioTower.wrappedValue = AudioEncoder(config.encoder)
        _audioProjector.wrappedValue = AudioProjector(
            encoderSize: config.encoder.hiddenSize, outputSize: config.text.hiddenSize)
        _codebookEmbedding.wrappedValue = Embedding(
            embeddingCount: config.codebooks * config.codebookSize, dimensions: config.text.hiddenSize)
        _depthDecoder.wrappedValue = DepthDecoder(
            config.depth, inputSize: config.text.hiddenSize, codebooks: config.codebooks,
            codebookSize: config.codebookSize)
        super.init()
        if let quantization = config.quantization {
            quantize(model: languageModel, groupSize: quantization.groupSize, bits: quantization.bits)
        }
    }

    var weightDType: DType { languageModel.model.embeddingNorm.weight.dtype }

    private var suppressedTokens: [Int] { [config.audioTokenID, config.audioOutTokenID] }

    func inputEmbeddings(ids: [Int], features: MLXArray?) throws -> MLXArray {
        guard !ids.contains(config.audioOutTokenID) else {
            throw LFM3Error.invalidInput("speech history is not supported")
        }
        let tokens = MLXArray(ids.map { Int32($0) }).expandedDimensions(axis: 0)
        var embeddings = languageModel.model.embedTokens!(tokens)
        let positions = ids.indices.filter { ids[$0] == config.audioTokenID }
        let rows = try features.map { audioProjector(try audioTower($0)) }
        guard positions.count == (rows?.dim(0) ?? 0) else {
            throw LFM3Error.invalidInput("speech placeholders do not match the supplied audio")
        }
        if let rows, !positions.isEmpty {
            let flat = embeddings.reshaped(-1, embeddings.dim(-1))
            flat[MLXArray(positions.map { Int32($0) })] = rows.asType(embeddings.dtype)
            embeddings = flat.reshaped(embeddings.shape)
        }
        return embeddings
    }

    private func textLogits(_ hidden: MLXArray) -> MLXArray {
        let embed = languageModel.model.embedTokens!
        return config.text.tieWordEmbeddings ? embed.asLinear(hidden) : languageModel.head!(hidden)
    }

    func generation(
        ids: [Int], features: MLXArray?, mode: GenerationMode?, options: GenerationOptions
    ) throws -> GenerationCursor {
        try GenerationCursor(model: self, promptIDs: ids, features: features, requested: mode, options: options)
    }

    func streamSlots(
        ids: [Int], features: MLXArray?, mode: GenerationMode?, options: GenerationOptions,
        emit: (GeneratedSlot) throws -> Bool
    ) throws {
        let cursor = try generation(ids: ids, features: features, mode: mode, options: options)
        while let slot = try cursor.next() {
            if try !emit(slot) { return }
        }
    }

    final class GenerationCursor {
        private let model: LFM3AudioModel
        private let options: GenerationOptions
        private let random: MLXRandom.RandomState
        private let suppressMask: MLXArray
        private let eosIDs: Set<Int>
        private let cache: [LayerCache]
        private var hidden: MLXArray
        private var pendingEmbedding: MLXArray?
        private var mode: GenerationMode
        private var textHistory: [Int32] = []
        private var audioHistory: [[Int32]] = []
        private var slotsLeft: Int
        private var frame = 0
        private var step = 0
        private var speaking = false
        private var textDone = false
        private var finished = false

        init(
            model: LFM3AudioModel, promptIDs: [Int], features: MLXArray?, requested: GenerationMode?,
            options: GenerationOptions
        ) throws {
            guard let last = promptIDs.last, options.maxNewTokens >= 1 else {
                throw LFM3Error.invalidInput("prompt is empty")
            }
            self.model = model
            self.options = options
            random = options.seed.map { MLXRandom.RandomState(seed: $0) } ?? MLXRandom.RandomState()
            let config = model.config
            var ids = promptIDs
            if let requested {
                mode = requested
                if requested == .audio, last != config.audioStartTokenID, last != config.audioOutTokenID {
                    ids.append(config.audioStartTokenID)
                }
                if requested == .interleaved, last != config.mixedStartTokenID { ids.append(config.mixedStartTokenID) }
            } else if last == config.audioStartTokenID || last == config.audioOutTokenID {
                mode = .audio
            } else {
                mode = last == config.mixedStartTokenID ? .interleaved : .text
            }
            var suppressed = model.suppressedTokens
            if requested == .text { suppressed += [config.mixedStartTokenID, config.audioStartTokenID] }
            var maskValues = [Float](repeating: 0, count: config.text.vocabSize)
            for token in suppressed where token < maskValues.count { maskValues[token] = -Float.infinity }
            suppressMask = MLXArray(maskValues)
            eosIDs = Set(config.eosTokenIDs)
            cache = model.languageModel.model.makeCache()
            let embeds = try model.inputEmbeddings(ids: ids, features: features)
            hidden = model.languageModel.model(embeddings: embeds, cache: cache)[0..., -1, 0...]
            slotsLeft = config.interleavedText
        }

        func next() throws -> GeneratedSlot? {
            guard !finished else { return nil }
            try Task.checkCancellation()
            return try withRandomState(random) { try advance() }
        }

        private func advance() throws -> GeneratedSlot {
            let config = model.config
            let backbone = model.languageModel.model
            if let pendingEmbedding {
                hidden = backbone(embeddings: pendingEmbedding.reshaped(1, 1, -1), cache: cache)[0..., -1, 0...]
                self.pendingEmbedding = nil
            }
            let interleaving = mode == .interleaved
            let next: MLXArray
            let slot: GeneratedSlot
            if mode == .audio || (interleaving && speaking) {
                let order = try options.frameOrder.map { orders -> MLXArray in
                    guard frame < orders.count else { throw LFM3Error.invalidInput("speech frame order is exhausted") }
                    return MLXArray(orders[frame].map { Int32($0) }).reshaped(1, -1)
                }
                frame += 1
                let history: MLXArray? =
                    audioHistory.isEmpty
                    ? nil : MLXArray(audioHistory.flatMap { $0 }, [1, audioHistory.count, config.codebooks])
                var codes = sampleFrame(
                    depth: model.depthDecoder, hidden: hidden, schedule: config.maskgitSchedule,
                    settings: options.audio,
                    history: history, order: order)[0]
                codes = normalizeEOS(codes, eos: config.audioEOSCode)
                let values = codes.asArray(Int32.self)
                if values[0] == Int32(config.audioEOSCode) {
                    mode = .text
                } else {
                    audioHistory.append(values)
                    if audioHistory.count > options.audioRepetitionWindow { audioHistory.removeFirst() }
                }
                next = embedFrames(model.codebookEmbedding, codes)
                slot = GeneratedSlot(token: config.audioOutTokenID, codes: values)
            } else {
                let history = textHistory.isEmpty ? nil : MLXArray(textHistory).reshaped(1, -1)
                let token = sampleToken(
                    model.textLogits(hidden), settings: options.text, history: history, suppress: suppressMask
                ).item(Int.self)
                textHistory.append(Int32(token))
                if textHistory.count > options.textRepetitionWindow { textHistory.removeFirst() }
                if token == config.textEndTokenID {
                    if interleaving {
                        textDone = true
                        speaking = true
                    } else {
                        finished = true
                    }
                } else if eosIDs.contains(token) {
                    finished = true
                } else if !interleaving {
                    if token == config.audioStartTokenID {
                        mode = .audio
                    } else if token == config.mixedStartTokenID {
                        mode = .interleaved
                        slotsLeft = config.interleavedText
                        speaking = false
                        textDone = false
                    }
                }
                next = backbone.embedTokens!(MLXArray([Int32(token)]))
                slot = GeneratedSlot(token: token, codes: nil)
            }
            if interleaving && !textDone {
                slotsLeft -= 1
                if slotsLeft == 0 {
                    speaking.toggle()
                    slotsLeft = speaking ? config.interleavedAudio : config.interleavedText
                }
            }
            step += 1
            if finished || step >= options.maxNewTokens { finished = true } else { pendingEmbedding = next }
            return slot
        }
    }
}

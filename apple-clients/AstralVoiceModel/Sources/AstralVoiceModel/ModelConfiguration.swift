// Decodes the LFM3-Audio config.json and audio_tokenizer/config.json into the typed settings the model, encoder, depth decoder and codec are built from.
// LFM3AudioModel and LiquidCodec read these values, and the unit tests build tiny variants of them to run without the real weights.

import Foundation

public struct RopeSettings: Codable, Equatable, Sendable {
    public var ropeTheta: Double?
    public var partialRotaryFactor: Double?

    enum CodingKeys: String, CodingKey {
        case ropeTheta = "rope_theta"
        case partialRotaryFactor = "partial_rotary_factor"
    }

    public init(ropeTheta: Double? = nil, partialRotaryFactor: Double? = nil) {
        self.ropeTheta = ropeTheta
        self.partialRotaryFactor = partialRotaryFactor
    }
}

public struct BackboneConfiguration: Equatable, Sendable {
    public var modelType: String
    public var vocabSize: Int
    public var hiddenSize: Int
    public var intermediateSize: Int
    public var layerCount: Int
    public var attentionHeads: Int
    public var keyValueHeads: Int
    public var headDim: Int
    public var normEps: Float
    public var convKernel: Int
    public var layerTypes: [String]
    public var slidingWindow: Int
    public var sandwichNorm: Bool
    public var fullAttentionRope: RopeSettings
    public var slidingAttentionRope: RopeSettings
    public var legacyRopeTheta: Double
    public var tieWordEmbeddings: Bool
    public var blockMultipleOf: Int
    public var blockFFNDimMultiplier: Double
    public var blockAutoAdjustFFDim: Bool
    public var convBias = false

    public init(
        modelType: String = "lfm3", vocabSize: Int, hiddenSize: Int, intermediateSize: Int, layerCount: Int,
        attentionHeads: Int, keyValueHeads: Int, headDim: Int? = nil, normEps: Float = 1e-5, convKernel: Int,
        layerTypes: [String], slidingWindow: Int = 256, sandwichNorm: Bool,
        fullAttentionRope: RopeSettings = RopeSettings(ropeTheta: 1_000_000, partialRotaryFactor: 0.5),
        slidingAttentionRope: RopeSettings = RopeSettings(ropeTheta: 10_000),
        legacyRopeTheta: Double = 1_000_000, tieWordEmbeddings: Bool = true, blockMultipleOf: Int = 256,
        blockFFNDimMultiplier: Double = 1, blockAutoAdjustFFDim: Bool = true
    ) {
        self.modelType = modelType
        self.vocabSize = vocabSize
        self.hiddenSize = hiddenSize
        self.intermediateSize = intermediateSize
        self.layerCount = layerCount
        self.attentionHeads = attentionHeads
        self.keyValueHeads = keyValueHeads
        self.headDim = headDim ?? hiddenSize / attentionHeads
        self.normEps = normEps
        self.convKernel = convKernel
        self.layerTypes = layerTypes
        self.slidingWindow = slidingWindow
        self.sandwichNorm = sandwichNorm
        self.fullAttentionRope = fullAttentionRope
        self.slidingAttentionRope = slidingAttentionRope
        self.legacyRopeTheta = legacyRopeTheta
        self.tieWordEmbeddings = tieWordEmbeddings
        self.blockMultipleOf = blockMultipleOf
        self.blockFFNDimMultiplier = blockFFNDimMultiplier
        self.blockAutoAdjustFFDim = blockAutoAdjustFFDim
    }

    func rope(forLayer type: String) -> RopeSettings {
        type == "sliding_attention" ? slidingAttentionRope : fullAttentionRope
    }

    var feedForwardDim: Int {
        guard modelType == "lfm2", blockAutoAdjustFFDim else { return intermediateSize }
        var dim = Int(2 * Double(intermediateSize) / 3)
        dim = Int(blockFFNDimMultiplier * Double(dim))
        return blockMultipleOf * ((dim + blockMultipleOf - 1) / blockMultipleOf)
    }
}

extension BackboneConfiguration: Decodable {
    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case vocabSize = "vocab_size"
        case hiddenSize = "hidden_size"
        case intermediateSize = "intermediate_size"
        case layerCount = "num_hidden_layers"
        case attentionHeads = "num_attention_heads"
        case keyValueHeads = "num_key_value_heads"
        case headDim = "head_dim"
        case normEps = "norm_eps"
        case convKernel = "conv_L_cache"
        case convBias = "conv_bias"
        case layerTypes = "layer_types"
        case slidingWindow = "sliding_window"
        case sandwichNorm = "use_sandwich_norm"
        case ropeParameters = "rope_parameters"
        case tieWordEmbeddings = "tie_word_embeddings"
        case blockMultipleOf = "block_multiple_of"
        case blockFFNDimMultiplier = "block_ffn_dim_multiplier"
        case blockAutoAdjustFFDim = "block_auto_adjust_ff_dim"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let modelType = try c.decodeIfPresent(String.self, forKey: .modelType) ?? "lfm3"
        let hidden = try c.decode(Int.self, forKey: .hiddenSize)
        let heads = try c.decode(Int.self, forKey: .attentionHeads)
        let layers = try c.decode(Int.self, forKey: .layerCount)
        let types = try c.decodeIfPresent([String].self, forKey: .layerTypes)
        let layerTypes = types ?? Self.defaultLayerTypes(count: layers)
        guard layerTypes.count == layers, Set(layerTypes).isSubset(of: ["conv", "full_attention", "sliding_attention"])
        else { throw DecodingError.dataCorruptedError(forKey: .layerTypes, in: c, debugDescription: "invalid layer types") }
        var full = RopeSettings(ropeTheta: 1_000_000, partialRotaryFactor: 0.5)
        var sliding = RopeSettings(ropeTheta: 10_000)
        var legacy = 1_000_000.0
        if let rope = try c.decodeIfPresent([String: AnyRope].self, forKey: .ropeParameters) {
            if let theta = rope["rope_theta"]?.number { legacy = theta }
            if let value = rope["full_attention"]?.settings { full = value }
            if let value = rope["sliding_attention"]?.settings { sliding = value }
            if rope["full_attention"] == nil, rope["sliding_attention"] == nil {
                full = RopeSettings(ropeTheta: legacy, partialRotaryFactor: 1)
                sliding = full
            }
        }
        try self.init(
            modelType: modelType, vocabSize: c.decode(Int.self, forKey: .vocabSize), hiddenSize: hidden,
            intermediateSize: c.decode(Int.self, forKey: .intermediateSize), layerCount: layers, attentionHeads: heads,
            keyValueHeads: c.decodeIfPresent(Int.self, forKey: .keyValueHeads) ?? heads,
            headDim: c.decodeIfPresent(Int.self, forKey: .headDim),
            normEps: c.decodeIfPresent(Float.self, forKey: .normEps) ?? 1e-5,
            convKernel: c.decodeIfPresent(Int.self, forKey: .convKernel) ?? 7, layerTypes: layerTypes,
            slidingWindow: c.decodeIfPresent(Int.self, forKey: .slidingWindow) ?? 256,
            sandwichNorm: c.decodeIfPresent(Bool.self, forKey: .sandwichNorm) ?? true,
            fullAttentionRope: full, slidingAttentionRope: sliding, legacyRopeTheta: legacy,
            tieWordEmbeddings: c.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? true,
            blockMultipleOf: c.decodeIfPresent(Int.self, forKey: .blockMultipleOf) ?? 256,
            blockFFNDimMultiplier: c.decodeIfPresent(Double.self, forKey: .blockFFNDimMultiplier) ?? 1,
            blockAutoAdjustFFDim: c.decodeIfPresent(Bool.self, forKey: .blockAutoAdjustFFDim) ?? true)
        convBias = try c.decodeIfPresent(Bool.self, forKey: .convBias) ?? false
    }

    static func defaultLayerTypes(count: Int) -> [String] {
        let pattern = [
            "conv", "conv", "full_attention", "conv", "sliding_attention", "conv", "full_attention", "conv",
            "sliding_attention", "conv", "full_attention", "conv", "sliding_attention", "conv", "full_attention",
            "conv", "sliding_attention", "conv", "full_attention", "conv", "sliding_attention", "conv",
            "full_attention", "conv",
        ]
        return Array(pattern.prefix(count))
    }
}

private struct AnyRope: Decodable, Equatable {
    var number: Double?
    var settings: RopeSettings?

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let value = try? single.decode(Double.self) {
            number = value
        } else if let value = try? single.decode(RopeSettings.self) {
            settings = value
        } else if (try? single.decode(String.self)) != nil {
            number = nil
        } else {
            throw DecodingError.dataCorruptedError(in: single, debugDescription: "invalid rope parameters")
        }
    }
}

public struct EncoderConfiguration: Equatable, Sendable {
    public var melBins: Int
    public var convChannels: Int
    public var hiddenSize: Int
    public var slidingWindow: Int
    public var backbone: BackboneConfiguration

    public init(melBins: Int, convChannels: Int, hiddenSize: Int, slidingWindow: Int, backbone: BackboneConfiguration) {
        self.melBins = melBins
        self.convChannels = convChannels
        self.hiddenSize = hiddenSize
        self.slidingWindow = slidingWindow
        self.backbone = backbone
    }
}

public struct ModelConfiguration: Equatable, Sendable {
    public var text: BackboneConfiguration
    public var encoder: EncoderConfiguration
    public var depth: BackboneConfiguration
    public var codebooks: Int
    public var codebookSize: Int
    public var audioEOSCode: Int
    public var maskgitSchedule: [Int]
    public var interleavedText: Int
    public var interleavedAudio: Int
    public var audioTokenID: Int
    public var audioOutTokenID: Int
    public var audioStartTokenID: Int
    public var textEndTokenID: Int
    public var mixedStartTokenID: Int
    public var eosTokenIDs: [Int]
    public var sampleRate: Int
    public var quantization: QuantizationSettings?

    public struct QuantizationSettings: Equatable, Sendable, Decodable {
        public var groupSize: Int
        public var bits: Int

        enum CodingKeys: String, CodingKey {
            case groupSize = "group_size"
            case bits
        }

        public init(groupSize: Int, bits: Int) {
            self.groupSize = groupSize
            self.bits = bits
        }
    }

    public init(
        text: BackboneConfiguration, encoder: EncoderConfiguration, depth: BackboneConfiguration, codebooks: Int = 12,
        codebookSize: Int = 2017, audioEOSCode: Int? = nil, maskgitSchedule: [Int]? = nil, interleavedText: Int = 6,
        interleavedAudio: Int = 12, audioTokenID: Int = 125_031, audioOutTokenID: Int = 125_032,
        audioStartTokenID: Int = 125_012, textEndTokenID: Int = 125_014, mixedStartTokenID: Int = 125_015,
        eosTokenIDs: [Int] = [124_900], sampleRate: Int = 24_000, quantization: QuantizationSettings? = nil
    ) throws {
        let schedule = maskgitSchedule ?? Self.schedule(codebooks: codebooks, steps: 3)
        guard schedule.allSatisfy({ $0 >= 1 }), schedule.reduce(0, +) == codebooks else {
            throw ModelConfigurationError.invalid("maskgit schedule must be positive and sum to the codebook count")
        }
        let eos = audioEOSCode ?? codebookSize - 1
        guard (0..<codebookSize).contains(eos), interleavedText >= 1, interleavedAudio >= 1 else {
            throw ModelConfigurationError.invalid("audio end code or interleaving blocks out of range")
        }
        self.text = text
        self.encoder = encoder
        self.depth = depth
        self.codebooks = codebooks
        self.codebookSize = codebookSize
        self.audioEOSCode = eos
        self.maskgitSchedule = schedule
        self.interleavedText = interleavedText
        self.interleavedAudio = interleavedAudio
        self.audioTokenID = audioTokenID
        self.audioOutTokenID = audioOutTokenID
        self.audioStartTokenID = audioStartTokenID
        self.textEndTokenID = textEndTokenID
        self.mixedStartTokenID = mixedStartTokenID
        self.eosTokenIDs = eosTokenIDs
        self.sampleRate = sampleRate
        self.quantization = quantization
    }

    static func schedule(codebooks: Int, steps: Int) -> [Int] {
        var result = [Int](repeating: codebooks / steps, count: steps)
        result[steps - 1] += codebooks % steps
        return result
    }

    public static func load(from url: URL) throws -> ModelConfiguration {
        try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> ModelConfiguration {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelConfigurationError.invalid("config.json is not an object")
        }
        func backbone(_ key: String, defaults: [String: Any]) throws -> BackboneConfiguration {
            var merged = defaults
            for (name, value) in (root[key] as? [String: Any]) ?? [:] { merged[name] = value }
            return try JSONDecoder().decode(
                BackboneConfiguration.self, from: JSONSerialization.data(withJSONObject: merged))
        }
        let text = try backbone("lfm", defaults: [:])
        let encoderRoot = root["encoder"] as? [String: Any] ?? [:]
        let encoderDefaults: [String: Any] = [
            "model_type": "lfm2", "vocab_size": 2, "hidden_size": 768, "intermediate_size": 2560,
            "num_hidden_layers": 17, "num_attention_heads": 8, "num_key_value_heads": 4, "conv_L_cache": 3,
            "use_sandwich_norm": false,
            "layer_types": Array(repeating: ["conv", "conv", "full_attention"], count: 5).flatMap { $0 }
                + ["full_attention", "full_attention"],
        ]
        var encoderBackbone = encoderDefaults
        for (name, value) in (encoderRoot["lfm"] as? [String: Any]) ?? [:] { encoderBackbone[name] = value }
        let encoderModel = try JSONDecoder().decode(
            BackboneConfiguration.self, from: JSONSerialization.data(withJSONObject: encoderBackbone))
        let depth = try backbone(
            "depthformer",
            defaults: [
                "vocab_size": 1, "hidden_size": 1024, "intermediate_size": 2816, "num_hidden_layers": 3,
                "num_attention_heads": 32, "num_key_value_heads": 8, "head_dim": 32,
                "layer_types": ["full_attention", "full_attention", "full_attention"], "use_sandwich_norm": false,
                "rope_parameters": ["full_attention": ["rope_theta": 1_000_000.0]],
            ])
        let codebooks = root["codebooks"] as? Int ?? 12
        let steps = root["maskgit_steps"] as? Int ?? 3
        guard (1...codebooks).contains(steps) else {
            throw ModelConfigurationError.invalid("maskgit_steps must be between 1 and the codebook count")
        }
        let eos = root["eos_token_id"]
        let eosIDs = (eos as? [Int]) ?? (eos as? Int).map { [$0] } ?? [124_900]
        var quantization: QuantizationSettings?
        if let value = root["quantization"] as? [String: Any], let bits = value["bits"] as? Int,
            let group = value["group_size"] as? Int
        {
            if let mode = value["mode"] as? String, mode != "affine" {
                throw ModelConfigurationError.invalid("unsupported quantization mode \(mode)")
            }
            quantization = QuantizationSettings(groupSize: group, bits: bits)
        }
        return try ModelConfiguration(
            text: text,
            encoder: EncoderConfiguration(
                melBins: encoderRoot["dim_in"] as? Int ?? 128, convChannels: encoderRoot["dim_conv"] as? Int ?? 256,
                hiddenSize: encoderRoot["dim_out"] as? Int ?? 768,
                slidingWindow: encoderRoot["sliding_window"] as? Int ?? 32, backbone: encoderModel),
            depth: depth, codebooks: codebooks, codebookSize: root["audio_vocab_size"] as? Int ?? 2017,
            audioEOSCode: root["audio_eos_code"] as? Int,
            maskgitSchedule: root["maskgit_schedule"] as? [Int] ?? Self.schedule(codebooks: codebooks, steps: steps),
            interleavedText: root["interleaved_n_text"] as? Int ?? 6,
            interleavedAudio: root["interleaved_n_audio"] as? Int ?? 12,
            audioTokenID: root["audio_token_id"] as? Int ?? 125_031,
            audioOutTokenID: root["audio_out_token_id"] as? Int ?? 125_032,
            audioStartTokenID: root["audio_start_token_id"] as? Int ?? 125_012,
            textEndTokenID: root["text_end_token_id"] as? Int ?? 125_014,
            mixedStartTokenID: root["mixed_start_token_id"] as? Int ?? 125_015, eosTokenIDs: eosIDs,
            sampleRate: root["sample_rate"] as? Int ?? 24_000, quantization: quantization)
    }
}

public enum ModelConfigurationError: Error, Equatable {
    case invalid(String)
}

public struct CodecConfiguration: Equatable, Sendable {
    public var encoderDim = 512
    public var quantizerDim = 256
    public var fsqLevels = [8, 7, 6, 6]
    public var quantizerCount = 12
    public var fftSize = 1280
    public var hop = 320
    public var frameStack = 6
    public var decoderWindow = 30
    public var sampleRate = 24_000

    public init() {}

    public var codebookSize: Int { fsqLevels.reduce(1, *) }
    public var samplesPerFrame: Int { hop * frameStack }

    public static func load(from url: URL) throws -> CodecConfiguration {
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ModelConfigurationError.invalid("codec config is not an object")
        }
        var config = CodecConfiguration()
        config.encoderDim = root["encoder_dim"] as? Int ?? config.encoderDim
        config.quantizerDim = root["quantizer_dim"] as? Int ?? config.quantizerDim
        config.fsqLevels = root["fsq_levels"] as? [Int] ?? config.fsqLevels
        config.quantizerCount = root["n_q"] as? Int ?? config.quantizerCount
        config.fftSize = root["stft_n_fft"] as? Int ?? config.fftSize
        config.hop = root["stft_hop_length"] as? Int ?? config.hop
        config.frameStack = root["stft_frame_stack"] as? Int ?? config.frameStack
        config.decoderWindow = root["decoder_window"] as? Int ?? config.decoderWindow
        config.sampleRate = root["sampling_rate"] as? Int ?? config.sampleRate
        let window = root["stft_win_length"] as? Int ?? config.fftSize
        guard window == config.fftSize, config.fftSize % config.hop == 0 else {
            throw ModelConfigurationError.invalid("codec requires window equal to fft size and hop dividing it")
        }
        return config
    }

    var backbone: BackboneConfiguration {
        BackboneConfiguration(
            vocabSize: 1, hiddenSize: encoderDim, intermediateSize: 2304, layerCount: 8, attentionHeads: 8,
            keyValueHeads: 2, headDim: 64, convKernel: 7,
            layerTypes: (0..<8).map { [2, 4, 6].contains($0) ? "sliding_attention" : "conv" }, slidingWindow: decoderWindow,
            sandwichNorm: true, slidingAttentionRope: RopeSettings(ropeTheta: 1_000_000), tieWordEmbeddings: false)
    }
}

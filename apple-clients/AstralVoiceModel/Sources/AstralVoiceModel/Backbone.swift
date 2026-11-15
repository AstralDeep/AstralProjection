// The LFM3 and LFM2 hybrid backbone: gated short convolutions, grouped-query attention with partial rotary embeddings, SwiGLU feed-forward blocks and their caches.
// LFM3AudioModel runs it as the language model, AudioEncoder runs the LFM2 variant over mel features, DepthDecoder runs it bidirectionally, and LiquidCodec runs it as the waveform decoder.

import Foundation
import MLX
import MLXNN

final class LayerCache {
    var keys: MLXArray?
    var values: MLXArray?
    var convState: MLXArray?
    var offset = 0
    let window: Int?

    init(window: Int? = nil) {
        self.window = window
    }

    func append(keys newKeys: MLXArray, values newValues: MLXArray) -> (MLXArray, MLXArray) {
        if let keys, let values {
            self.keys = concatenated([keys, newKeys], axis: 2)
            self.values = concatenated([values, newValues], axis: 2)
        } else {
            keys = newKeys
            values = newValues
        }
        offset += newKeys.dim(2)
        if let window, keys!.dim(2) > window, newKeys.dim(2) == 1 {
            keys = keys![.ellipsis, (keys!.dim(2) - window)..., 0...]
            values = values![.ellipsis, (values!.dim(2) - window)..., 0...]
        }
        return (keys!, values!)
    }
}

enum AttentionMask {
    case none
    case causal
    case array(MLXArray)

    static func banded(length: Int, window: Int?) -> AttentionMask {
        guard length > 1 else { return .none }
        guard let window, length > window else { return .causal }
        let rows = MLXArray(0..<length).reshaped(length, 1)
        let columns = MLXArray(0..<length).reshaped(1, length)
        return .array(logicalAnd(rows .>= columns, rows .< columns + window))
    }

    var mode: MLXFast.ScaledDotProductAttentionMaskMode {
        switch self {
        case .none: return .none
        case .causal: return .causal
        case .array(let mask): return .array(mask)
        }
    }
}

final class ConstantHolder {
    let array: MLXArray

    init(_ array: MLXArray) {
        self.array = array
    }
}

final class BackboneRMSNorm: Module {
    var weight: MLXArray
    let eps: Float
    private let unit: ConstantHolder

    init(_ dimensions: Int, eps: Float) {
        weight = MLXArray.ones([dimensions])
        unit = ConstantHolder(MLXArray.ones([dimensions], type: Float.self))
        self.eps = eps
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(x.asType(.float32), weight: unit.array, eps: eps).asType(x.dtype) * weight
    }
}

final class RotaryEmbedding {
    private let headDim: Int
    private let inverseFrequencies: MLXArray

    init(headDim: Int, theta: Double, partialFactor: Double) {
        self.headDim = headDim
        let half = headDim / 2
        let rotated = Int(partialFactor * Double(headDim)) / 2
        let frequencies = (0..<half).map { index -> Float in
            index < rotated ? Float(pow(theta, -2 * Double(index) / Double(headDim))) : 0
        }
        inverseFrequencies = MLXArray(frequencies)
    }

    func apply(_ x: MLXArray, offset: Int) -> MLXArray {
        let positions = (MLXArray(0..<x.dim(-2)) + offset).asType(.float32).reshaped(-1, 1)
        let angles = positions * inverseFrequencies
        let doubled = concatenated([angles, angles], axis: -1)
        let half = headDim / 2
        let rotated = concatenated([-x[.ellipsis, half...], x[.ellipsis, ..<half]], axis: -1)
        return (x.asType(.float32) * cos(doubled) + rotated.asType(.float32) * sin(doubled)).asType(x.dtype)
    }
}

final class BackboneAttention: Module {
    let heads: Int
    let keyValueHeads: Int
    let headDim: Int
    let scale: Float
    let gated: Bool
    let rope: RotaryEmbedding

    @ModuleInfo(key: "q_proj") var queryProjection: Linear
    @ModuleInfo(key: "k_proj") var keyProjection: Linear
    @ModuleInfo(key: "v_proj") var valueProjection: Linear
    @ModuleInfo(key: "o_proj") var outputProjection: Linear?
    @ModuleInfo(key: "out_proj") var legacyOutputProjection: Linear?
    @ModuleInfo(key: "q_norm") var queryNorm: BackboneRMSNorm?
    @ModuleInfo(key: "k_norm") var keyNorm: BackboneRMSNorm?
    @ModuleInfo(key: "q_layernorm") var legacyQueryNorm: RMSNorm?
    @ModuleInfo(key: "k_layernorm") var legacyKeyNorm: RMSNorm?
    @ModuleInfo(key: "gate_proj") var gateProjection: Linear?

    init(_ config: BackboneConfiguration, layerType: String) {
        heads = config.attentionHeads
        keyValueHeads = config.keyValueHeads
        headDim = config.headDim
        scale = Float(1 / Double(config.headDim).squareRoot())
        let legacy = config.modelType == "lfm2"
        gated = !legacy
        let settings = config.rope(forLayer: layerType)
        rope = RotaryEmbedding(
            headDim: config.headDim, theta: settings.ropeTheta ?? config.legacyRopeTheta,
            partialFactor: settings.partialRotaryFactor ?? 1)
        _queryProjection.wrappedValue = Linear(config.hiddenSize, heads * headDim, bias: false)
        _keyProjection.wrappedValue = Linear(config.hiddenSize, keyValueHeads * headDim, bias: false)
        _valueProjection.wrappedValue = Linear(config.hiddenSize, keyValueHeads * headDim, bias: false)
        if legacy {
            _legacyOutputProjection.wrappedValue = Linear(heads * headDim, config.hiddenSize, bias: false)
            _legacyQueryNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.normEps)
            _legacyKeyNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.normEps)
        } else {
            _outputProjection.wrappedValue = Linear(heads * headDim, config.hiddenSize, bias: false)
            _queryNorm.wrappedValue = BackboneRMSNorm(headDim, eps: config.normEps)
            _keyNorm.wrappedValue = BackboneRMSNorm(headDim, eps: config.normEps)
            _gateProjection.wrappedValue = Linear(config.hiddenSize, heads, bias: false)
        }
        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: AttentionMask, cache: LayerCache?) -> MLXArray {
        let batch = x.dim(0)
        let length = x.dim(1)
        var queries = queryProjection(x).reshaped(batch, length, heads, headDim)
        var keys = keyProjection(x).reshaped(batch, length, keyValueHeads, headDim)
        queries = (queryNorm?(queries) ?? legacyQueryNorm!(queries)).transposed(0, 2, 1, 3)
        keys = (keyNorm?(keys) ?? legacyKeyNorm!(keys)).transposed(0, 2, 1, 3)
        var values = valueProjection(x).reshaped(batch, length, keyValueHeads, headDim).transposed(0, 2, 1, 3)
        let offset = cache?.offset ?? 0
        queries = rope.apply(queries, offset: offset)
        keys = rope.apply(keys, offset: offset)
        if let cache { (keys, values) = cache.append(keys: keys, values: values) }
        var attended = MLXFast.scaledDotProductAttention(
            queries: queries, keys: keys, values: values, scale: scale, mask: mask.mode)
        attended = attended.transposed(0, 2, 1, 3)
        if gated { attended = attended * sigmoid(gateProjection!(x)).expandedDimensions(axis: -1) }
        let merged = attended.reshaped(batch, length, -1)
        return (outputProjection ?? legacyOutputProjection!)(merged)
    }
}

final class ShortConvolution: Module {
    let kernel: Int
    let hidden: Int

    @ModuleInfo(key: "conv") var conv: Conv1d
    @ModuleInfo(key: "in_proj") var inputProjection: Linear
    @ModuleInfo(key: "out_proj") var outputProjection: Linear

    init(_ config: BackboneConfiguration) {
        kernel = config.convKernel
        hidden = config.hiddenSize
        _conv.wrappedValue = Conv1d(
            inputChannels: hidden, outputChannels: hidden, kernelSize: kernel, groups: hidden, bias: config.convBias)
        _inputProjection.wrappedValue = Linear(hidden, 3 * hidden, bias: false)
        _outputProjection.wrappedValue = Linear(hidden, hidden, bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, cache: LayerCache?) -> MLXArray {
        let parts = split(inputProjection(x), parts: 3, axis: -1)
        var gated = parts[0] * parts[2]
        if let cache {
            let state = cache.convState ?? MLXArray.zeros([gated.dim(0), kernel - 1, hidden], dtype: gated.dtype)
            gated = concatenated([state, gated], axis: 1)
            cache.convState = gated[0..., (gated.dim(1) - (kernel - 1))..., 0...]
        } else {
            gated = padded(gated, widths: [.init((0, 0)), .init((kernel - 1, 0)), .init((0, 0))])
        }
        return outputProjection(parts[1] * conv(gated))
    }
}

final class FeedForward: Module {
    @ModuleInfo(key: "w1") var gate: Linear
    @ModuleInfo(key: "w3") var up: Linear
    @ModuleInfo(key: "w2") var down: Linear

    init(hidden: Int, inner: Int) {
        _gate.wrappedValue = Linear(hidden, inner, bias: false)
        _up.wrappedValue = Linear(hidden, inner, bias: false)
        _down.wrappedValue = Linear(inner, hidden, bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        down(silu(gate(x)) * up(x))
    }
}

final class BackboneLayer: Module {
    let layerType: String
    let isAttention: Bool

    @ModuleInfo(key: "self_attn") var attention: BackboneAttention?
    @ModuleInfo(key: "conv") var shortConv: ShortConvolution?
    @ModuleInfo(key: "feed_forward") var feedForward: FeedForward
    @ModuleInfo(key: "operator_norm") var operatorNorm: BackboneRMSNorm
    @ModuleInfo(key: "ffn_norm") var ffnNorm: BackboneRMSNorm
    @ModuleInfo(key: "post_operator_norm") var postOperatorNorm: BackboneRMSNorm?
    @ModuleInfo(key: "post_ffn_norm") var postFFNNorm: BackboneRMSNorm?

    init(_ config: BackboneConfiguration, index: Int) {
        layerType = config.layerTypes[index]
        isAttention = layerType != "conv"
        if isAttention {
            _attention.wrappedValue = BackboneAttention(config, layerType: layerType)
        } else {
            _shortConv.wrappedValue = ShortConvolution(config)
        }
        _feedForward.wrappedValue = FeedForward(hidden: config.hiddenSize, inner: config.feedForwardDim)
        _operatorNorm.wrappedValue = BackboneRMSNorm(config.hiddenSize, eps: config.normEps)
        _ffnNorm.wrappedValue = BackboneRMSNorm(config.hiddenSize, eps: config.normEps)
        if config.sandwichNorm, config.modelType != "lfm2" {
            _postOperatorNorm.wrappedValue = BackboneRMSNorm(config.hiddenSize, eps: config.normEps)
            _postFFNNorm.wrappedValue = BackboneRMSNorm(config.hiddenSize, eps: config.normEps)
        }
        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: AttentionMask, cache: LayerCache?) -> MLXArray {
        let normed = operatorNorm(x)
        var y = attention?(normed, mask: mask, cache: cache) ?? shortConv!(normed, cache: cache)
        if let postOperatorNorm { y = postOperatorNorm(y) }
        let mixed = x + y
        var z = feedForward(ffnNorm(mixed))
        if let postFFNNorm { z = postFFNNorm(z) }
        return mixed + z
    }
}

final class BackboneModel: Module {
    let config: BackboneConfiguration

    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding?
    @ModuleInfo(key: "layers") var layers: [BackboneLayer]
    @ModuleInfo(key: "embedding_norm") var embeddingNorm: BackboneRMSNorm

    init(_ config: BackboneConfiguration, embeddings: Bool) {
        self.config = config
        if embeddings { _embedTokens.wrappedValue = Embedding(embeddingCount: config.vocabSize, dimensions: config.hiddenSize) }
        _layers.wrappedValue = (0..<config.layerCount).map { BackboneLayer(config, index: $0) }
        _embeddingNorm.wrappedValue = BackboneRMSNorm(config.hiddenSize, eps: config.normEps)
        super.init()
    }

    func makeCache() -> [LayerCache] {
        config.layerTypes.map { LayerCache(window: $0 == "sliding_attention" ? config.slidingWindow : nil) }
    }

    func callAsFunction(embeddings: MLXArray, cache: [LayerCache]? = nil, windowSize: Int? = nil, causal: Bool = true)
        -> MLXArray
    {
        var x = embeddings
        let length = x.dim(1)
        for (index, layer) in layers.enumerated() {
            let window = layer.layerType == "sliding_attention" ? config.slidingWindow : windowSize
            let mask: AttentionMask =
                causal && layer.isAttention ? AttentionMask.banded(length: length, window: window) : .none
            x = layer(x, mask: mask, cache: cache?[index])
        }
        return embeddingNorm(x)
    }
}

// The depth decoder that turns one language-model hidden state into a frame of twelve speech codes, revealing codebooks over a few bidirectional passes.
// LFM3AudioModel calls sampleFrame once per speech slot, and Sampling supplies the token selection used inside each pass.

import Foundation
import MLX
import MLXNN

final class HeadRMSNorm: Module {
    var weight: MLXArray
    let eps: Float

    init(_ dimensions: Int, eps: Float) {
        weight = MLXArray.ones([dimensions])
        self.eps = eps
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(x.asType(.float32), weight: weight.asType(.float32), eps: eps).asType(x.dtype)
    }
}

final class CodebookEmbedding: Module {
    @ModuleInfo(key: "embedding") var embedding: Embedding
    @ModuleInfo(key: "embedding_norm") var embeddingNorm: HeadRMSNorm

    init(size: Int, dimensions: Int, eps: Float) {
        _embedding.wrappedValue = Embedding(embeddingCount: size, dimensions: dimensions)
        _embeddingNorm.wrappedValue = HeadRMSNorm(dimensions, eps: eps)
        super.init()
    }

    func logits(_ x: MLXArray) -> MLXArray {
        embedding.asLinear(embeddingNorm(x))
    }
}

final class DepthModel: Module {
    @ModuleInfo(key: "layers") var layers: [BackboneLayer]
    @ModuleInfo(key: "embedding_norm") var embeddingNorm: RMSNorm

    init(_ config: BackboneConfiguration) {
        _layers.wrappedValue = (0..<config.layerCount).map { BackboneLayer(config, index: $0) }
        _embeddingNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.normEps)
        super.init()
    }

    func callAsFunction(_ input: MLXArray) -> MLXArray {
        var x = input
        for layer in layers { x = layer(x, mask: .none, cache: nil) }
        return embeddingNorm(x)
    }
}

final class DepthDecoder: Module {
    let codebooks: Int
    let hidden: Int

    @ModuleInfo(key: "depth_linear") var depthLinear: Linear
    @ParameterInfo(key: "mask_embedding") var maskEmbedding: MLXArray
    @ModuleInfo(key: "model") var model: DepthModel
    @ModuleInfo(key: "depth_embeddings") var depthEmbeddings: [CodebookEmbedding]

    init(_ config: BackboneConfiguration, inputSize: Int, codebooks: Int, codebookSize: Int) {
        self.codebooks = codebooks
        hidden = config.hiddenSize
        _depthLinear.wrappedValue = Linear(inputSize, codebooks * config.hiddenSize)
        _maskEmbedding.wrappedValue = MLXArray.zeros([config.hiddenSize])
        _model.wrappedValue = DepthModel(config)
        _depthEmbeddings.wrappedValue = (0..<codebooks).map { _ in
            CodebookEmbedding(size: codebookSize, dimensions: config.hiddenSize, eps: config.normEps)
        }
        super.init()
    }

    func callAsFunction(hidden state: MLXArray, codes: MLXArray, masked: MLXArray) -> MLXArray {
        let batch = state.dim(0)
        var x = depthLinear(state).reshaped(batch, codebooks, hidden)
        let embeds = stacked((0..<codebooks).map { depthEmbeddings[$0].embedding(codes[.ellipsis, $0]) }, axis: -2)
        let mask = maskEmbedding.asType(embeds.dtype)
        x = model(x + which(masked.expandedDimensions(axis: -1), mask, embeds))
        return stacked((0..<codebooks).map { depthEmbeddings[$0].logits(x[.ellipsis, $0, 0...]) }, axis: -2)
    }
}

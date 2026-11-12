// Token selection shared by text and speech slots: repetition penalty, suppressed ids, temperature, top-k and top-p, with exact greedy decoding at temperature zero.
// LFM3AudioModel samples text tokens with it directly, and sampleFrame applies it per codebook inside the depth decoder's reveal passes.

import Foundation
import MLX
import MLXNN

struct SamplerSettings: Sendable {
    var temperature: Float?
    var topK: Int?
    var topP: Float?
    var repetitionPenalty: Float?
}

func sampleToken(
    _ logits: MLXArray, settings: SamplerSettings, history: MLXArray? = nil, suppress: MLXArray? = nil
) -> MLXArray {
    var scores = logits.asType(.float32)
    let vocab = scores.dim(-1)
    if let penalty = settings.repetitionPenalty, penalty != 1, let history {
        let ids = broadcast(history, to: Array(scores.shape.dropLast()) + [history.dim(-1)])
        let picked = takeAlong(scores, ids, axis: -1)
        let penalized = which(picked .< 0, picked * penalty, picked / penalty)
        scores = putAlong(scores, ids, values: penalized, axis: -1)
    }
    if let suppress { scores = scores + suppress }
    let topK = settings.topK ?? 0
    if settings.temperature == 0 || (settings.temperature == nil && topK == 0) {
        return argMax(scores, axis: -1)
    }
    if let temperature = settings.temperature { scores = scores / temperature }
    scores = scores - logSumExp(scores, axis: -1, keepDims: true)
    if topK > 0, topK < vocab { scores = applyTopK(scores, topK) }
    if let topP = settings.topP, topP < 1 { scores = applyTopP(scores, topP) }
    return MLXRandom.categorical(scores)
}

func applyTopK(_ logprobs: MLXArray, _ k: Int) -> MLXArray {
    let threshold = sorted(logprobs, axis: -1)[.ellipsis, (logprobs.dim(-1) - k)...].min(axis: -1, keepDims: true)
    return which(logprobs .< threshold, MLXArray(-Float.infinity), logprobs)
}

func applyTopP(_ logprobs: MLXArray, _ p: Float) -> MLXArray {
    let probs = exp(logprobs)
    let order = argSort(logprobs, axis: -1)
    let cumulative = cumsum(takeAlong(probs, order, axis: -1), axis: -1)
    let inverse = putAlong(
        MLXArray.zeros(like: order), order, values: MLXArray(0..<order.dim(-1)).asType(order.dtype), axis: -1)
    let restored = takeAlong(cumulative, inverse, axis: -1)
    return which(restored .> 1 - p, logprobs, MLXArray(-Float.infinity))
}

func sampleFrame(
    depth: DepthDecoder, hidden: MLXArray, schedule: [Int], settings: SamplerSettings, history: MLXArray?,
    order: MLXArray?
) -> MLXArray {
    let batch = hidden.dim(0)
    let k = depth.codebooks
    let reveal =
        order ?? stacked((0..<batch).map { _ in MLXRandom.permutation(k) }, axis: 0)
    let swapped = history?.swappedAxes(-1, -2)
    var codes = MLXArray.zeros([batch, k], type: Int32.self)
    var revealed = MLXArray.zeros([batch, k], type: Bool.self)
    var start = 0
    for size in schedule {
        let pick = putAlong(
            MLXArray.zeros([batch, k], type: Bool.self), reveal[0..., start..<(start + size)],
            values: MLXArray(true), axis: -1)
        let logits = depth(hidden: hidden, codes: codes, masked: logicalNot(revealed))
        let sampled = sampleToken(logits, settings: settings, history: swapped)
        codes = which(pick, sampled.asType(.int32), codes)
        revealed = logicalOr(revealed, pick)
        start += size
    }
    return codes
}

func normalizeEOS(_ codes: MLXArray, eos: Int) -> MLXArray {
    which(any(codes .== eos, axis: -1, keepDims: true), MLXArray(Int32(eos)), codes)
}

func embedFrames(_ table: Embedding, _ codes: MLXArray) -> MLXArray {
    let k = codes.dim(-1)
    let stride = table.weight.dim(0) / k
    let offsets = MLXArray(0..<k).asType(codes.dtype) * Int32(stride)
    return table(codes + offsets).sum(axis: -2)
}

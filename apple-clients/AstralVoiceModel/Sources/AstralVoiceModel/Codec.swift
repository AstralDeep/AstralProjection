// The Liquid codec decoder: finite-scalar dequantization of twelve code streams, a causal LFM3 stack and an inverse STFT that yields 24 kHz audio.
// LFM3AudioModel decodes finished or streamed code frames with it, and StreamingCodecDecoder re-decodes a short window of recent frames to emit audio as it is generated.

import Foundation
import MLX
import MLXNN

final class FSQDequantizer: Module {
    let levels: [Int]
    let basis: [Int]

    @ModuleInfo(key: "project_out") var projectOut: Linear

    init(_ config: CodecConfiguration) {
        let levels = config.fsqLevels
        self.levels = levels
        basis = (0..<levels.count).map { index in levels[..<index].reduce(1, *) }
        _projectOut.wrappedValue = Linear(config.quantizerCount * levels.count, config.quantizerDim)
        super.init()
    }

    func callAsFunction(_ codes: MLXArray) -> MLXArray {
        let levelArray = MLXArray(levels.map { Int32($0) })
        let half = floorDivide(levelArray, MLXArray(Int32(2))).asType(.float32)
        let transposed = codes.transposed(0, 2, 1).expandedDimensions(axis: -1)
        let digits = remainder(floorDivide(transposed, MLXArray(basis.map { Int32($0) })), levelArray)
        let latents = ((digits.asType(.float32) - half) / half).reshaped(codes.dim(0), codes.dim(2), -1)
        return projectOut(latents.asType(projectOut.weight.dtype))
    }
}

final class InverseSTFT: Module {
    let fftSize: Int
    let hop: Int
    var window: MLXArray

    init(_ config: CodecConfiguration) {
        fftSize = config.fftSize
        hop = config.hop
        window = MLXArray.zeros([config.fftSize], type: Float.self)
        super.init()
    }

    private func overlapAdd(_ frames: MLXArray) -> MLXArray {
        let batch = frames.dim(0)
        let count = frames.dim(1)
        let k = fftSize / hop
        let blocks = frames.reshaped(batch, count, k, hop)
        var total = padded(blocks[0..., 0..., 0], widths: [.init((0, 0)), .init((0, k - 1)), .init((0, 0))])
        for j in 1..<k {
            total = total + padded(blocks[0..., 0..., j], widths: [.init((0, 0)), .init((j, k - 1 - j)), .init((0, 0))])
        }
        return total.reshaped(batch, -1)
    }

    func callAsFunction(_ spectrum: MLXArray) -> MLXArray {
        let w = window.asType(.float32)
        let frames = irfft(spectrum, n: fftSize, axis: -1) * w
        let audio = overlapAdd(frames)
        let envelope = overlapAdd(broadcast(w * w, to: [1, spectrum.dim(1), fftSize]))
        let trim = (fftSize - hop) / 2
        return audio[0..., trim..<(audio.dim(1) - trim)] / envelope[0..., trim..<(envelope.dim(1) - trim)]
    }
}

final class CodecDecoder: Module {
    let stack: Int

    @ModuleInfo(key: "lfm") var lfm: BackboneModel
    @ModuleInfo(key: "lin") var lin: Linear
    @ModuleInfo(key: "istft") var istft: InverseSTFT

    init(_ config: CodecConfiguration) {
        stack = config.frameStack
        _lfm.wrappedValue = BackboneModel(config.backbone, embeddings: false)
        _lin.wrappedValue = Linear(config.encoderDim, config.fftSize + 2)
        _istft.wrappedValue = InverseSTFT(config)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let hidden = lfm(embeddings: repeated(x, count: stack, axis: 1))
        let parts = split(lin(hidden).asType(.float32), parts: 2, axis: -1)
        let magnitude = exp(parts[0])
        let real = (magnitude * cos(parts[1])).asType(.complex64)
        let imaginary = (magnitude * sin(parts[1])).asType(.complex64)
        return istft(real + imaginary * MLXArray(real: 0, imaginary: 1))
    }
}

public final class LiquidCodec: Module {
    let config: CodecConfiguration

    @ModuleInfo(key: "quantizer") var quantizer: FSQDequantizer
    @ModuleInfo(key: "from_quantizer") var fromQuantizer: Linear
    @ModuleInfo(key: "decoder") var decoder: CodecDecoder

    init(_ config: CodecConfiguration) {
        self.config = config
        _quantizer.wrappedValue = FSQDequantizer(config)
        _fromQuantizer.wrappedValue = Linear(config.quantizerDim, config.encoderDim)
        _decoder.wrappedValue = CodecDecoder(config)
        super.init()
    }

    public var samplesPerFrame: Int { config.samplesPerFrame }

    func decode(codes: MLXArray) throws -> MLXArray {
        guard codes.ndim == 2, codes.dim(0) == config.quantizerCount else {
            throw LFM3Error.invalidInput("expected codes [\(config.quantizerCount), frames]")
        }
        guard codes.dim(1) > 0 else { return MLXArray.zeros([0], type: Float.self) }
        if codes.min().item(Int32.self) < 0 || codes.max().item(Int32.self) >= Int32(config.codebookSize) {
            throw LFM3Error.invalidInput("codes must lie in [0, \(config.codebookSize))")
        }
        let latent = fromQuantizer(quantizer(codes.expandedDimensions(axis: 0).asType(.int32)))
        return decoder(latent)[0]
    }

    static func load(directory: URL, dtype: DType) throws -> LiquidCodec {
        let config = try CodecConfiguration.load(from: directory.appendingPathComponent("config.json"))
        let codec = LiquidCodec(config)
        var weights = [String: MLXArray]()
        for (name, value) in try loadArrays(url: directory.appendingPathComponent("model.safetensors")) {
            let key = name.replacingOccurrences(of: "quantizer.fsq.", with: "quantizer.")
            guard
                key.hasPrefix("decoder.") || key.hasPrefix("from_quantizer.")
                    || key.hasPrefix("quantizer.project_out.")
            else { continue }
            var array = value
            if key.hasSuffix("conv.conv.weight"), array.dim(1) == 1 { array = array.transposed(0, 2, 1) }
            if key != "decoder.istft.window" { array = array.asType(dtype) }
            weights[key] = array
        }
        try codec.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(codec)
        return codec
    }
}

public final class StreamingCodecDecoder {
    private let codec: LiquidCodec
    private let contextFrames: Int
    private var frames: [[Int32]] = []
    private var emittedSamples = 0
    private var pendingFrames = 0
    private let holdBack: Int

    init(codec: LiquidCodec, contextFrames: Int = 20) {
        self.codec = codec
        self.contextFrames = contextFrames
        holdBack = (codec.config.fftSize - codec.config.hop) / 2
    }

    public var frameCount: Int { frames.count }
    var pendingCount: Int { pendingFrames }

    func append(_ frame: [Int32]) {
        frames.append(frame)
        pendingFrames += 1
    }

    func flush(final: Bool) throws -> [Float] {
        guard !frames.isEmpty else { return [] }
        let total = frames.count
        let start = max(0, total - pendingFrames - contextFrames)
        let window = frames[start...]
        let codes = MLXArray(window.flatMap { $0 }, [window.count, codec.config.quantizerCount]).transposed(1, 0)
        let wave = try codec.decode(codes: codes)
        eval(wave)
        let samplesPerFrame = codec.samplesPerFrame
        let firstSample = start * samplesPerFrame
        let limit = final ? total * samplesPerFrame : max(0, total * samplesPerFrame - holdBack)
        guard limit > emittedSamples else { return [] }
        let fresh = wave[(emittedSamples - firstSample)..<(limit - firstSample)].asArray(Float.self)
        emittedSamples = limit
        pendingFrames = 0
        return fresh
    }
}

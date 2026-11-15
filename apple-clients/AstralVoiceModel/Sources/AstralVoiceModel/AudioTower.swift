// The speech input path: a strided convolutional downsampler, the causal LFM2 encoder over mel features, and the projector into the language model's embedding space.
// LFM3AudioModel calls AudioEncoder and AudioProjector to turn LogMel features of one clip into the embeddings that replace the audio placeholders in the prompt.

import Foundation
import MLX
import MLXNN

private func inFloat32(_ activation: (MLXArray) -> MLXArray, _ x: MLXArray) -> MLXArray {
    activation(x.asType(.float32)).asType(x.dtype)
}

final class Downsampler: Module {
    @ModuleInfo(key: "conv_in") var convIn: Conv2d
    @ModuleInfo(key: "conv_mid") var convMid: Conv2d
    @ModuleInfo(key: "lin_mid") var linMid: Conv2d
    @ModuleInfo(key: "conv_end") var convEnd: Conv2d
    @ModuleInfo(key: "lin_end") var linEnd: Conv2d
    @ModuleInfo(key: "lin_out") var linOut: Linear

    init(_ config: EncoderConfiguration) {
        let channels = config.convChannels
        _convIn.wrappedValue = Conv2d(inputChannels: 1, outputChannels: channels, kernelSize: 3, stride: 2, padding: 1)
        _convMid.wrappedValue = Conv2d(
            inputChannels: channels, outputChannels: channels, kernelSize: 3, stride: 2, padding: 1, groups: channels)
        _linMid.wrappedValue = Conv2d(inputChannels: channels, outputChannels: channels, kernelSize: 1)
        _convEnd.wrappedValue = Conv2d(
            inputChannels: channels, outputChannels: channels, kernelSize: 3, stride: 2, padding: 1, groups: channels)
        _linEnd.wrappedValue = Conv2d(inputChannels: channels, outputChannels: channels, kernelSize: 1)
        _linOut.wrappedValue = Linear(config.melBins * channels / 8, config.hiddenSize)
        super.init()
    }

    func callAsFunction(_ features: MLXArray) -> MLXArray {
        var x = features.expandedDimensions(axis: -1)
        x = inFloat32(silu, convIn(x))
        x = inFloat32(silu, linMid(convMid(x)))
        x = inFloat32(silu, linEnd(convEnd(x)))
        let batch = x.dim(0)
        let time = x.dim(2)
        x = x.transposed(0, 2, 3, 1).reshaped(batch, time, -1)
        return linOut(x)
    }
}

final class AudioEncoder: Module {
    let config: EncoderConfiguration

    @ModuleInfo(key: "downsample") var downsample: Downsampler
    @ModuleInfo(key: "lfm") var lfm: BackboneModel

    init(_ config: EncoderConfiguration) {
        self.config = config
        _downsample.wrappedValue = Downsampler(config)
        _lfm.wrappedValue = BackboneModel(config.backbone, embeddings: false)
        super.init()
    }

    func callAsFunction(_ features: MLXArray) throws -> MLXArray {
        guard features.ndim == 3, features.dim(0) == 1, features.dim(1) == config.melBins else {
            throw LFM3Error.invalidInput("expected features [1, \(config.melBins), frames]")
        }
        let reduced = downsample(features.asType(downsample.convIn.weight.dtype))
        return lfm(embeddings: reduced, windowSize: config.slidingWindow)[0]
    }
}

final class AudioProjector: Module {
    @ModuleInfo(key: "layer_norm") var layerNorm: LayerNorm
    @ModuleInfo(key: "linear_1") var linear1: Linear
    @ModuleInfo(key: "linear_2") var linear2: Linear

    init(encoderSize: Int, outputSize: Int) {
        _layerNorm.wrappedValue = LayerNorm(dimensions: encoderSize)
        _linear1.wrappedValue = Linear(encoderSize, outputSize)
        _linear2.wrappedValue = Linear(outputSize, outputSize)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        linear2(inFloat32(gelu, linear1(layerNorm(x))))
    }
}

public enum LFM3Error: Error, Equatable {
    case invalidInput(String)
    case modelFiles(String)
    case cancelled
}

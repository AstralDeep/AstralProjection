// Computes the 128-bin slaney log-mel features of a mono 16 kHz clip exactly as the LFM3-Audio feature extractor does, in double precision on the CPU with Accelerate.
// LFM3AudioEngine feeds the result to AudioEncoder, and the filterbank is built once per process.

import Accelerate
import Foundation

public enum LogMel {
    public static let sampleRate = 16_000
    public static let fftSize = 400
    public static let hop = 160
    public static let melBins = 128
    static let logFloor = -12.0

    public static func frameCount(samples: Int) -> Int {
        let excess = samples - fftSize
        return 1 + max(0, excess <= 0 ? 0 : (excess + hop - 1) / hop)
    }

    public static func encoderTokenCount(frames: Int) -> Int { (frames + 7) / 8 }

    private static let filterbank: [Double] = makeFilterbank()
    private static let cosines: [Double] = dftBasis(cosine: true)
    private static let sines: [Double] = dftBasis(cosine: false)
    private static let window: [Double] = (0..<fftSize).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize)) }

    public static func features(_ samples: [Float]) -> (values: [Float], frames: Int) {
        let frames = frameCount(samples: samples.count)
        let bins = fftSize / 2 + 1
        let paddedCount = fftSize + (frames - 1) * hop
        var framesMatrix = [Double](repeating: 0, count: fftSize * frames)
        for t in 0..<frames {
            for n in 0..<fftSize {
                let index = t * hop + n
                if index < samples.count && index < paddedCount {
                    framesMatrix[n * frames + t] = Double(samples[index]) * window[n]
                }
            }
        }
        var real = [Double](repeating: 0, count: bins * frames)
        var imaginary = [Double](repeating: 0, count: bins * frames)
        vDSP_mmulD(cosines, 1, framesMatrix, 1, &real, 1, vDSP_Length(bins), vDSP_Length(frames), vDSP_Length(fftSize))
        vDSP_mmulD(sines, 1, framesMatrix, 1, &imaginary, 1, vDSP_Length(bins), vDSP_Length(frames), vDSP_Length(fftSize))
        var power = [Double](repeating: 0, count: bins * frames)
        for i in power.indices { power[i] = real[i] * real[i] + imaginary[i] * imaginary[i] }
        var mel = [Double](repeating: 0, count: melBins * frames)
        vDSP_mmulD(filterbank, 1, power, 1, &mel, 1, vDSP_Length(melBins), vDSP_Length(frames), vDSP_Length(bins))
        return (mel.map { Float((max(log10($0), logFloor) + 4) / 4) }, frames)
    }

    private static func dftBasis(cosine: Bool) -> [Double] {
        let bins = fftSize / 2 + 1
        var basis = [Double](repeating: 0, count: bins * fftSize)
        for k in 0..<bins {
            for n in 0..<fftSize {
                let angle = 2 * Double.pi * Double((n * k) % fftSize) / Double(fftSize)
                basis[k * fftSize + n] = cosine ? Foundation.cos(angle) : -Foundation.sin(angle)
            }
        }
        return basis
    }

    private static func hzToMel(_ hz: Double) -> Double {
        let linearStep = 200.0 / 3
        let minLogHz = 1000.0
        let minLogMel = minLogHz / linearStep
        let logStep = Foundation.log(6.4) / 27
        return hz >= minLogHz ? minLogMel + Foundation.log(hz / minLogHz) / logStep : hz / linearStep
    }

    private static func melToHz(_ mel: Double) -> Double {
        let linearStep = 200.0 / 3
        let minLogHz = 1000.0
        let minLogMel = minLogHz / linearStep
        let logStep = Foundation.log(6.4) / 27
        return mel >= minLogMel ? minLogHz * Foundation.exp(logStep * (mel - minLogMel)) : linearStep * mel
    }

    private static func makeFilterbank() -> [Double] {
        let bins = fftSize / 2 + 1
        let maxFrequency = Double(sampleRate / 2)
        let allFrequencies = (0..<bins).map { maxFrequency * Double($0) / Double(bins - 1) }
        let low = hzToMel(0)
        let high = hzToMel(maxFrequency)
        let points = (0..<(melBins + 2)).map {
            melToHz(low + (high - low) * Double($0) / Double(melBins + 1))
        }
        var bank = [Double](repeating: 0, count: melBins * bins)
        for m in 0..<melBins {
            let normalization = 2 / (points[m + 2] - points[m])
            for k in 0..<bins {
                let down = -(points[m] - allFrequencies[k]) / (points[m + 1] - points[m])
                let up = (points[m + 2] - allFrequencies[k]) / (points[m + 2] - points[m + 1])
                bank[m * bins + k] = max(0, min(down, up)) * normalization
            }
        }
        return bank
    }
}

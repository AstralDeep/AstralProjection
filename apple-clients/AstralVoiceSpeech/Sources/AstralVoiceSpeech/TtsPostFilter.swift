// Applies the rumble filter and the high-shelf de-esser to speech one frame at a time, carrying filter state across frames.
// It reproduces what FluidAudio's one-shot synthesize call applies to a whole sentence, so streamed speech sounds the same as the speech judged in listening tests.
import Foundation

struct TtsPostFilter: Sendable {
    private let rumbleAlpha: Float
    private let b0: Float
    private let b1: Float
    private let b2: Float
    private let a1: Float
    private let a2: Float
    private var previousInput: Float = 0
    private var previousRumble: Float = 0
    private var z1: Float = 0
    private var z2: Float = 0
    private var started = false

    init(sampleRate: Float) {
        let rumbleCutoff: Float = 80
        let rc = 1.0 / (2.0 * Float.pi * rumbleCutoff)
        let dt = 1.0 / sampleRate
        rumbleAlpha = rc / (rc + dt)

        let shelfCutoff: Float = 6000
        let reductionDb: Float = -3.0
        let a = powf(10, reductionDb / 40)
        let omega = 2 * Float.pi * shelfCutoff / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let q: Float = 0.707
        let alpha = sinOmega / (2 * q)
        let sqrtA = sqrt(a)
        let rawB0 = a * ((a + 1) + (a - 1) * cosOmega + 2 * sqrtA * alpha)
        let rawB1 = -2 * a * ((a - 1) + (a + 1) * cosOmega)
        let rawB2 = a * ((a + 1) + (a - 1) * cosOmega - 2 * sqrtA * alpha)
        let rawA0 = (a + 1) - (a - 1) * cosOmega + 2 * sqrtA * alpha
        let rawA1 = 2 * ((a - 1) - (a + 1) * cosOmega)
        let rawA2 = (a + 1) - (a - 1) * cosOmega - 2 * sqrtA * alpha
        b0 = rawB0 / rawA0
        b1 = rawB1 / rawA0
        b2 = rawB2 / rawA0
        a1 = rawA1 / rawA0
        a2 = rawA2 / rawA0
    }

    mutating func process(_ samples: inout [Float]) {
        for index in samples.indices {
            var x = samples[index]
            if started {
                let y = rumbleAlpha * (previousRumble + x - previousInput)
                previousInput = x
                previousRumble = y
                x = y
            } else {
                started = true
                previousInput = x
                previousRumble = 0
            }
            let out = b0 * x + z1
            z1 = b1 * x - a1 * out + z2
            z2 = b2 * x - a2 * out
            samples[index] = out
        }
    }
}

// Energy-based voice activity detection over the echo-cancelled microphone signal, with an adaptive noise floor and a release hangover.
// VoiceDuplexEngine runs it on every microphone buffer and VoicePipeline turns its changes into barge-in and end-of-turn input.

import AVFoundation
import Foundation

nonisolated struct VoiceActivityConfiguration: Equatable, Sendable {
    var onsetRatio: Float = 3.0
    var releaseRatio: Float = 1.6
    var minimumLevel: Float = 0.012
    var onsetDuration: TimeInterval = 0.04
    var hangover: TimeInterval = 0.3
}

nonisolated struct EnergyVoiceActivityDetector {
    private let configuration: VoiceActivityConfiguration
    private var noiseFloor: Float = 0.003
    private var active = false
    private var aboveFor: TimeInterval = 0
    private var belowFor: TimeInterval = 0

    init(configuration: VoiceActivityConfiguration = VoiceActivityConfiguration()) {
        self.configuration = configuration
    }

    var isActive: Bool { active }

    mutating func process(level: Float, duration: TimeInterval) -> Bool? {
        let onThreshold = max(configuration.minimumLevel, noiseFloor * configuration.onsetRatio)
        let offThreshold = max(configuration.minimumLevel * 0.7, noiseFloor * configuration.releaseRatio)
        if active {
            belowFor = level < offThreshold ? belowFor + duration : 0
            if belowFor >= configuration.hangover {
                active = false
                belowFor = 0
                aboveFor = 0
                return false
            }
            return nil
        }
        if level >= onThreshold {
            aboveFor += duration
            if aboveFor >= configuration.onsetDuration {
                active = true
                aboveFor = 0
                belowFor = 0
                return true
            }
            return nil
        }
        aboveFor = 0
        noiseFloor = noiseFloor * 0.95 + level * 0.05
        return nil
    }

    mutating func reset() {
        active = false
        aboveFor = 0
        belowFor = 0
    }

    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for frame in 0..<Int(buffer.frameLength) { sum += channel[frame] * channel[frame] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }
}

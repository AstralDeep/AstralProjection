// Pads a recognition clip with zeros to 16000*k - 160 samples so the audio encoder sees whole mel windows and no padded frames.
// SpeechRecognizer applies it before every transcription.
import Foundation

public enum AudioPadding {
    public static let sampleRate = 16_000
    private static let trim = 160

    public static func paddedCount(for sampleCount: Int) -> Int {
        let seconds = max(1, (sampleCount + trim + sampleRate - 1) / sampleRate)
        return sampleRate * seconds - trim
    }

    public static func padded(_ samples: [Float]) -> [Float] {
        let target = paddedCount(for: samples.count)
        guard target > samples.count else { return samples }
        return samples + [Float](repeating: 0, count: target - samples.count)
    }
}

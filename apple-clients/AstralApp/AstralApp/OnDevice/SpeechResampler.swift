// Turns speech audio of any sample rate, sample format and channel count into mono Float32 at one target rate, keeping converter state across the buffers of a sentence.
// VoiceDuplexEngine runs every voice through it before playback, and SystemVoiceSpeech uses it without a target rate to flatten system-voice buffers to mono floats.

import AVFoundation
import AstralVoiceSpeech
import Foundation

nonisolated enum SpeechResamplerError: Error, Equatable {
    case formatUnavailable
    case conversionFailed
}

nonisolated final class SpeechResampler: @unchecked Sendable {
    private let targetRate: Double?
    private let lock = NSLock()
    private var source: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var convertedFormat: AVAudioFormat?

    init(targetRate: Double? = nil) {
        self.targetRate = targetRate
    }

    func resample(_ buffer: SpeechAudioBuffer) throws -> [Float] {
        let rate = Double(buffer.sampleRate)
        guard rate.isFinite, rate > 0 else { throw SpeechResamplerError.formatUnavailable }
        if rate == (targetRate ?? rate) { return try lock.withLock { try drainLocked() + buffer.samples } }
        guard !buffer.samples.isEmpty else { return [] }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(buffer.samples.count)),
            let channel = pcm.floatChannelData?[0]
        else { throw SpeechResamplerError.formatUnavailable }
        pcm.frameLength = AVAudioFrameCount(buffer.samples.count)
        buffer.samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        return try resample(pcm)
    }

    func resample(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        try lock.withLock {
            var output = try drainIfFormatChangedLocked(to: buffer.format)
            guard buffer.frameLength > 0 else { return output }
            let rate = buffer.format.sampleRate
            guard rate.isFinite, rate > 0 else { throw SpeechResamplerError.formatUnavailable }
            if buffer.format.commonFormat == .pcmFormatFloat32, buffer.format.channelCount == 1,
                rate == (targetRate ?? rate), let channel = buffer.floatChannelData?[0]
            {
                output += Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                return output
            }
            let active = try converterLocked(for: buffer.format)
            output += try Self.mono(run(active, input: buffer, ending: false))
            return output
        }
    }

    func finish() throws -> [Float] {
        try lock.withLock { try drainLocked() }
    }

    private func drainIfFormatChangedLocked(to format: AVAudioFormat) throws -> [Float] {
        guard let current = source, current != format else { return [] }
        return try drainLocked()
    }

    private func drainLocked() throws -> [Float] {
        defer {
            converter = nil
            convertedFormat = nil
            source = nil
        }
        guard let converter else { return [] }
        return try Self.mono(run(converter, input: nil, ending: true))
    }

    private func converterLocked(for format: AVAudioFormat) throws -> AVAudioConverter {
        if let converter, source == format { return converter }
        guard
            let output = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: targetRate ?? format.sampleRate,
                channels: format.channelCount, interleaved: false),
            let made = AVAudioConverter(from: format, to: output)
        else { throw SpeechResamplerError.formatUnavailable }
        made.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter = made
        convertedFormat = output
        source = format
        return made
    }

    private func run(_ converter: AVAudioConverter, input: AVAudioPCMBuffer?, ending: Bool) throws -> [[Float]] {
        guard let format = convertedFormat else { throw SpeechResamplerError.formatUnavailable }
        let ratio = format.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(max(4_096, ceil(Double(input?.frameLength ?? 0) * ratio) + 4_096))
        var channels = [[Float]](repeating: [], count: Int(format.channelCount))
        var supplied = false
        while true {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw SpeechResamplerError.formatUnavailable
            }
            var failure: NSError?
            let status = converter.convert(to: chunk, error: &failure) { _, inputStatus in
                if let input, !supplied {
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = ending ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error || failure != nil { throw SpeechResamplerError.conversionFailed }
            if let data = chunk.floatChannelData {
                for index in channels.indices {
                    channels[index] += UnsafeBufferPointer(start: data[index], count: Int(chunk.frameLength))
                }
            }
            if status != .haveData { break }
        }
        return channels
    }

    private static func mono(_ channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        guard channels.count > 1 else { return first }
        let scale = 1 / Float(channels.count)
        return first.indices.map { frame in channels.reduce(0) { $0 + $1[frame] } * scale }
    }
}

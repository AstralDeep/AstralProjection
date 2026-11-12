// Reports local model timing and memory for an explicitly requested diagnostic run.
// The normal package suite skips this test; parity and correctness tests carry the required gates.

import MLX
import XCTest

@testable import AstralVoiceModel

final class RealModelDiagnosticsTests: XCTestCase {
    func testMeasure() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ASTRAL_LFM3_DIAGNOSTICS"] == "1",
            "Set ASTRAL_LFM3_DIAGNOSTICS=1 for local timing diagnostics.")
        let dir = try RealModel.require()
        func mb(_ x: Int) -> String { String(format: "%.0f MiB", Double(x) / 1_048_576) }
        Memory.peakMemory = 0
        let t0 = Date()
        let engine = try LFM3AudioEngine(directory: dir)
        print(
            "MEAS load \(Date().timeIntervalSince(t0))s active \(mb(Memory.activeMemory)) peak \(mb(Memory.peakMemory))"
        )
        let wav = try ReferenceFixture.wavSamples()
        for i in 0..<3 {
            let t1 = Date()
            let r = try await engine.transcribe(audio: wav)
            print(
                "MEAS asr#\(i) \(Date().timeIntervalSince(t1))s audio \(Double(wav.count)/16000)s tokens \(r.tokenIDs.count) text \(r.text)"
            )
        }
        for i in 0..<3 {
            let t1 = Date()
            let received = DiagnosticAudioCounter(start: t1)
            let h = LFM3Handlers(onAudio: { pcm in received.append(pcm) })
            var options = LFM3Sampling()
            options.seed = 1
            let r = try await engine.synthesize(
                text: "The patient is stable. Please remind me to call the clinic tomorrow morning.", options: options,
                handlers: h)
            let dur = Double(received.samples) / 24000
            print(
                "MEAS tts#\(i) \(Date().timeIntervalSince(t1))s speech \(dur)s rtf \(Date().timeIntervalSince(t1)/max(dur, 0.001)) firstChunk \(received.firstChunk ?? -1) frames \(r.audioFrames.count)"
            )
        }
        for i in 0..<2 {
            let t1 = Date()
            var options = LFM3Sampling()
            options.maxNewTokens = 24
            let r = try await engine.chat(
                messages: [
                    LFM3Message(
                        role: .system,
                        text:
                            "You are the instant spoken reply of a voice assistant. Say one short acknowledgement of at most eight words."
                    ), LFM3Message(role: .user, text: "Remind me to call the clinic tomorrow."),
                ], options: options)
            print("MEAS chat#\(i) \(Date().timeIntervalSince(t1))s \(r.text)")
        }
        print(
            "MEAS final active \(mb(Memory.activeMemory)) peak \(mb(Memory.peakMemory)) cache \(mb(Memory.cacheMemory))"
        )
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        print("MEAS rss \(mb(Int(info.resident_size))) maxrss via getrusage")
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        print("MEAS peak rss \(mb(Int(ru.ru_maxrss)))")
    }
}

private final class DiagnosticAudioCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let start: Date
    private var total = 0
    private var first: TimeInterval?
    init(start: Date) { self.start = start }
    var samples: Int { lock.withLock { total } }
    var firstChunk: TimeInterval? { lock.withLock { first } }
    func append(_ pcm: [Float]) {
        lock.withLock {
            total += pcm.count
            if first == nil { first = Date().timeIntervalSince(start) }
        }
    }
}

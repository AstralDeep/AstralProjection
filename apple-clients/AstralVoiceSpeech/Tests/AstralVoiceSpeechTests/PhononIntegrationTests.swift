// Loads the real Phonon 31m pack named by ASTRAL_VOICE_PHONON_DIR, speaks one sentence and checks the audio and the absence of network requests.
// It skips when the variable is unset, and no model file is ever committed.
import FluidAudio
import XCTest

@testable import AstralVoiceSpeech

final class PhononIntegrationTests: XCTestCase {
    func testRealModelSpeaksOneSentenceOfflineAndReloadsWithoutARequest() async throws {
        guard let path = ProcessInfo.processInfo.environment["ASTRAL_VOICE_PHONON_DIR"], !path.isEmpty else {
            throw XCTSkip("ASTRAL_VOICE_PHONON_DIR is not set")
        }
        let speech = PhononSpeech()
        guard speech.availability == .available else { throw XCTSkip("needs iOS 18 or macOS 15") }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let tripwire = try LoopbackTripwire()
        try await tripwire.start()
        defer { tripwire.stop() }

        try await speech.load(from: folder)
        let loadedFirst = await speech.isLoaded
        XCTAssertTrue(loadedFirst)
        try await speech.load(from: folder)
        XCTAssertTrue(ModelHub.offlineMode)

        var buffers: [SpeechAudioBuffer] = []
        for try await buffer in try await speech.synthesize(sentence: "Hello there, this is the local voice.") {
            buffers.append(buffer)
        }
        XCTAssertFalse(buffers.isEmpty)
        XCTAssertTrue(buffers.allSatisfy { $0.sampleRate == PocketTtsConstants.audioSampleRate })
        let samples = buffers.flatMap(\.samples)
        XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
        let peak = samples.map { abs($0) }.max() ?? 0
        let rms = (samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count)).squareRoot()
        XCTAssertGreaterThan(peak, 0.05)
        XCTAssertGreaterThan(rms, 0.005)
        let seconds = Double(samples.count) / Double(PocketTtsConstants.audioSampleRate)
        XCTAssertGreaterThan(seconds, 0.5)
        XCTAssertLessThan(seconds, 20)

        await speech.unload()
        try await speech.load(from: folder)
        let again = try await speech.synthesize(sentence: "Once more.")
        var count = 0
        for try await _ in again { count += 1 }
        XCTAssertGreaterThan(count, 0)
        XCTAssertEqual(tripwire.connectionCount, 0)
        await speech.unload()
    }
}

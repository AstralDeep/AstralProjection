// Tests the system voice's selection rule as a pure function and its rendering over a scripted renderer.
// One test renders a real system voice through AVSpeechSynthesizer.write and skips when the device has no voice for the language.

import AVFoundation
import AstralVoiceSpeech
import XCTest

@testable import AstralDeep

final class ScriptedVoiceRenderer: SystemVoiceRendering, @unchecked Sendable {
    final class Handle: SystemVoiceRenderHandle, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var stops: Int { lock.withLock { count } }
        func stop() { lock.withLock { count += 1 } }
    }

    private let voices: [SystemVoiceDescriptor]
    private let lock = NSLock()
    private var callback: (@Sendable (AVAudioBuffer) -> Void)?
    private(set) var requests: [(text: String, voice: String)] = []
    let handle = Handle()

    init(voices: [SystemVoiceDescriptor]) { self.voices = voices }

    func installedVoices() -> [SystemVoiceDescriptor] { voices }

    func render(_ text: String, voice identifier: String, onBuffer: @escaping @Sendable (AVAudioBuffer) -> Void)
        -> any SystemVoiceRenderHandle
    {
        lock.withLock {
            requests.append((text, identifier))
            callback = onBuffer
        }
        return handle
    }

    func emit(_ buffer: AVAudioBuffer) { lock.withLock { callback }?(buffer) }
}

final class SystemVoiceSpeechTests: XCTestCase {
    private func voice(
        _ id: String, _ language: String, _ quality: SystemVoiceDescriptor.Quality = .standard, personal: Bool = false,
        novelty: Bool = false, isDefault: Bool = false
    ) -> SystemVoiceDescriptor {
        SystemVoiceDescriptor(
            identifier: id, language: language, quality: quality, isPersonal: personal, isNovelty: novelty,
            isLocaleDefault: isDefault)
    }

    private func pcm(
        rate: Double, frames: Int, format: AVAudioCommonFormat = .pcmFormatInt16, channels: AVAudioChannelCount = 1
    ) throws -> AVAudioPCMBuffer {
        let audio = try XCTUnwrap(
            AVAudioFormat(commonFormat: format, sampleRate: rate, channels: channels, interleaved: channels > 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio, frameCapacity: AVAudioFrameCount(max(frames, 1))))
        buffer.frameLength = AVAudioFrameCount(frames)
        if format == .pcmFormatInt16, let data = buffer.int16ChannelData {
            for index in 0..<(frames * Int(channels)) { data[0][index] = 8_000 }
        }
        return buffer
    }

    func testSelectionPrefersTheExactLocaleThenTheLocaleDefaultThenQuality() {
        let voices = [
            voice("a", "es-MX", .premium, isDefault: true),
            voice("b", "es-ES", .standard),
            voice("c", "es-ES", .enhanced),
            voice("d", "es-ES", .standard, isDefault: true),
        ]
        XCTAssertEqual(SystemVoiceSelection.select(for: .spanish, from: voices)?.identifier, "d")
        XCTAssertEqual(SystemVoiceSelection.select(for: .spanish, from: Array(voices.dropLast()))?.identifier, "c")
        XCTAssertEqual(SystemVoiceSelection.select(for: .spanish, from: Array(voices.prefix(1)))?.identifier, "a")
    }

    func testSelectionNeverPicksPersonalOrNoveltyVoicesAndReportsNoneWhenOnlyThoseExist() {
        let voices = [
            voice("personal", "en-US", .premium, personal: true, isDefault: true),
            voice("novelty", "en-US", .premium, novelty: true),
            voice("plain", "en-GB"),
        ]
        XCTAssertEqual(SystemVoiceSelection.select(for: .english, from: voices)?.identifier, "plain")
        XCTAssertNil(SystemVoiceSelection.select(for: .english, from: Array(voices.prefix(2))))
    }

    func testSelectionMatchesTheLanguageFamilyAndNormalizesTags() {
        let voices = [voice("fr", "fr_CA"), voice("de", "de-DE"), voice("ja", "ja-JP")]
        XCTAssertEqual(SystemVoiceSelection.select(for: .french, from: voices)?.identifier, "fr")
        XCTAssertEqual(SystemVoiceSelection.select(for: .german, from: voices)?.identifier, "de")
        XCTAssertNil(SystemVoiceSelection.select(for: .korean, from: voices))
        XCTAssertNil(SystemVoiceSelection.select(for: .arabic, from: []))
    }

    func testMandarinNeverSelectsTheCantoneseHongKongVoice() {
        XCTAssertNil(SystemVoiceSelection.select(for: .mandarin, from: [voice("canto", "zh-HK", .premium)]))
        let voices = [voice("canto", "zh-HK", .premium), voice("tw", "zh-TW")]
        XCTAssertEqual(SystemVoiceSelection.select(for: .mandarin, from: voices)?.identifier, "tw")
    }

    func testEveryLanguageHasAnExactLocaleCandidate() {
        for language in ConversationLanguage.allCases {
            let voices = [voice("x", language.localeIdentifier)]
            XCTAssertEqual(SystemVoiceSelection.select(for: language, from: voices)?.identifier, "x")
        }
    }

    func testNoVoiceForTheLanguageIsReportedDistinctly() async {
        let renderer = ScriptedVoiceRenderer(voices: [voice("en", "en-US")])
        let speech = SystemVoiceSpeech(language: { .korean }, renderer: renderer)
        let reason = await speech.unavailability()
        XCTAssertEqual(reason, .noSystemVoice(.korean))
        do {
            _ = try await speech.speak("hello")
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? VoiceSpeechUnavailable, VoiceSpeechUnavailable(reason: .noSystemVoice(.korean)))
        }
        XCTAssertTrue(renderer.requests.isEmpty)
    }

    func testBuffersOfAnyFormatReachTheStreamAsMonoFloatsAndTheEmptyBufferEndsIt() async throws {
        let renderer = ScriptedVoiceRenderer(voices: [voice("es", "es-ES")])
        let speech = SystemVoiceSpeech(language: { .spanish }, renderer: renderer)
        let stream = try await speech.speak("  hola  ")
        XCTAssertEqual(renderer.requests.first?.text, "hola")
        XCTAssertEqual(renderer.requests.first?.voice, "es")
        renderer.emit(try pcm(rate: 22_050, frames: 400))
        renderer.emit(try pcm(rate: 22_050, frames: 300, channels: 2))
        renderer.emit(try pcm(rate: 22_050, frames: 0))
        var buffers: [SpeechAudioBuffer] = []
        for try await buffer in stream { buffers.append(buffer) }
        XCTAssertEqual(buffers.map(\.sampleRate), [22_050, 22_050])
        XCTAssertEqual(buffers.map(\.samples.count), [400, 300])
        XCTAssertEqual(buffers[0].samples[0], 8_000 / 32_768, accuracy: 0.001)
    }

    func testCancelStopsTheRenderAndEndsTheStreamWithCancelled() async throws {
        let renderer = ScriptedVoiceRenderer(voices: [voice("en", "en-US")])
        let speech = SystemVoiceSpeech(language: { .english }, renderer: renderer)
        let stream = try await speech.speak("hello")
        renderer.emit(try pcm(rate: 22_050, frames: 100))
        await speech.cancel()
        XCTAssertGreaterThanOrEqual(renderer.handle.stops, 1)
        var count = 0
        do {
            for try await _ in stream { count += 1 }
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .cancelled)
        }
        XCTAssertEqual(count, 1)
    }

    func testDroppingTheStreamStopsTheRender() async throws {
        let renderer = ScriptedVoiceRenderer(voices: [voice("en", "en-US")])
        let speech = SystemVoiceSpeech(language: { .english }, renderer: renderer)
        var stream: AsyncThrowingStream<SpeechAudioBuffer, Error>? = try await speech.speak("hello")
        XCTAssertNotNil(stream)
        stream = nil
        XCTAssertEqual(renderer.handle.stops, 1)
    }

    func testANonPCMBufferFailsTheSentence() async throws {
        let renderer = ScriptedVoiceRenderer(voices: [voice("en", "en-US")])
        let speech = SystemVoiceSpeech(language: { .english }, renderer: renderer)
        let stream = try await speech.speak("hello")
        let format = try XCTUnwrap(AVAudioFormat(streamDescription: &Self.aac))
        renderer.emit(AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: 1))
        do {
            for try await _ in stream {}
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .synthesisFailed("unsupported system voice buffer"))
        }
    }

    func testAnEmptySentenceIsRefusedBeforeRendering() async {
        let renderer = ScriptedVoiceRenderer(voices: [voice("en", "en-US")])
        let speech = SystemVoiceSpeech(language: { .english }, renderer: renderer)
        do {
            _ = try await speech.speak("   ")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .emptySentence)
        }
    }

    func testARealSystemVoiceRendersAudioThroughWrite() async throws {
        let renderer = LiveSystemVoiceRenderer()
        let speech = SystemVoiceSpeech(language: { .english }, renderer: renderer)
        guard await speech.unavailability() == nil else { throw XCTSkip("No English system voice is installed.") }
        let stream = try await speech.speak("Testing one two three.")
        var total = 0
        var rate = 0
        for try await buffer in stream {
            total += buffer.samples.count
            rate = buffer.sampleRate
        }
        XCTAssertGreaterThan(total, 0)
        XCTAssertGreaterThan(rate, 0)
    }

    private nonisolated(unsafe) static var aac = AudioStreamBasicDescription(
        mSampleRate: 44_100, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
        mFramesPerPacket: 1_024, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
}

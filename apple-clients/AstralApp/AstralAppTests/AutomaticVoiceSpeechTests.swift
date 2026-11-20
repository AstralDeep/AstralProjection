// Covers every branch of the automatic voice switch with scripted local and system voices.
// It checks that English prefers the local voice, that other languages and an explicit choice use the system voice, and that the switch notice fires once.

import AstralVoiceSpeech
import XCTest

@testable import AstralDeep

final class ScriptedSwitchableVoice: SwitchableVoice, @unchecked Sendable {
    private let speech: ScriptedSpeech
    private let lock = NSLock()
    private var reason: VoiceSpeechUnavailability?
    private(set) var warmUps = 0
    private(set) var cancels = 0

    init(speech: ScriptedSpeech, unavailable: VoiceSpeechUnavailability? = nil) {
        self.speech = speech
        reason = unavailable
    }

    var spoken: [String] { speech.spoken }

    func setUnavailable(_ value: VoiceSpeechUnavailability?) { lock.withLock { reason = value } }
    func unavailability() async -> VoiceSpeechUnavailability? { lock.withLock { reason } }
    func warmUp() async throws { lock.withLock { warmUps += 1 } }
    func cancel() async { lock.withLock { cancels += 1 } }
    func speak(_ sentence: String) async throws -> AsyncThrowingStream<SpeechAudioBuffer, Error> {
        try await speech.speak(sentence)
    }
}

final class SwitchNotices: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [VoiceSpeechUnavailability] = []
    var all: [VoiceSpeechUnavailability] { lock.withLock { stored } }
    func record(_ reason: VoiceSpeechUnavailability) { lock.withLock { stored.append(reason) } }
}

final class AutomaticVoiceSpeechTests: XCTestCase {
    private let localAudio = SpeechAudioBuffer(samples: [0.1, 0.2], sampleRate: 24_000)
    private let systemAudio = SpeechAudioBuffer(samples: [0.3], sampleRate: 22_050)

    private func collect(_ stream: AsyncThrowingStream<SpeechAudioBuffer, Error>) async throws -> [SpeechAudioBuffer] {
        var all: [SpeechAudioBuffer] = []
        for try await buffer in stream { all.append(buffer) }
        return all
    }

    private struct Rig {
        let automatic: AutomaticVoiceSpeech
        let local: ScriptedSwitchableVoice
        let system: ScriptedSwitchableVoice
        let notices: SwitchNotices
    }

    private func rig(
        local: ScriptedSpeech, localUnavailable: VoiceSpeechUnavailability? = nil,
        language: ConversationLanguage = .english, choice: EnglishVoiceChoice = .automatic
    ) -> Rig {
        let localVoice = ScriptedSwitchableVoice(speech: local, unavailable: localUnavailable)
        let systemVoice = ScriptedSwitchableVoice(speech: ScriptedSpeech(buffers: [systemAudio]))
        let notices = SwitchNotices()
        let automatic = AutomaticVoiceSpeech(
            local: localVoice, system: systemVoice, language: { language }, englishChoice: { choice },
            onSwitch: { notices.record($0) })
        return Rig(automatic: automatic, local: localVoice, system: systemVoice, notices: notices)
    }

    func testEnglishPrefersTheLocalVoiceWithoutANotice() async throws {
        let rig = rig(local: ScriptedSpeech(buffers: [localAudio]))
        let audio = try await collect(try await rig.automatic.speak("hello"))
        XCTAssertEqual(audio, [localAudio])
        XCTAssertTrue(rig.system.spoken.isEmpty)
        XCTAssertTrue(rig.notices.all.isEmpty)
    }

    func testEnglishFallsBackWhenTheLocalVoiceIsUnavailableAndReportsOnceAcrossSentences() async throws {
        let rig = rig(local: ScriptedSpeech(buffers: [localAudio]), localUnavailable: .notInstalled)
        for sentence in ["one", "two", "three"] {
            let audio = try await collect(try await rig.automatic.speak(sentence))
            XCTAssertEqual(audio, [systemAudio])
        }
        XCTAssertEqual(rig.notices.all, [.notInstalled])
        XCTAssertTrue(rig.local.spoken.isEmpty)
    }

    func testALoadFailureOnSpeakFallsBackWithTheFailureReason() async throws {
        let failing = ScriptedSpeech(
            buffers: [], speakFailure: VoiceSpeechUnavailable(reason: .loadFailed))
        let rig = rig(local: failing)
        let audio = try await collect(try await rig.automatic.speak("hello"))
        XCTAssertEqual(audio, [systemAudio])
        XCTAssertEqual(rig.notices.all, [.loadFailed])
    }

    func testOtherErrorsFromStartingTheLocalVoiceAreNotHidden() async {
        let failing = ScriptedSpeech(buffers: [], speakFailure: SpeechSynthesisError.emptySentence)
        let rig = rig(local: failing)
        do {
            _ = try await rig.automatic.speak("hello")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .emptySentence)
        }
        XCTAssertTrue(rig.system.spoken.isEmpty)
    }

    func testAFailureBeforeAnyAudioFinishesTheSentenceWithTheSystemVoice() async throws {
        let rig = rig(local: ScriptedSpeech(buffers: [], failure: SpeechSynthesisError.synthesisFailed("x")))
        let audio = try await collect(try await rig.automatic.speak("hello"))
        XCTAssertEqual(audio, [systemAudio])
        XCTAssertEqual(rig.system.spoken, ["hello"])
        XCTAssertEqual(rig.notices.all, [.synthesisFailed])
    }

    func testAFailureAfterAudioWasYieldedFailsTheSentenceAsBefore() async {
        let rig = rig(
            local: ScriptedSpeech(buffers: [localAudio], failure: SpeechSynthesisError.synthesisFailed("x")))
        var heard: [SpeechAudioBuffer] = []
        do {
            for try await buffer in try await rig.automatic.speak("hello") { heard.append(buffer) }
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .synthesisFailed("x"))
        }
        XCTAssertEqual(heard, [localAudio])
        XCTAssertTrue(rig.system.spoken.isEmpty)
        XCTAssertTrue(rig.notices.all.isEmpty)
    }

    func testACancelledLocalSentenceDoesNotFallBack() async {
        let rig = rig(local: ScriptedSpeech(buffers: [], failure: SpeechSynthesisError.cancelled))
        do {
            for try await _ in try await rig.automatic.speak("hello") {}
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .cancelled)
        }
        XCTAssertTrue(rig.system.spoken.isEmpty)
    }

    func testTheOtherSevenLanguagesUseTheSystemVoiceWithoutANotice() async throws {
        for language in ConversationLanguage.allCases where language != .english {
            let rig = rig(local: ScriptedSpeech(buffers: [localAudio]), language: language)
            let audio = try await collect(try await rig.automatic.speak("hola"))
            XCTAssertEqual(audio, [systemAudio], language.rawValue)
            XCTAssertTrue(rig.local.spoken.isEmpty)
            XCTAssertTrue(rig.notices.all.isEmpty)
        }
    }

    func testAnExplicitSystemChoiceForEnglishUsesTheSystemVoiceWithoutANotice() async throws {
        let rig = rig(local: ScriptedSpeech(buffers: [localAudio]), choice: .system)
        let audio = try await collect(try await rig.automatic.speak("hello"))
        XCTAssertEqual(audio, [systemAudio])
        XCTAssertTrue(rig.local.spoken.isEmpty)
        XCTAssertTrue(rig.notices.all.isEmpty)
    }

    func testALaterFailureIsReportedAgainOnlyAfterTheLocalVoiceSpokeSuccessfully() async throws {
        let rig = rig(local: ScriptedSpeech(buffers: [localAudio]), localUnavailable: .loadFailed)
        _ = try await collect(try await rig.automatic.speak("a"))
        _ = try await collect(try await rig.automatic.speak("b"))
        XCTAssertEqual(rig.notices.all, [.loadFailed])
        rig.local.setUnavailable(nil)
        _ = try await collect(try await rig.automatic.speak("c"))
        rig.local.setUnavailable(.notInstalled)
        _ = try await collect(try await rig.automatic.speak("d"))
        XCTAssertEqual(rig.notices.all, [.loadFailed, .notInstalled])
    }

    func testTheSystemVoiceMissingForTheLanguageSurfacesDistinctly() async {
        let local = ScriptedSwitchableVoice(speech: ScriptedSpeech(buffers: []), unavailable: .notInstalled)
        let missing = ScriptedSpeech(
            buffers: [], speakFailure: VoiceSpeechUnavailable(reason: .noSystemVoice(.english)))
        let automatic = AutomaticVoiceSpeech(
            local: local, system: ScriptedSwitchableVoice(speech: missing), language: { .english })
        do {
            _ = try await automatic.speak("hello")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? VoiceSpeechUnavailable, VoiceSpeechUnavailable(reason: .noSystemVoice(.english)))
        }
    }

    func testWarmUpTouchesOnlyTheLocalVoiceAndOnlyWhenItWillSpeak() async {
        let english = rig(local: ScriptedSpeech(buffers: []))
        await english.automatic.warmUp()
        XCTAssertEqual(english.local.warmUps, 1)
        let spanish = rig(local: ScriptedSpeech(buffers: []), language: .spanish)
        await spanish.automatic.warmUp()
        XCTAssertEqual(spanish.local.warmUps, 0)
        await english.automatic.cancel()
        XCTAssertEqual(english.local.cancels, 1)
        XCTAssertEqual(english.system.cancels, 1)
    }
}

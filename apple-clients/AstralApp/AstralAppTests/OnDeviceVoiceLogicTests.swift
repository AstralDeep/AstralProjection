// Verifies sentence splitting, speech text cleaning, voice activity detection, end-of-turn timing, speech timelines and push-to-talk key state.
// All inputs are synthetic and the clock is controlled.

import AVFoundation
@testable import AstralDeep
import XCTest

final class OnDeviceVoiceLogicTests: XCTestCase {
    func testVoiceLevelHandlesInterleavedIntegerAndPlanarFloatingPointPCM() throws {
        let interleaved = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true))
        let integer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: interleaved, frameCapacity: 100))
        integer.frameLength = 100
        for index in 0..<200 { integer.int16ChannelData![0][index] = 16_384 }
        XCTAssertEqual(EnergyVoiceActivityDetector.level(of: integer), 0.5, accuracy: 0.0001)
        let planar = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let floating = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: planar, frameCapacity: 100))
        floating.frameLength = 100
        for channel in 0..<2 {
            for index in 0..<100 { floating.floatChannelData![channel][index] = 0.5 }
        }
        XCTAssertEqual(EnergyVoiceActivityDetector.level(of: floating), 0.5, accuracy: 0.0001)
        floating.floatChannelData![0][0] = .nan
        XCTAssertEqual(EnergyVoiceActivityDetector.level(of: floating), 0)
    }

    func testSplitterEmitsCompleteSentencesAcrossDeltas() {
        var splitter = VoiceSentenceSplitter()
        XCTAssertEqual(splitter.append("Hello there. How a"), ["Hello there."])
        XCTAssertEqual(splitter.append("re you? Fine"), ["How are you?"])
        XCTAssertEqual(splitter.append(", thanks."), [])
        XCTAssertEqual(splitter.flush(), ["Fine, thanks."])
        XCTAssertEqual(splitter.flush(), [])
    }

    func testSplitterKeepsAbbreviationsAndDecimalsTogether() {
        var splitter = VoiceSentenceSplitter()
        XCTAssertEqual(
            splitter.append("Dr. Smith paid 3.5 dollars. Then left. "), ["Dr. Smith paid 3.5 dollars.", "Then left."])
        XCTAssertEqual(splitter.append("J. Doe came. "), ["J. Doe came."])
    }

    func testSplitterBreaksOnNewlinesAndLongClauses() {
        var splitter = VoiceSentenceSplitter()
        XCTAssertEqual(splitter.append("- item one\n- item two\n"), ["- item one", "- item two"])
        let long = String(repeating: "word ", count: 20) + "and, then " + String(repeating: "more ", count: 20)
        let pieces = splitter.append(long)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertTrue(pieces[0].hasSuffix("and,"))
    }

    func testSplitterWaitsForWhitespaceAfterTerminator() {
        var splitter = VoiceSentenceSplitter()
        XCTAssertEqual(splitter.append("Version 2."), [])
        XCTAssertEqual(splitter.append("5 is out. "), ["Version 2.5 is out."])
    }

    func testSpeechTextRemovesMarkupAndLinks() {
        XCTAssertEqual(VoiceSpeechText.clean("**Bold** and `code` here."), "Bold and code here.")
        XCTAssertEqual(VoiceSpeechText.clean("See [the docs](https://example.com/x) now."), "See the docs now.")
        XCTAssertEqual(VoiceSpeechText.clean("## Heading"), "Heading")
        XCTAssertEqual(VoiceSpeechText.clean("1. First step"), "First step")
        XCTAssertEqual(VoiceSpeechText.clean("---"), "")
        XCTAssertEqual(VoiceSpeechText.clean("Visit https://example.com today"), "Visit today")
    }

    func testDetectorOnsetNeedsSustainedEnergy() {
        var detector = EnergyVoiceActivityDetector()
        for _ in 0..<20 { XCTAssertNil(detector.process(level: 0.002, duration: 0.02)) }
        XCTAssertNil(detector.process(level: 0.2, duration: 0.02))
        XCTAssertNil(detector.process(level: 0.002, duration: 0.02))
        XCTAssertFalse(detector.isActive)
        XCTAssertNil(detector.process(level: 0.2, duration: 0.02))
        XCTAssertEqual(detector.process(level: 0.2, duration: 0.02), true)
        XCTAssertTrue(detector.isActive)
    }

    func testDetectorReleasesOnlyAfterTheHangover() {
        var detector = EnergyVoiceActivityDetector()
        _ = detector.process(level: 0.2, duration: 0.05)
        XCTAssertTrue(detector.isActive)
        var changes: [Bool] = []
        for _ in 0..<20 { if let change = detector.process(level: 0.001, duration: 0.02) { changes.append(change) } }
        XCTAssertEqual(changes, [false])
        XCTAssertFalse(detector.isActive)
    }

    func testDetectorBriefDipsInsideSpeechKeepItActive() {
        var detector = EnergyVoiceActivityDetector()
        _ = detector.process(level: 0.2, duration: 0.05)
        for _ in 0..<5 { XCTAssertNil(detector.process(level: 0.001, duration: 0.02)) }
        XCTAssertNil(detector.process(level: 0.2, duration: 0.02))
        for _ in 0..<5 { XCTAssertNil(detector.process(level: 0.001, duration: 0.02)) }
        XCTAssertTrue(detector.isActive)
    }

    func testDetectorAdaptsToANoisyRoom() {
        var detector = EnergyVoiceActivityDetector()
        for _ in 0..<200 { _ = detector.process(level: 0.01, duration: 0.02) }
        XCTAssertNil(detector.process(level: 0.02, duration: 0.05))
        XCTAssertFalse(detector.isActive)
    }

    private func detector(_ clock: ManualVoiceClock, mode: VoiceCaptureMode = .handsFree) -> VoiceEndOfTurnDetector {
        VoiceEndOfTurnDetector(clock: clock, mode: mode)
    }

    func testSilenceSpeculatesThenEndsTheTurn() {
        let clock = ManualVoiceClock()
        let turn = detector(clock)
        _ = turn.voiceActivity(active: true)
        _ = turn.partial("what is the weather")
        _ = turn.voiceActivity(active: false)
        XCTAssertEqual(turn.tick(), [])
        clock.advance(0.26)
        XCTAssertEqual(turn.tick(), [.speculate("what is the weather")])
        XCTAssertEqual(turn.tick(), [])
        clock.advance(0.4)
        XCTAssertEqual(turn.tick(), [.endOfTurn("what is the weather")])
        XCTAssertEqual(turn.tick(), [])
    }

    func testTalkingAgainDiscardsTheDraftAndRestartsTheTurn() {
        let clock = ManualVoiceClock()
        let turn = detector(clock)
        _ = turn.partial("what is")
        _ = turn.voiceActivity(active: false)
        clock.advance(0.3)
        XCTAssertEqual(turn.tick(), [.speculate("what is")])
        XCTAssertEqual(turn.voiceActivity(active: true), [.discardDraft])
        XCTAssertEqual(turn.partial("what is the weather"), [])
        _ = turn.voiceActivity(active: false)
        clock.advance(0.3)
        XCTAssertEqual(turn.tick(), [.speculate("what is the weather")])
    }

    func testChangedTranscriptDuringSilenceDiscardsTheDraft() {
        let clock = ManualVoiceClock()
        let turn = detector(clock)
        _ = turn.partial("call mom")
        _ = turn.voiceActivity(active: false)
        clock.advance(0.3)
        _ = turn.tick()
        XCTAssertEqual(turn.partial("call mom tomorrow"), [.discardDraft])
    }

    func testTrailingConnectorWordHoldsTheTurnOpenLonger() {
        let clock = ManualVoiceClock()
        let turn = detector(clock)
        _ = turn.partial("set a timer for ten minutes and")
        _ = turn.voiceActivity(active: false)
        clock.advance(0.7)
        XCTAssertFalse(turn.tick().contains(.endOfTurn("set a timer for ten minutes and")))
        clock.advance(0.4)
        XCTAssertTrue(turn.tick().contains(.endOfTurn("set a timer for ten minutes and")))
    }

    func testRecognizerFinalEndsTheTurnImmediately() {
        let turn = detector(ManualVoiceClock())
        XCTAssertEqual(turn.finalized(" done "), [.endOfTurn("done")])
        XCTAssertEqual(turn.finalized("  "), [])
    }

    func testPushToTalkEndsOnReleaseNotOnSilence() {
        let clock = ManualVoiceClock()
        let turn = detector(clock, mode: .pushToTalk)
        _ = turn.partial("hello there")
        _ = turn.voiceActivity(active: false)
        clock.advance(5)
        XCTAssertEqual(turn.tick(), [])
        XCTAssertEqual(turn.release(), [.endOfTurn("hello there")])
        XCTAssertEqual(detector(clock).release(), [])
    }

    func testTimelineCountsOnlyCompletedWords() {
        let text = "Alpha beta gamma"
        let timeline = VoiceSpeechTimeline.make(
            text: text,
            wordRanges: [
                (NSRange(location: 0, length: 5), 0), (NSRange(location: 6, length: 4), 100),
                (NSRange(location: 11, length: 5), 200),
            ], secondsPerOffsetUnit: 0.01)
        XCTAssertEqual(timeline.charactersSpoken(atSeconds: 0.5), 0)
        XCTAssertEqual(timeline.charactersSpoken(atSeconds: 1.0), 5)
        XCTAssertEqual(timeline.charactersSpoken(atSeconds: 2.5), 10)
    }

    func testPushToTalkEvaluatorTracksPressAndRelease() {
        var evaluator = PushToTalkKeyEvaluator()
        XCTAssertEqual(evaluator.evaluate(keyCode: 10, isPressed: true), .none)
        XCTAssertEqual(evaluator.evaluate(keyCode: PushToTalkKeyEvaluator.rightOptionKeyCode, isPressed: true), .press)
        XCTAssertEqual(evaluator.evaluate(keyCode: PushToTalkKeyEvaluator.rightOptionKeyCode, isPressed: true), .none)
        XCTAssertEqual(
            evaluator.evaluate(keyCode: PushToTalkKeyEvaluator.rightOptionKeyCode, isPressed: false), .release)
        XCTAssertEqual(evaluator.evaluate(keyCode: PushToTalkKeyEvaluator.rightOptionKeyCode, isPressed: false), .none)
    }

    func testPushToTalkResetReleasesAHeldKey() {
        var evaluator = PushToTalkKeyEvaluator()
        XCTAssertEqual(evaluator.reset(), .none)
        _ = evaluator.evaluate(keyCode: PushToTalkKeyEvaluator.rightOptionKeyCode, isPressed: true)
        XCTAssertEqual(evaluator.reset(), .release)
    }
}

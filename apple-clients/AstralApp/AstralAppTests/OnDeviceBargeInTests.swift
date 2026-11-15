// Verifies the barge-in state machine against a controlled clock: ducking, the 250 ms confirmation, backchannels, played-text records and tool cancellation.
// Real-microphone timing is not covered here and must be checked live.

import XCTest

@testable import AstralDeep

final class OnDeviceBargeInTests: XCTestCase {
    private var clock = ManualVoiceClock()
    private var controller: BargeInController!

    override func setUp() {
        clock = ManualVoiceClock()
        controller = BargeInController(clock: clock)
    }

    private func startSpeaking(_ sentences: [String] = ["Hello there.", "This is a long sentence."]) {
        for sentence in sentences { _ = controller.enqueue(sentence: sentence) }
    }

    func testSentencesPlayOneAtATime() {
        XCTAssertEqual(controller.enqueue(sentence: "One."), [.speak(index: 0, text: "One.")])
        XCTAssertEqual(controller.enqueue(sentence: "Two."), [])
        XCTAssertEqual(
            controller.sentenceFinished(index: 0, completed: true), [.speak(index: 1, text: "Two.")])
        XCTAssertEqual(controller.sentenceFinished(index: 1, completed: true), [])
        XCTAssertFalse(controller.isSpeaking)
    }

    func testSoundWhileSpeakingDucksImmediately() {
        startSpeaking()
        XCTAssertEqual(controller.voiceActivity(active: true), [.duck(volume: 0.15)])
    }

    func testSoundWhileIdleDoesNothing() {
        XCTAssertEqual(controller.voiceActivity(active: true), [])
        XCTAssertEqual(controller.voiceActivity(active: false), [])
    }

    func testCoughEndingBeforeConfirmationRestoresVolumeAndKeepsSpeaking() {
        startSpeaking()
        _ = controller.voiceActivity(active: true)
        clock.advance(0.15)
        XCTAssertEqual(controller.voiceActivity(active: false), [.restoreVolume])
        XCTAssertTrue(controller.isSpeaking)
    }

    func testBackchannelDoesNotStopSpeechEvenWhenItLasts() {
        startSpeaking()
        _ = controller.voiceActivity(active: true)
        clock.advance(0.1)
        XCTAssertEqual(controller.partialTranscript("mm-hm"), [])
        clock.advance(0.4)
        XCTAssertEqual(controller.tick(), [])
        XCTAssertEqual(controller.voiceActivity(active: false), [.restoreVolume])
        XCTAssertTrue(controller.isSpeaking)
    }

    func testShortAcknowledgementWordsDoNotStopSpeech() {
        startSpeaking()
        _ = controller.voiceActivity(active: true)
        clock.advance(0.3)
        XCTAssertEqual(controller.partialTranscript("okay"), [])
        XCTAssertEqual(controller.voiceActivity(active: false), [.restoreVolume])
    }

    func testWordsThatContinuePastTheWindowConfirmTheInterruption() {
        startSpeaking()
        _ = controller.voiceActivity(active: true)
        clock.advance(0.1)
        XCTAssertEqual(controller.partialTranscript("wait"), [])
        XCTAssertEqual(controller.nextDeadline, 100.25)
        clock.advance(0.15)
        let actions = controller.tick()
        XCTAssertEqual(actions.first, .stopSpeech)
        XCTAssertTrue(actions.contains(.cancelModelStream))
        XCTAssertEqual(actions.last, .beginUserTurn)
        XCTAssertFalse(controller.isSpeaking)
    }

    func testConfirmedInterruptionIsSilentWithinHalfASecondOfOnset() throws {
        startSpeaking()
        let onset = clock.now
        _ = controller.voiceActivity(active: true)
        clock.advance(0.1)
        _ = controller.partialTranscript("stop talking")
        var stoppedAt: TimeInterval?
        while stoppedAt == nil, clock.now - onset < 1 {
            clock.advance(0.02)
            if controller.tick().contains(.stopSpeech) { stoppedAt = clock.now }
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(stoppedAt) - onset, 0.5)
    }

    func testWordsArrivingLateStillConfirmImmediately() {
        startSpeaking()
        _ = controller.voiceActivity(active: true)
        clock.advance(0.4)
        XCTAssertTrue(controller.partialTranscript("hold on").contains(.stopSpeech))
    }

    func testShortUtteranceWithWordsConfirmsWhenSoundEnds() {
        startSpeaking()
        _ = controller.voiceActivity(active: true)
        clock.advance(0.1)
        _ = controller.partialTranscript("stop")
        clock.advance(0.05)
        XCTAssertTrue(controller.voiceActivity(active: false).contains(.stopSpeech))
    }

    func testWordsHeardBeforeOnsetDoNotCount() {
        startSpeaking()
        _ = controller.partialTranscript("earlier words")
        _ = controller.voiceActivity(active: true)
        clock.advance(0.5)
        XCTAssertEqual(controller.partialTranscript("earlier words"), [])
        XCTAssertTrue(controller.partialTranscript("earlier words now").contains(.stopSpeech))
    }

    func testNoiseWithoutWordsIsDismissedAndNotRetriggeredUntilItEnds() {
        startSpeaking()
        _ = controller.voiceActivity(active: true)
        clock.advance(1.6)
        XCTAssertEqual(controller.tick(), [.restoreVolume])
        XCTAssertEqual(controller.voiceActivity(active: true), [])
        XCTAssertEqual(controller.voiceActivity(active: false), [])
        XCTAssertEqual(controller.voiceActivity(active: true), [.duck(volume: 0.15)])
    }

    func testOnlyPlayedTextIsRecorded() {
        startSpeaking(["Hello there.", "This is a long sentence.", "Never reached."])
        _ = controller.sentenceFinished(index: 0, completed: true)
        controller.sentenceProgress(index: 1, characters: 12)
        _ = controller.voiceActivity(active: true)
        clock.advance(0.3)
        let actions = controller.partialTranscript("wait")
        XCTAssertTrue(actions.contains(.recordSpoken("Hello there. This is a")))
        XCTAssertEqual(controller.spokenText, "")
    }

    func testPartialWordAtTheCutIsDropped() {
        startSpeaking(["Alpha beta gamma."])
        controller.sentenceProgress(index: 0, characters: 8)
        XCTAssertEqual(controller.spokenText, "Alpha")
        controller.sentenceProgress(index: 0, characters: 11)
        XCTAssertEqual(controller.spokenText, "Alpha beta")
    }

    func testMarkupStrippedSpeechMapsBackToTheOriginalText() {
        _ = controller.enqueue(sentence: "**Bold** words here.", speech: "Bold words here.")
        controller.sentenceProgress(index: 0, characters: 10)
        XCTAssertEqual(controller.spokenText, "**Bold** words")
        controller.sentenceProgress(index: 0, characters: 13)
        XCTAssertEqual(controller.spokenText, "**Bold** words")
    }

    func testSentenceWithNothingToSpeakCountsAsPlayed() {
        XCTAssertEqual(controller.enqueue(sentence: "---", speech: ""), [])
        XCTAssertEqual(controller.enqueue(sentence: "Next.", speech: "Next."), [.speak(index: 1, text: "Next.")])
        XCTAssertEqual(controller.spokenText, "---")
    }

    func testFalseAlarmResumesFromTheNextUnspokenSentence() {
        startSpeaking(["First.", "Second."])
        _ = controller.voiceActivity(active: true)
        XCTAssertEqual(controller.sentenceFinished(index: 0, completed: true), [])
        XCTAssertEqual(
            controller.voiceActivity(active: false), [.restoreVolume, .speak(index: 1, text: "Second.")])
    }

    func testOnlyCancelSafeToolsAreCancelled() {
        startSpeaking()
        controller.toolStarted(id: "search", cancelSafe: true)
        controller.toolStarted(id: "send_email", cancelSafe: false)
        controller.toolStarted(id: "done", cancelSafe: true)
        controller.toolFinished(id: "done")
        _ = controller.voiceActivity(active: true)
        clock.advance(0.3)
        let actions = controller.partialTranscript("stop")
        XCTAssertEqual(actions.filter { if case .cancelTool = $0 { true } else { false } }, [.cancelTool(id: "search")])
    }

    func testPendingRiskyActionIsLeftAloneByAnInterruption() {
        startSpeaking()
        controller.toolStarted(id: "search", cancelSafe: true)
        controller.setRiskyActionPending(true)
        _ = controller.voiceActivity(active: true)
        clock.advance(0.3)
        let actions = controller.partialTranscript("yes approve it")
        XCTAssertTrue(actions.contains(.stopSpeech))
        XCTAssertFalse(actions.contains(.cancelModelStream))
        XCTAssertFalse(actions.contains(.cancelTool(id: "search")))
    }

    func testResetClearsEverything() {
        startSpeaking()
        _ = controller.voiceActivity(active: true)
        controller.reset()
        XCTAssertFalse(controller.isSpeaking)
        XCTAssertNil(controller.nextDeadline)
    }
}

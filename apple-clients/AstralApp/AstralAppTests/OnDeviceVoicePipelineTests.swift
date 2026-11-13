// Drives VoicePipeline end to end with fake audio, transcriber, kernel link and model under a controlled clock.
// Covers turn flow, integrity labels, the absence of any approval path, interruption records and acknowledgement rules.

import AVFoundation
@testable import AstralDeep
import XCTest

@MainActor
final class OnDeviceVoicePipelineTests: XCTestCase {
    private var clock = ManualVoiceClock()
    private var audio = FakeDuplexAudio()
    private var transcriber = FakeTranscriber()
    private var link = FakeKernelLink()

    override func setUp() async throws {
        clock = ManualVoiceClock()
        audio = FakeDuplexAudio()
        transcriber = FakeTranscriber()
        link = FakeKernelLink()
    }

    private func makePipeline(
        trigger: VoiceSessionTrigger = .ownerGesture, mode: VoiceCaptureMode = .handsFree,
        model: AstralOnDeviceModel? = nil
    ) throws -> VoicePipeline {
        let fast = model.map { VoiceFastPath(model: $0) }
        let pipeline = VoicePipeline(
            audio: audio, transcriber: transcriber, fastPath: fast, link: link, clock: clock)
        try pipeline.start(trigger: trigger, mode: mode)
        return pipeline
    }

    private func speak(_ pipeline: VoicePipeline, _ text: String, silence: TimeInterval = 0.7) {
        pipeline.handleVoiceActivity(true)
        pipeline.handleRecognizer(.partial(text))
        pipeline.handleVoiceActivity(false)
        clock.advance(silence)
        pipeline.tick()
    }

    func testStartingOpensAudioAndASegment() throws {
        let pipeline = try makePipeline()
        XCTAssertTrue(audio.started)
        XCTAssertEqual(transcriber.begun, 1)
        XCTAssertThrowsError(try pipeline.start(trigger: .ownerGesture))
        pipeline.stop()
        XCTAssertTrue(audio.stopped)
        XCTAssertEqual(transcriber.shutdowns, 1)
        XCTAssertFalse(pipeline.isRunning)
    }

    func testSilentListeningDoesNotFeedTheModelAndSpeechIncludesItsOnset() throws {
        let pipeline = try makePipeline()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        for _ in 0..<100 { audio.onMicrophone?(buffer) }
        XCTAssertEqual(transcriber.appendedFrames, 0)
        audio.onVoiceActivity?(true)
        audio.onMicrophone?(buffer)
        XCTAssertGreaterThan(transcriber.appendedFrames, 160)
        audio.onVoiceActivity?(false)
        XCTAssertEqual(transcriber.partialFlushes, 1)
        pipeline.stop()
    }

    func testUnsolicitedRecognitionWithoutVoiceActivityCannotCreateAPhantomTurn() throws {
        let pipeline = try makePipeline()
        pipeline.handleRecognizer(.partial("a synthetic hallucination"))
        clock.advance(2)
        pipeline.tick()
        pipeline.handleRecognizer(.final("a synthetic hallucination"))
        XCTAssertTrue(link.turns.isEmpty)
        pipeline.stop()
    }

    func testAudioStartFailureCleansUpTheGraph() throws {
        audio.startError = .voiceProcessingUnavailable
        XCTAssertThrowsError(try makePipeline())
        XCTAssertTrue(audio.stopped)
    }

    func testSpokenTurnReachesTheKernelAsAnOwnerTranscript() throws {
        let pipeline = try makePipeline()
        speak(pipeline, "what time is it")
        XCTAssertEqual(transcriber.ended, 1)
        pipeline.handleRecognizer(.final("What time is it?"))
        XCTAssertEqual(link.turns.count, 1)
        XCTAssertEqual(link.turns[0].text, "What time is it?")
        XCTAssertEqual(link.turns[0].integrity, .owner)
        XCTAssertEqual(link.turns[0].source, .deviceMicrophone)
        pipeline.stop()
    }

    func testMissingFinalReportsTimeoutWithoutSubmittingAStalePartial() throws {
        let pipeline = try makePipeline()
        var failures: [String] = []
        pipeline.onFailure = { failures.append($0) }
        speak(pipeline, "turn on the lights")
        XCTAssertTrue(link.turns.isEmpty)
        clock.advance(9)
        pipeline.tick()
        XCTAssertTrue(link.turns.isEmpty)
        XCTAssertEqual(failures, ["voice_recognition_timed_out"])
        pipeline.stop()
    }

    func testSlowFinalReplacesTheEarlyPartialBeforeItCanBecomeAnOwnerTurn() throws {
        let pipeline = try makePipeline()
        speak(pipeline, "What")
        clock.advance(2)
        pipeline.tick()
        XCTAssertTrue(link.turns.isEmpty)
        pipeline.handleRecognizer(.final("What is two plus two?"))
        XCTAssertEqual(link.turns.map(\.text), ["What is two plus two?"])
        pipeline.stop()
    }

    func testEmptyFinalNeverPromotesAnEarlierPartial() throws {
        let pipeline = try makePipeline()
        speak(pipeline, "an unfinished phrase")
        pipeline.handleRecognizer(.final(""))
        XCTAssertTrue(link.turns.isEmpty)
        pipeline.stop()
    }

    func testLateFinalFromATimedOutSegmentCannotSubmitAnotherTurn() throws {
        let pipeline = try makePipeline()
        let identifier = UUID()
        speak(pipeline, "turn on the lights")
        clock.advance(9)
        pipeline.tick()
        pipeline.handleRecognizer(.final("Turn on the lights.", segmentID: identifier))
        XCTAssertTrue(link.turns.isEmpty)
        pipeline.stop()
    }

    func testSessionNotStartedByTheOwnerProducesUntrustedTranscripts() throws {
        let pipeline = try makePipeline(trigger: .programmatic)
        speak(pipeline, "send the report")
        pipeline.handleRecognizer(.final("send the report"))
        XCTAssertEqual(link.turns.first?.integrity, .untrusted)
        pipeline.stop()
    }

    func testOnlyTheDeviceMicrophoneInAnOwnerSessionIsOwnerIntegrity() {
        let sources: [VoiceAudioSource] = [.deviceMicrophone, .file, .call, .other]
        for source in sources {
            for trigger in [VoiceSessionTrigger.ownerGesture, .pushToTalk, .programmatic] {
                let turn = OwnerVoiceTurn.make(
                    text: "hello", source: source, trigger: trigger, riskyActionPending: false)
                let expected: VoiceTranscriptIntegrity =
                    source == .deviceMicrophone && trigger != .programmatic ? .owner : .untrusted
                XCTAssertEqual(turn?.integrity, expected, "\(source) \(trigger)")
            }
        }
        XCTAssertNil(
            OwnerVoiceTurn.make(
                text: "  ", source: .deviceMicrophone, trigger: .ownerGesture, riskyActionPending: false))
        XCTAssertNil(
            OwnerVoiceTurn.make(
                text: "bad\u{0}text", source: .deviceMicrophone, trigger: .ownerGesture, riskyActionPending: false))
    }

    func testSayingYesToAPendingRiskyActionIsOnlyEverATranscript() throws {
        let pipeline = try makePipeline()
        pipeline.setRiskyActionPending(true)
        speak(pipeline, "yes approve it")
        pipeline.handleRecognizer(.final("Yes, approve it."))
        XCTAssertEqual(link.turns.count, 1)
        XCTAssertTrue(link.turns[0].riskyActionPending)
        XCTAssertFalse(link.turns[0].approvalEligible)
        XCTAssertEqual(link.cancelledTurns, 0)
        XCTAssertTrue(link.cancelledTools.isEmpty)
        XCTAssertTrue(link.spoken.isEmpty)
        pipeline.stop()
    }

    func testAnswerStreamsSentenceBySentence() throws {
        let pipeline = try makePipeline()
        speak(pipeline, "tell me something")
        pipeline.handleRecognizer(.final("Tell me something."))
        pipeline.answerDelta("First sentence. Second sen")
        XCTAssertEqual(audio.spoken.map(\.text), ["First sentence."])
        pipeline.handleSpeech(.finished(index: 0))
        XCTAssertEqual(audio.spoken.count, 1)
        pipeline.answerDelta("tence.")
        pipeline.answerFinished()
        XCTAssertEqual(audio.spoken.map(\.text), ["First sentence.", "Second sentence."])
        pipeline.stop()
    }

    func testAnswerBeforeAnyTurnIsIgnored() throws {
        let pipeline = try makePipeline()
        pipeline.answerDelta("Unprompted speech.")
        XCTAssertTrue(audio.spoken.isEmpty)
        pipeline.stop()
    }

    func testRealInterruptionStopsSpeechCancelsTheStreamAndRecordsOnlyWhatWasPlayed() throws {
        let pipeline = try makePipeline()
        speak(pipeline, "tell me a story")
        pipeline.handleRecognizer(.final("Tell me a story."))
        pipeline.toolStarted(id: "lookup", cancelSafe: true)
        pipeline.toolStarted(id: "write", cancelSafe: false)
        pipeline.answerDelta("Once upon a time there was a fox. It ran far away. The end.")
        pipeline.handleSpeech(.finished(index: 0))
        audio.progress = VoiceSpeechProgress(index: 1, characters: 6)
        pipeline.handleVoiceActivity(true)
        XCTAssertEqual(audio.volumes.last, 0.15)
        clock.advance(0.1)
        pipeline.handleRecognizer(.partial("wait"))
        XCTAssertEqual(audio.stopSpeakingCount, 0)
        clock.advance(0.2)
        pipeline.tick()
        XCTAssertEqual(audio.stopSpeakingCount, 1)
        XCTAssertEqual(audio.volumes.last, 1)
        XCTAssertEqual(link.cancelledTurns, 1)
        XCTAssertEqual(link.cancelledTools, ["lookup"])
        XCTAssertEqual(
            link.spoken, [VoiceSpokenRecord(kind: .answer, text: "Once upon a time there was a fox. It ran")])
        pipeline.answerDelta("More text that must stay silent.")
        XCTAssertEqual(audio.spoken.count, 2)
        pipeline.stop()
    }

    func testUnalignedInterruptionRecordsCompletedSentencesWithoutGuessingAPrefix() throws {
        let pipeline = try makePipeline()
        speak(pipeline, "read it")
        pipeline.handleRecognizer(.final("Read it."))
        pipeline.answerDelta("The first sentence finished. The second sentence was interrupted. Never spoken.")
        pipeline.handleSpeech(.finished(index: 0))
        audio.progress = VoiceSpeechProgress(index: 1, characters: 0)
        pipeline.handleVoiceActivity(true)
        clock.advance(0.1)
        pipeline.handleRecognizer(.partial("wait"))
        clock.advance(0.2)
        pipeline.tick()
        XCTAssertEqual(audio.stopSpeakingCount, 1)
        XCTAssertEqual(link.cancelledTurns, 1)
        XCTAssertEqual(link.spoken, [VoiceSpokenRecord(kind: .answer, text: "The first sentence finished.")])
        pipeline.stop()
    }

    func testCoughDoesNotStopSpeech() throws {
        let pipeline = try makePipeline()
        speak(pipeline, "read it")
        pipeline.handleRecognizer(.final("Read it."))
        pipeline.answerDelta("A sentence. Another sentence.")
        pipeline.handleVoiceActivity(true)
        clock.advance(0.1)
        pipeline.handleVoiceActivity(false)
        XCTAssertEqual(audio.stopSpeakingCount, 0)
        XCTAssertEqual(audio.volumes, [0.15, 1])
        XCTAssertEqual(link.cancelledTurns, 0)
        pipeline.stop()
    }

    func testAssistantEchoDoesNotBecomeAUserTurn() throws {
        let pipeline = try makePipeline()
        speak(pipeline, "read it")
        pipeline.handleRecognizer(.final("Read it."))
        pipeline.answerDelta("A sentence. Another sentence.")
        pipeline.handleRecognizer(.partial("a sentence"))
        clock.advance(2)
        pipeline.tick()
        XCTAssertEqual(link.turns.count, 1)
        pipeline.stop()
    }

    func testAcknowledgementIsSpokenWhenNoAnswerHasArrived() async throws {
        let pipeline = try makePipeline(model: FakeOnDeviceModel(mode: .respond(.text("Sure."))))
        speak(pipeline, "what time is it")
        pipeline.handleRecognizer(.final("What time is it?"))
        let reached1 = await waitUntil { !audio.spoken.isEmpty }
        XCTAssertTrue(reached1)
        XCTAssertEqual(audio.spoken.first?.index, -1)
        XCTAssertEqual(audio.spoken.first?.text, "Sure.")
        pipeline.handleSpeech(.finished(index: -1))
        XCTAssertEqual(link.spoken, [VoiceSpokenRecord(kind: .acknowledgement, text: "Sure.")])
        pipeline.stop()
    }

    func testAcknowledgementIsSkippedWhenTheAnswerIsAlreadyArriving() async throws {
        let model = FakeOnDeviceModel(mode: .respond(.text("Sure.")))
        let pipeline = try makePipeline(model: model)
        speak(pipeline, "what time is it")
        pipeline.handleRecognizer(.final("What time is it?"))
        pipeline.answerDelta("It is noon. ")
        let reached2 = await waitUntil { model.requests.count >= 1 }
        XCTAssertTrue(reached2)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(audio.spoken.map(\.text), ["It is noon."])
        pipeline.stop()
    }

    func testAnswerWaitsForAnAcknowledgementThatIsStillPlaying() async throws {
        let pipeline = try makePipeline(model: FakeOnDeviceModel(mode: .respond(.text("Sure."))))
        speak(pipeline, "what time is it")
        pipeline.handleRecognizer(.final("What time is it?"))
        let reached3 = await waitUntil { !audio.spoken.isEmpty }
        XCTAssertTrue(reached3)
        pipeline.answerDelta("It is noon. ")
        XCTAssertEqual(audio.spoken.count, 1)
        pipeline.handleSpeech(.finished(index: -1))
        XCTAssertEqual(audio.spoken.map(\.text), ["Sure.", "It is noon."])
        pipeline.stop()
    }

    func testSpeakingOverAnAcknowledgementStopsIt() async throws {
        let pipeline = try makePipeline(model: FakeOnDeviceModel(mode: .respond(.text("Sure."))))
        speak(pipeline, "what time is it")
        pipeline.handleRecognizer(.final("What time is it?"))
        let reached4 = await waitUntil { !audio.spoken.isEmpty }
        XCTAssertTrue(reached4)
        pipeline.handleVoiceActivity(true)
        XCTAssertEqual(audio.stopSpeakingCount, 1)
        pipeline.handleSpeech(.finished(index: -1))
        XCTAssertTrue(link.spoken.isEmpty)
        pipeline.stop()
    }

    func testPushToTalkCapturesOnlyWhileHeldAndEndsOnRelease() throws {
        let pipeline = try makePipeline(trigger: .pushToTalk, mode: .pushToTalk)
        XCTAssertEqual(transcriber.begun, 0)
        pipeline.beginPushToTalk()
        XCTAssertEqual(transcriber.begun, 1)
        pipeline.handleRecognizer(.partial("open my notes"))
        clock.advance(5)
        pipeline.tick()
        XCTAssertTrue(link.turns.isEmpty)
        pipeline.endPushToTalk()
        XCTAssertEqual(transcriber.ended, 1)
        pipeline.handleRecognizer(.final("Open my notes."))
        XCTAssertEqual(link.turns.first?.integrity, .owner)
        pipeline.stop()
    }

    func testRecognizerFailureIsReported() throws {
        let pipeline = try makePipeline()
        var reasons: [String] = []
        pipeline.onFailure = { reasons.append($0) }
        pipeline.handleRecognizer(.failed("local_recognition_failed"))
        XCTAssertEqual(reasons, ["local_recognition_failed"])
        pipeline.stop()
    }

    func testSynthesisFailureIsReportedWithoutClaimingSpeechWasHeard() throws {
        let pipeline = try makePipeline()
        var reasons: [String] = []
        pipeline.onFailure = { reasons.append($0) }
        pipeline.handleVoiceActivity(true)
        pipeline.handleRecognizer(.final("What time is it?"))
        pipeline.answerDelta("The clock is unavailable.")
        pipeline.handleSpeech(.failed(index: 0))
        XCTAssertEqual(reasons, ["voice_synthesis_failed"])
        XCTAssertTrue(link.spoken.isEmpty)
        pipeline.stop()
    }

    func testStoppedPipelineIgnoresLateEvents() throws {
        let pipeline = try makePipeline()
        pipeline.stop()
        pipeline.handleRecognizer(.final("late"))
        pipeline.handleVoiceActivity(true)
        pipeline.answerDelta("late. ")
        XCTAssertTrue(link.turns.isEmpty)
        XCTAssertTrue(audio.spoken.isEmpty)
    }
}

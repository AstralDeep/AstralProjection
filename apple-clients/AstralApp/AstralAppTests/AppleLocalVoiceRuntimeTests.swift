// Deterministic unit tests for AppleLocalVoiceRuntime: the client_local/v1 ready handshake,
// recognition turn lifecycle, canonical final retry and duplicate rejection, announcement
// expiry/sequence/mute fencing, playout telemetry, echo suppression, and stale-callback fencing,
// using a fake local speech engine and a manual scheduler that mirror the shipped Windows
// controller's local-speech coverage for the Apple app.

import AstralCore
import Foundation
import XCTest

@testable import AstralDeep

@MainActor
final class AppleLocalVoiceRuntimeTests: XCTestCase {
    private let device = "00000000-0000-4000-8000-00000000000a"
    private let connection = "00000000-0000-4000-8000-00000000000b"
    private let session = "00000000-0000-4000-8000-00000000000c"
    private let chat = "00000000-0000-4000-8000-00000000000d"
    private let turnId = "00000000-0000-4000-8000-00000000000e"
    private let submissionId = "00000000-0000-4000-8000-00000000000f"
    private let requestGeneration = "00000000-0000-4000-8000-000000000010"
    private let announcementId = "00000000-0000-4000-8000-000000000011"

    private var engine: FakeLocalSpeechEngine!
    private var sentTexts: [String] = []
    private var feedbacks: [(phase: String, reason: String, message: String?)] = []
    private var transcripts: [String] = []
    private var failClosedCount = 0
    private var scheduled: [(milliseconds: UInt64, work: @MainActor () -> Void)] = []
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var uuidCounter = 0
    private var runtime: AppleLocalVoiceRuntime!

    func reset() {
        engine = FakeLocalSpeechEngine()
        sentTexts = []
        feedbacks = []
        transcripts = []
        failClosedCount = 0
        scheduled = []
        clock = Date(timeIntervalSince1970: 1_000_000)
        uuidCounter = 0
        runtime = AppleLocalVoiceRuntime(
            engine: engine,
            wiring: AppleLocalVoiceRuntime.Wiring(
                send: { [weak self] text in
                    self?.sentTexts.append(text) ?? false
                    return self?.sendAllowed ?? false
                },
                feedback: { [weak self] phase, reason, message in
                    self?.feedbacks.append((phase, reason, message))
                },
                failClosed: { [weak self] in self?.failClosedCount += 1 },
                bindingFresh: { [weak self] in self?.bindingFresh ?? false },
                uuid: { [weak self] in self?.nextUUID() ?? "" },
                now: { [weak self] in self?.clock ?? Date() },
                transcript: { [weak self] text in self?.transcripts.append(text) },
                schedule: { [weak self] milliseconds, work in
                    self?.scheduled.append((milliseconds, work))
                }))
    }

    private var sendAllowed = true
    private var bindingFresh = true

    private func nextUUID() -> String {
        uuidCounter += 1
        return String(
            format: "00000000-0000-4000-8000-%012d", uuidCounter)
    }

    private func advanceClock(seconds: Double) {
        clock = clock.addingTimeInterval(seconds)
    }

    private func runScheduled(milliseconds: UInt64) {
        let matching = scheduled.filter { $0.milliseconds == milliseconds }
        scheduled.removeAll { $0.milliseconds == milliseconds }
        for entry in matching { entry.work() }
    }

    private func drain() async {
        for _ in 0..<25 { await Task.yield() }
    }

    private func activateRuntime(
        microphoneEnabled: Bool = true, speechMuted: Bool = false
    ) {
        runtime.activate(
            fence: AppleLocalVoiceFence(
                deviceId: device, connectionGeneration: connection, sessionId: session,
                generation: 1, speechRevision: 2),
            chatId: chat, chatContextRevision: 3, microphoneEnabled: microphoneEnabled,
            speechMuted: speechMuted, foregroundActive: true,
            capability: AppleLocalSpeechObservation(
                hasMicrophone: true, hasAudioOutput: true, microphonePermission: "authorized",
                recognitionPermission: "authorized", recognitionProcessing: "guaranteed_local",
                recognitionLocale: "ready", recognitionInstallation: "ready",
                synthesisProcessing: "guaranteed_local", synthesisLocale: "ready"
            ).clientCapability())
    }

    private func sentFrames() -> [(name: String, payload: [String: JSONValue])] {
        sentTexts.compactMap { text in
            guard let frame = InboundFrame.parse(text), let object = frame.payload.objectValue
            else { return nil }
            return (frame.name, object)
        }
    }

    private func sentFrames(named name: String) -> [[String: JSONValue]] {
        sentFrames().filter { $0.name == name }.map(\.payload)
    }

    private func lastFrame(named name: String) -> [String: JSONValue]? {
        sentFrames(named: name).last
    }

    private func commonBinding(extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "schema_version": .string("2"),
            "speech_backend": .string("client_local"),
            "device_id": .string(device),
            "connection_generation": .string(connection),
            "session_id": .string(session),
            "generation": .number(1),
            "speech_revision": .number(2),
        ]
        for (key, value) in extra { fields[key] = value }
        return fields
    }

    private func sessionReadyFrame(
        chatId: String? = nil, contextRevision: Int = 3, leaseInSeconds: Double = 30
    ) -> VoiceLocalFrame? {
        let lease = clock.addingTimeInterval(leaseInSeconds)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var fields = commonBinding(
            extra: [
                "contract": .string("client_local/v1"),
                "transport": .string("client_local"),
                "configured_locale": .string("en-US"),
                "chat_id": .string(chatId ?? self.chat),
                "chat_context_revision": .number(Double(contextRevision)),
                "applied_chat_context_revision": .number(Double(contextRevision)),
                "foreground_active": .bool(true),
                "microphone_enabled": .bool(true),
                "speech_muted": .bool(false),
                "lease_expires_at": .string(formatter.string(from: lease)),
            ])
        fields["type"] = .string("voice_local_session_ready")
        return localFrame(fields)
    }

    private func turnBoundFrame(
        clientTurnId: String, recognitionSequence: Int,
        bindingInSeconds: Double = 60,
        deviceId: String? = nil, speechRevision: Int = 2
    ) -> VoiceLocalFrame? {
        let expiry = clock.addingTimeInterval(bindingInSeconds)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var fields = commonBinding(
            extra: [
                "client_turn_id": .string(clientTurnId),
                "turn_id": .string(turnId),
                "submission_id": .string(submissionId),
                "request_generation": .string(requestGeneration),
                "chat_id": .string(chat),
                "chat_context_revision": .number(3),
                "recognition_sequence": .number(Double(recognitionSequence)),
                "binding_expires_at": .string(formatter.string(from: expiry)),
            ])
        fields["type"] = .string("voice_local_turn_bound")
        if let deviceId { fields["device_id"] = .string(deviceId) }
        fields["speech_revision"] = .number(Double(speechRevision))
        return localFrame(fields)
    }

    private func announcementFrame(
        sequence: Int, text: String = "All done.",
        expiresIn: Double = 5, turnId: String?, kind: String = "result",
        digest: String? = nil
    ) -> VoiceLocalFrame? {
        let expiry = clock.addingTimeInterval(expiresIn)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var fields = commonBinding(
            extra: [
                "announcement_id": .string(announcementId),
                "announcement_sequence": .number(Double(sequence)),
                "turn_id": turnId.map { .string($0) } ?? .null,
                "kind": .string(kind),
                "output_policy": .string("full_recap"),
                "locale": .string("en-US"),
                "text": .string(text),
                "text_digest_sha256": .string(digest ?? Self.digest(text)),
                "expires_at": .string(formatter.string(from: expiry)),
                "foreground_required": .bool(true),
                "mute_revision": .number(1),
                "consent_revision": .number(1),
            ])
        fields["type"] = .string("voice_local_announcement")
        return localFrame(fields)
    }

    private func localFrame(_ fields: [String: JSONValue]) -> VoiceLocalFrame? {
        guard let data = try? JSONValue.object(fields).encoded(),
            let frame = InboundFrame.parse(String(decoding: data, as: UTF8.self))
        else { return nil }
        return VoiceLocalFrame(frame: frame)
    }

    private static func digest(_ value: String) -> String {
        AppleLocalVoiceRuntime.sha256Hex(value)
    }

    private func readyHandshake() async {
        activateRuntime()
        await drain()
        XCTAssertNotNil(lastFrame(named: "voice_local_ready"))
        guard let ready = sessionReadyFrame() else { return XCTFail("fixture frame") }
        XCTAssertTrue(runtime.consume(ready))
        await drain()
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertNotNil(lastFrame(named: "voice_local_recognition_started"))
    }

    func testActivateSendsExactReadyFrameWithClientCapabilityAndSequence() async {
        reset()
        activateRuntime()
        await drain()
        let ready = lastFrame(named: "voice_local_ready")
        XCTAssertNotNil(ready)
        XCTAssertEqual(ready?["contract"]?.stringValue, "client_local/v1")
        XCTAssertEqual(ready?["transport"]?.stringValue, "client_local")
        XCTAssertEqual(ready?["configured_locale"]?.stringValue, "en-US")
        XCTAssertEqual(ready?["full_duplex"]?.boolValue, false)
        XCTAssertEqual(ready?["recognition_processing"]?.stringValue, "guaranteed_local")
        XCTAssertEqual(ready?["client_sequence"]?.numberValue, 1)
        XCTAssertEqual(ready?["device_id"]?.stringValue, device)
        XCTAssertEqual(engine.startCount, 0)
    }

    func testSessionReadyGrantsRecognitionAfterStartedFrame() async {
        reset()
        await readyHandshake()
        let started = lastFrame(named: "voice_local_recognition_started")
        XCTAssertEqual(started?["chat_id"]?.stringValue, chat)
        XCTAssertEqual(started?["chat_context_revision"]?.numberValue, 3)
        XCTAssertEqual(started?["recognition_sequence"]?.numberValue, 1)
        XCTAssertEqual(started?["client_turn_id"]?.stringValue?.count, 36)
    }

    func testSessionReadyWithWrongChatOrStaleAuthorityIsRefused() async {
        reset()
        activateRuntime()
        await drain()
        guard let wrongChat = sessionReadyFrame(chatId: requestGeneration),
            let stale = sessionReadyFrame(contextRevision: 9)
        else { return XCTFail("fixture frames") }
        XCTAssertFalse(runtime.consume(wrongChat))
        XCTAssertFalse(runtime.consume(stale))
        await drain()
        XCTAssertEqual(engine.startCount, 0)
        XCTAssertTrue(sentFrames(named: "voice_local_recognition_started").isEmpty)
    }

    func testBoundFinalIsCanonicalizedDigestedAndSentOnce() async {
        reset()
        await readyHandshake()
        let started = lastFrame(named: "voice_local_recognition_started")!
        let clientTurnId = started["client_turn_id"]!.stringValue!
        guard let bound = turnBoundFrame(clientTurnId: clientTurnId, recognitionSequence: 1)
        else { return XCTFail("fixture frame") }
        XCTAssertTrue(runtime.consume(bound))
        engine.emitFinal(" caf\u{00E9} \r\n next ")
        await drain()
        let final = lastFrame(named: "voice_local_final")
        XCTAssertEqual(final?["text"]?.stringValue, "caf\u{00E9} \n next")
        XCTAssertEqual(
            final?["text_digest_sha256"]?.stringValue,
            Self.digest("caf\u{00E9} \n next"))
        XCTAssertEqual(final?["turn_id"]?.stringValue, turnId)
        XCTAssertEqual(final?["submission_id"]?.stringValue, submissionId)
        XCTAssertEqual(final?["recognized_locale"]?.stringValue, "en-US")
        engine.emitFinal("second final for the same turn")
        await drain()
        XCTAssertEqual(sentFrames(named: "voice_local_final").count, 1)
    }

    func testUnboundFinalIsRetainedUntilTurnBoundArrives() async {
        reset()
        await readyHandshake()
        let started = lastFrame(named: "voice_local_recognition_started")!
        let clientTurnId = started["client_turn_id"]!.stringValue!
        engine.emitFinal("held text")
        await drain()
        XCTAssertTrue(sentFrames(named: "voice_local_final").isEmpty)
        guard let bound = turnBoundFrame(clientTurnId: clientTurnId, recognitionSequence: 1)
        else { return XCTFail("fixture frame") }
        XCTAssertTrue(runtime.consume(bound))
        await drain()
        XCTAssertEqual(lastFrame(named: "voice_local_final")?["text"]?.stringValue, "held text")
    }

    func testFinalWithControlCharactersIsReportedMalformed() async {
        reset()
        await readyHandshake()
        let started = lastFrame(named: "voice_local_recognition_started")!
        let clientTurnId = started["client_turn_id"]!.stringValue!
        guard let bound = turnBoundFrame(clientTurnId: clientTurnId, recognitionSequence: 1)
        else { return XCTFail("fixture frame") }
        XCTAssertTrue(runtime.consume(bound))
        engine.emitFinal("bad\u{0000}text")
        await drain()
        let failure = lastFrame(named: "voice_local_recognition_failed")
        XCTAssertEqual(failure?["reason"]?.stringValue, "local_final_malformed")
        XCTAssertEqual(failure?["turn_id"]?.stringValue, turnId)
    }

    func testExactFinalRetriesUntilAcknowledgementThenStops() async {
        reset()
        await readyHandshake()
        let started = lastFrame(named: "voice_local_recognition_started")!
        let clientTurnId = started["client_turn_id"]!.stringValue!
        guard let bound = turnBoundFrame(clientTurnId: clientTurnId, recognitionSequence: 1)
        else { return XCTFail("fixture frame") }
        XCTAssertTrue(runtime.consume(bound))
        engine.emitFinal("review the result")
        await drain()
        XCTAssertEqual(sentFrames(named: "voice_local_final").count, 1)
        XCTAssertEqual(transcripts.last, "review the result")
        advanceClock(seconds: 3)
        runScheduled(milliseconds: AppleLocalVoiceRuntime.finalRetryMilliseconds)
        await drain()
        XCTAssertEqual(sentFrames(named: "voice_local_final").count, 2)
        let frames = sentFrames(named: "voice_local_final")
        XCTAssertEqual(frames[0]["text"], frames[1]["text"])
        let ack = VoiceMessageAcknowledgement(
            frame: InboundFrame(
                name: "user_message_acked",
                payload: .object([
                    "type": .string("user_message_acked"),
                    "schema_version": .string("1"),
                    "chat_id": .string(chat),
                    "message_id": .number(7),
                    "submission_id": .string(submissionId),
                    "request_generation": .string(requestGeneration),
                    "connection_generation": .string(connection),
                    "voice_turn_id": .string(turnId),
                ])))
        XCTAssertNotNil(ack)
        XCTAssertTrue(runtime.consumeAcknowledgement(ack!))
        await drain()
        advanceClock(seconds: 3)
        runScheduled(milliseconds: AppleLocalVoiceRuntime.finalRetryMilliseconds)
        await drain()
        XCTAssertEqual(sentFrames(named: "voice_local_final").count, 2)
        XCTAssertEqual(
            sentFrames(named: "voice_local_recognition_started").count, 2)
    }

    func testAcknowledgementTimeoutFailsClosedAndScrubsPlaintext() async {
        reset()
        await readyHandshake()
        let started = lastFrame(named: "voice_local_recognition_started")!
        let clientTurnId = started["client_turn_id"]!.stringValue!
        guard let bound = turnBoundFrame(
            clientTurnId: clientTurnId, recognitionSequence: 1,
            bindingInSeconds: 5)
        else { return XCTFail("fixture frame") }
        XCTAssertTrue(runtime.consume(bound))
        engine.emitFinal("secret spoken text")
        await drain()
        XCTAssertEqual(failClosedCount, 0)
        advanceClock(seconds: 130)
        let retryEntries = scheduled.filter {
            $0.milliseconds == AppleLocalVoiceRuntime.finalRetryMilliseconds
        }
        XCTAssertFalse(retryEntries.isEmpty)
        for entry in retryEntries { entry.work() }
        await drain()
        XCTAssertEqual(failClosedCount, 1)
        XCTAssertEqual(feedbacks.last?.phase, "unavailable")
        XCTAssertEqual(transcripts.last, "")
        runScheduled(milliseconds: AppleLocalVoiceRuntime.finalRetryMilliseconds)
        await drain()
        XCTAssertEqual(sentFrames(named: "voice_local_final").count, 1)
    }

    func testStaleFinalRejectionForOlderTurnDoesNotCancelNewRecognition() async {
        reset()
        await readyHandshake()
        let firstTurn = sentFrames(named: "voice_local_recognition_started")[0]
        let firstClientTurnId = firstTurn["client_turn_id"]!.stringValue!
        guard let bound = turnBoundFrame(clientTurnId: firstClientTurnId, recognitionSequence: 1)
        else { return XCTFail("fixture frame") }
        XCTAssertTrue(runtime.consume(bound))
        engine.emitFinal("first utterance")
        await drain()
        let ack = VoiceMessageAcknowledgement(
            frame: InboundFrame(
                name: "user_message_acked",
                payload: .object([
                    "type": .string("user_message_acked"),
                    "schema_version": .string("1"),
                    "chat_id": .string(chat),
                    "message_id": .number(7),
                    "submission_id": .string(submissionId),
                    "request_generation": .string(requestGeneration),
                    "connection_generation": .string(connection),
                    "voice_turn_id": .string(turnId),
                ])))
        XCTAssertNotNil(ack)
        XCTAssertTrue(runtime.consumeAcknowledgement(ack!))
        await drain()
        XCTAssertEqual(
            sentFrames(named: "voice_local_recognition_started").count, 2)
        var rejected = commonBinding(
            extra: [
                "client_turn_id": .string(firstClientTurnId),
                "turn_id": .string(turnId),
                "submission_id": .string(submissionId),
                "request_generation": .string(requestGeneration),
                "chat_id": .string(chat),
                "chat_context_revision": .number(3),
                "recognition_sequence": .number(1),
                "reason": .string("duplicate_local_final"),
                "retry_policy": .string("none"),
                "occurred_at": .string("2099-07-31T12:00:00Z"),
            ])
        rejected["type"] = .string("voice_local_final_rejected")
        guard let staleRejection = localFrame(rejected) else { return XCTFail("fixture frame") }
        XCTAssertFalse(runtime.consume(staleRejection))
        await drain()
        XCTAssertEqual(
            sentFrames(named: "voice_local_recognition_started").count, 2)
    }

    func testMatchingFinalRejectionRestartsRecognition() async {
        reset()
        await readyHandshake()
        let started = lastFrame(named: "voice_local_recognition_started")!
        let clientTurnId = started["client_turn_id"]!.stringValue!
        guard let bound = turnBoundFrame(clientTurnId: clientTurnId, recognitionSequence: 1)
        else { return XCTFail("fixture frame") }
        XCTAssertTrue(runtime.consume(bound))
        engine.emitFinal("altered attempt")
        await drain()
        var rejected = commonBinding(
            extra: [
                "client_turn_id": .string(clientTurnId),
                "turn_id": .string(turnId),
                "submission_id": .string(submissionId),
                "request_generation": .string(requestGeneration),
                "chat_id": .string(chat),
                "chat_context_revision": .number(3),
                "recognition_sequence": .number(1),
                "reason": .string("altered_local_final"),
                "retry_policy": .string("none"),
                "occurred_at": .string("2099-07-31T12:00:00Z"),
            ])
        rejected["type"] = .string("voice_local_final_rejected")
        guard let rejectedFrame = localFrame(rejected) else { return XCTFail("fixture frame") }
        XCTAssertTrue(runtime.consume(rejectedFrame))
        await drain()
        XCTAssertEqual(feedbacks.last?.reason, "altered_local_final")
        XCTAssertEqual(
            sentFrames(named: "voice_local_recognition_started").count, 2)
    }

    func testEngineErrorBeforeBindingIsRetainedAndReportedAfterBinding() async {
        reset()
        await readyHandshake()
        engine.emitError("local_engine_lost")
        await drain()
        XCTAssertTrue(sentFrames(named: "voice_local_recognition_failed").isEmpty)
        XCTAssertEqual(feedbacks.last?.reason, "local_engine_lost")
        let started = lastFrame(named: "voice_local_recognition_started")!
        let clientTurnId = started["client_turn_id"]!.stringValue!
        let failureSequence = started["recognition_sequence"]!.numberValue
        guard let bound = turnBoundFrame(clientTurnId: clientTurnId, recognitionSequence: 1)
        else { return XCTFail("fixture frame") }
        XCTAssertTrue(runtime.consume(bound))
        await drain()
        let failure = lastFrame(named: "voice_local_recognition_failed")
        XCTAssertEqual(failure?["reason"]?.stringValue, "local_engine_lost")
        XCTAssertEqual(failure?["recognition_sequence"]?.numberValue, failureSequence)
    }

    func testUnknownEngineErrorReasonIsCanonicalized() async {
        reset()
        await readyHandshake()
        let started = lastFrame(named: "voice_local_recognition_started")!
        let clientTurnId = started["client_turn_id"]!.stringValue!
        guard let bound = turnBoundFrame(clientTurnId: clientTurnId, recognitionSequence: 1)
        else { return XCTFail("fixture frame") }
        XCTAssertTrue(runtime.consume(bound))
        engine.emitError("something unexpected")
        await drain()
        XCTAssertEqual(
            lastFrame(named: "voice_local_recognition_failed")?["reason"]?.stringValue,
            "local_recognition_failed")
    }

    func testEngineStartFailureReportsUnavailableAndClearsReadiness() async {
        reset()
        activateRuntime()
        await drain()
        engine.startRecognitionResult = false
        guard let ready = sessionReadyFrame() else { return XCTFail("fixture frame") }
        XCTAssertTrue(runtime.consume(ready))
        await drain()
        XCTAssertEqual(feedbacks.last?.reason, "local_recognition_unavailable")
        XCTAssertTrue(runtime.isActive)
        runtime.reconcile()
        await drain()
        let readyFrames = sentFrames(named: "voice_local_ready")
        XCTAssertEqual(readyFrames.count, 2)
    }

    func testStaleEpochCallbacksAreFenced() async {
        reset()
        await readyHandshake()
        engine.emitError("local_recognition_cancelled")
        await drain()
        engine.emitFinal("late final from the dead epoch")
        await drain()
        XCTAssertTrue(sentFrames(named: "voice_local_final").isEmpty)
    }

    func testTurnBindingExpiryRecoversWithNewRecognitionCycle() async {
        reset()
        await readyHandshake()
        advanceClock(seconds: 130)
        runScheduled(milliseconds: AppleLocalVoiceRuntime.bindingTimeoutMilliseconds)
        await drain()
        XCTAssertEqual(
            sentFrames(named: "voice_local_recognition_started").count, 2)
        let cycles = sentFrames(named: "voice_local_recognition_started")
        XCTAssertNotEqual(
            cycles[0]["client_turn_id"]?.stringValue,
            cycles[1]["client_turn_id"]?.stringValue)
    }

    func testAnnouncementPlaysWithStartedAndFinishedEventsAndEchoSuppression() async {
        reset()
        await readyHandshake()
        let started = lastFrame(named: "voice_local_recognition_started")!
        let clientTurnId = started["client_turn_id"]!.stringValue!
        guard let bound = turnBoundFrame(clientTurnId: clientTurnId, recognitionSequence: 1)
        else { return XCTFail("fixture frame") }
        XCTAssertTrue(runtime.consume(bound))
        guard let announcement = announcementFrame(sequence: 1, turnId: turnId)
        else { return XCTFail("fixture frame") }
        XCTAssertTrue(runtime.consume(announcement))
        await drain()
        XCTAssertEqual(engine.speakCount, 1)
        XCTAssertEqual(engine.lastSpokenText, "All done.")
        engine.emitPhase("started")
        await drain()
        XCTAssertEqual(lastFrame(named: "voice_local_playout_event")?["phase"]?.stringValue, "started")
        engine.emitPhase("finished")
        await drain()
        XCTAssertEqual(
            lastFrame(named: "voice_local_playout_event")?["phase"]?.stringValue, "finished")
        let suppression = scheduled.filter {
            $0.milliseconds == AppleLocalVoiceRuntime.echoSuppressionMilliseconds
        }
        XCTAssertEqual(suppression.count, 1)
        XCTAssertNil(lastFrame(named: "voice_local_recognition_started"))
        suppression.first?.work()
        await drain()
        XCTAssertEqual(
            sentFrames(named: "voice_local_recognition_started").count, 2)
    }

    func testAnnouncementRejectsWrongSequenceDigestExpiryAndMutedState() async {
        reset()
        await readyHandshake()
        guard let stale = announcementFrame(sequence: 2, turnId: turnId),
            let badDigest = announcementFrame(
                sequence: 1, turnId: turnId, digest: Self.digest("other text")),
            let expired = announcementFrame(sequence: 1, turnId: turnId, expiresIn: -1)
        else { return XCTFail("fixture frames") }
        XCTAssertFalse(runtime.consume(stale))
        XCTAssertFalse(runtime.consume(badDigest))
        XCTAssertFalse(runtime.consume(expired))
        await drain()
        XCTAssertEqual(engine.speakCount, 0)
        let first = announcementFrame(sequence: 1, turnId: turnId)
        XCTAssertNotNil(first)
        XCTAssertTrue(runtime.consume(first!))
        let second = announcementFrame(sequence: 2, turnId: turnId)
        XCTAssertNotNil(second)
        XCTAssertTrue(runtime.consume(second!))
        await drain()
        XCTAssertEqual(engine.speakCount, 1)
        engine.emitPhase("finished")
        await drain()
        XCTAssertEqual(engine.speakCount, 2)
    }

    func testAnnouncementExpiringDuringPlayoutFailsWithExpiredReason() async {
        reset()
        await readyHandshake()
        guard let announcement = announcementFrame(sequence: 1, turnId: turnId, expiresIn: 5)
        else { return XCTFail("fixture frame") }
        XCTAssertTrue(runtime.consume(announcement))
        await drain()
        engine.emitPhase("started")
        await drain()
        advanceClock(seconds: 10)
        let expiryEntries = scheduled.filter { $0.milliseconds == 5_000 }
        XCTAssertFalse(expiryEntries.isEmpty)
        for entry in expiryEntries { entry.work() }
        await drain()
        let event = lastFrame(named: "voice_local_playout_event")
        XCTAssertEqual(event?["phase"]?.stringValue, "failed")
        XCTAssertEqual(event?["reason"]?.stringValue, "local_announcement_expired")
    }

    func testMutedRuntimeSuppressesAnnouncementsAndStopsOwners() async {
        reset()
        await readyHandshake()
        runtime.applyControlChange(speechMuted: true)
        await drain()
        XCTAssertGreaterThanOrEqual(engine.stopAllCount, 1)
        guard let announcement = announcementFrame(sequence: 1, turnId: turnId)
        else { return XCTFail("fixture frame") }
        XCTAssertFalse(runtime.consume(announcement))
        runtime.applyControlChange(speechMuted: false)
        await drain()
        let readyFrames = sentFrames(named: "voice_local_ready")
        XCTAssertGreaterThanOrEqual(readyFrames.count, 2)
    }

    func testStopOwnersReportsInterruptedPlayoutAndBoundRecognitionFailure() async {
        reset()
        await readyHandshake()
        let started = lastFrame(named: "voice_local_recognition_started")!
        let clientTurnId = started["client_turn_id"]!.stringValue!
        guard let bound = turnBoundFrame(clientTurnId: clientTurnId, recognitionSequence: 1)
        else { return XCTFail("fixture frame") }
        XCTAssertTrue(runtime.consume(bound))
        guard let announcement = announcementFrame(sequence: 1, turnId: turnId)
        else { return XCTFail("fixture frame") }
        XCTAssertTrue(runtime.consume(announcement))
        await drain()
        engine.emitPhase("started")
        await drain()
        runtime.stopOwners("local_audio_interrupted")
        await drain()
        let events = sentFrames(named: "voice_local_playout_event")
        XCTAssertEqual(events.last?["phase"]?.stringValue, "interrupted")
        XCTAssertEqual(events.last?["reason"]?.stringValue, "local_audio_interrupted")
        let failures = sentFrames(named: "voice_local_recognition_failed")
        XCTAssertEqual(failures.last?["reason"]?.stringValue, "local_audio_interrupted")
        XCTAssertGreaterThanOrEqual(engine.stopAllCount, 1)
    }

    func testCloseIsIdempotentAndReportsTerminalPlayoutOnce() async {
        reset()
        await readyHandshake()
        guard let announcement = announcementFrame(sequence: 1, turnId: turnId)
        else { return XCTFail("fixture frame") }
        XCTAssertTrue(runtime.consume(announcement))
        await drain()
        engine.emitPhase("started")
        await drain()
        runtime.close()
        runtime.close()
        XCTAssertGreaterThanOrEqual(engine.stopAllCount, 1)
        let events = sentFrames(named: "voice_local_playout_event")
        XCTAssertEqual(events.last?["phase"]?.stringValue, "interrupted")
        XCTAssertFalse(runtime.consume(announcement))
    }

    func testSuspendStopsRecognitionAndBlocksRehandshakeWhileSuspended() async {
        reset()
        await readyHandshake()
        runtime.suspend(reason: "backgrounded")
        await drain()
        XCTAssertEqual(engine.stopAllCount, 1)
        guard let announcement = announcementFrame(sequence: 1, turnId: turnId)
        else { return XCTFail("fixture frame") }
        XCTAssertFalse(runtime.consume(announcement))
        runtime.reconcile()
        await drain()
        XCTAssertEqual(sentFrames(named: "voice_local_ready").count, 1)
        runtime.applySessionState(
            chatId: chat, chatContextRevision: 3, foregroundActive: true,
            microphoneEnabled: true, speechMuted: false, chatContextSynced: true)
        await drain()
        XCTAssertEqual(sentFrames(named: "voice_local_ready").count, 2)
    }

    func testPendingFailureLedgerIsBoundedAndEvictsTheOldest() async {
        reset()
        await readyHandshake()
        for _ in 0..<5 {
            engine.emitError("local_recognition_cancelled")
            await drain()
            runtime.reconcile()
            await drain()
            guard let ready = sessionReadyFrame() else { return XCTFail("fixture frame") }
            XCTAssertTrue(runtime.consume(ready))
            await drain()
        }
        engine.emitError("local_recognition_cancelled")
        await drain()
        let cycles = sentFrames(named: "voice_local_recognition_started")
        XCTAssertEqual(cycles.count, 6)
        let evicted = cycles[0]
        var evictedBound = commonBinding(
            extra: [
                "client_turn_id": .string(evicted["client_turn_id"]!.stringValue!),
                "turn_id": .string(turnId),
                "submission_id": .string(submissionId),
                "request_generation": .string(requestGeneration),
                "chat_id": .string(chat),
                "chat_context_revision": .number(3),
                "recognition_sequence": evicted["recognition_sequence"]!,
                "binding_expires_at": .string(
                    AppleLocalVoiceRuntime.wireTimestamp(clock.addingTimeInterval(60))),
            ])
        evictedBound["type"] = .string("voice_local_turn_bound")
        guard let evictedFrame = localFrame(evictedBound) else { return XCTFail("fixture frame") }
        XCTAssertFalse(runtime.consume(evictedFrame))
        XCTAssertTrue(sentFrames(named: "voice_local_recognition_failed").isEmpty)
        let retained = cycles[2]
        var retainedBound = commonBinding(
            extra: [
                "client_turn_id": .string(retained["client_turn_id"]!.stringValue!),
                "turn_id": .string(turnId),
                "submission_id": .string(submissionId),
                "request_generation": .string(requestGeneration),
                "chat_id": .string(chat),
                "chat_context_revision": .number(3),
                "recognition_sequence": retained["recognition_sequence"]!,
                "binding_expires_at": .string(
                    AppleLocalVoiceRuntime.wireTimestamp(clock.addingTimeInterval(60))),
            ])
        retainedBound["type"] = .string("voice_local_turn_bound")
        guard let retainedFrame = localFrame(retainedBound) else { return XCTFail("fixture frame") }
        XCTAssertTrue(runtime.consume(retainedFrame))
        XCTAssertEqual(
            lastFrame(named: "voice_local_recognition_failed")?["recognition_sequence"]?.numberValue,
            retained["recognition_sequence"]?.numberValue)
    }

    func testSpeechRevisionRotationRejectsFramesFromTheOldRevision() async {
        reset()
        await readyHandshake()
        runtime.updateSpeechRevision(3)
        let staleBound = turnBoundFrame(
            clientTurnId: "00000000-0000-4000-8000-000000000099", recognitionSequence: 1)
        XCTAssertNotNil(staleBound)
        XCTAssertFalse(runtime.consume(staleBound!))
        var rotated = commonBinding(extra: [:])
        rotated["speech_revision"] = .number(3)
        rotated["contract"] = .string("client_local/v1")
        rotated["transport"] = .string("client_local")
        rotated["configured_locale"] = .string("en-US")
        rotated["chat_id"] = .string(chat)
        rotated["chat_context_revision"] = .number(3)
        rotated["applied_chat_context_revision"] = .number(3)
        rotated["foreground_active"] = .bool(true)
        rotated["microphone_enabled"] = .bool(true)
        rotated["speech_muted"] = .bool(false)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        rotated["lease_expires_at"] = .string(
            formatter.string(from: clock.addingTimeInterval(30)))
        rotated["type"] = .string("voice_local_session_ready")
        guard let frame = localFrame(rotated) else { return XCTFail("fixture frame") }
        XCTAssertTrue(runtime.consume(frame))
    }
}

@MainActor
final class FakeLocalSpeechEngine: AppleLocalSpeechEngine {
    var observationValue = AppleLocalSpeechObservation(
        hasMicrophone: true, hasAudioOutput: true, microphonePermission: "authorized",
        recognitionPermission: "authorized", recognitionProcessing: "guaranteed_local",
        recognitionLocale: "ready", recognitionInstallation: "ready",
        synthesisProcessing: "guaranteed_local", synthesisLocale: "ready")
    var startRecognitionResult = true
    var speakResult = true
    private(set) var startCount = 0
    private(set) var stopRecognitionCount = 0
    private(set) var stopAllCount = 0
    private(set) var speakCount = 0
    private(set) var lastSpokenText: String?
    private(set) var authorizationRequests = 0
    var onFinalHandler: ((String) -> Void)?
    var onErrorHandler: ((String) -> Void)?
    var onPhaseHandler: ((String) -> Void)?

    func authorize() async -> AppleLocalSpeechObservation {
        authorizationRequests += 1
        return observationValue
    }

    func observation() async -> AppleLocalSpeechObservation { observationValue }

    func startRecognition(
        onFinal: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) async -> Bool {
        startCount += 1
        guard startRecognitionResult else { return false }
        onFinalHandler = onFinal
        onErrorHandler = onError
        return true
    }

    func stopRecognition() async {
        stopRecognitionCount += 1
        onFinalHandler = nil
        onErrorHandler = nil
    }

    func speak(_ text: String, onPhase: @escaping @MainActor (String) -> Void) async -> Bool {
        speakCount += 1
        lastSpokenText = text
        guard speakResult else { return false }
        onPhaseHandler = onPhase
        return true
    }

    func stopAll() async {
        stopAllCount += 1
        onPhaseHandler = nil
        onFinalHandler = nil
        onErrorHandler = nil
    }

    func emitFinal(_ text: String) { onFinalHandler?(text) }
    func emitError(_ reason: String) { onErrorHandler?(reason) }
    func emitPhase(_ phase: String) { onPhaseHandler?(phase) }
}

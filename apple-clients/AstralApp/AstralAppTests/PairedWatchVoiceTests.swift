// Drives the phone companion relay and real on-device adapters with bounded paired packets and a tiny installed model fixture.
// The injected principal callbacks model explicit verified admission; native principal membership is covered by MeshVoiceLinkTests.

import AstralCore
import AstralVoiceRuntime
import AstralVoiceSpeech
import Foundation
import XCTest

@testable import AstralDeep

@MainActor
final class PairedWatchVoiceTests: XCTestCase {
    override func setUp() async throws {
        HostedVoiceRequestRecorder.reset()
        URLProtocol.registerClass(HostedVoiceRequestRecorder.self)
    }
    override func tearDown() async throws {
        URLProtocol.unregisterClass(HostedVoiceRequestRecorder.self)
        HostedVoiceRequestRecorder.reset()
    }

    func testMeshKeyBindingRefusalReachesWatchWithoutInvokingVoice() async throws {
        let channel = PhoneCompanionChannel()
        let controller = OnDeviceVoiceController(
            store: nil, parts: .silent,
            requestPermission: {
                XCTFail("Unsupported binding cannot request the microphone")
                return false
            })
        let relay = PairedWatchVoiceRelay(controller: controller, channel: channel)
        relay.bind(prepare: { _ in throw MeshKernelError.meshKeyBindingUnavailable }, isCurrent: { _ in false })
        let owner = CompanionVoiceOwner(meshId: "sha256:" + String(repeating: "ab", count: 32))!
        let packet = try CompanionVoicePacket(
            kind: .start, session: UUID(), sequence: 0, microseconds: 0,
            payload: CompanionVoiceActivation(owner: owner, mode: .conversation).encoded())
        let failed = expectation(description: "unsupported mesh-key binding")
        channel.observe(.failure, failed)
        try await channel.onPacket?(packet)
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(
            channel.sent.first(where: { $0.kind == .failure })?.payload, Data("phone_mesh_binding_unavailable".utf8))
        XCTAssertFalse(controller.isRunning)
        relay.unbind()
    }

    func testWrongOwnerStartCannotInterruptAnAdmittedSession() async throws {
        let h = try await PhoneCompanionHarness.installed()
        defer { h.close() }
        try await h.start()
        await h.wait(for: .ready, in: self)
        XCTAssertTrue(h.controller.isRunning)
        let other = CompanionVoiceOwner(meshId: "sha256:" + String(repeating: "cd", count: 32))!
        let packet = try CompanionVoicePacket(
            kind: .start, session: UUID(), sequence: 0, microseconds: 0,
            payload: CompanionVoiceActivation(owner: other, mode: .conversation).encoded())
        try await h.channel.onPacket?(packet)
        await h.wait(for: .failure, in: self)
        XCTAssertEqual(h.channel.sent.last?.session, packet.session)
        XCTAssertTrue(h.controller.isRunning)
        XCTAssertFalse(h.channel.sent.contains { $0.kind == .stop })
        try await h.deliver(.capture, Data(repeating: 0, count: 3_200))
        XCTAssertTrue(h.controller.isRunning)
    }

    func testStartReplayCannotRestartAnEndedSessionOrInterruptCurrentAudio() async throws {
        let h = try await PhoneCompanionHarness.installed()
        defer { h.close() }
        try await h.start()
        await h.wait(for: .ready, in: self)
        let replay = try CompanionVoicePacket(
            kind: .start, session: h.session, sequence: 0, microseconds: 0,
            payload: CompanionVoiceActivation(owner: h.owner, mode: .conversation).encoded())
        do {
            try await h.channel.onPacket?(replay)
            XCTFail("live start replay")
        } catch {}
        XCTAssertTrue(h.controller.isRunning)
        try await h.deliver(.stop)
        XCTAssertFalse(h.controller.isRunning)
        do {
            try await h.channel.onPacket?(replay)
            XCTFail("ended start replay")
        } catch {}
        await drain()
        XCTAssertFalse(h.controller.isRunning)
        XCTAssertEqual(h.channel.sent.filter { $0.kind == .ready }.count, 1)
    }

    func testRetiredTranscriptCallbackCannotSendIntoAReplacementSession() async throws {
        let h = try await PhoneCompanionHarness.installed()
        defer { h.close() }
        try await h.start()
        await h.wait(for: .ready, in: self)
        let retired = try XCTUnwrap(h.controller.onTranscript)
        try await h.deliver(.stop)
        let ready = expectation(description: "replacement ready")
        h.channel.observe(.ready, ready, includingExisting: false)
        let next = UUID()
        let packet = try CompanionVoicePacket(
            kind: .start, session: next, sequence: 0, microseconds: 0,
            payload: CompanionVoiceActivation(owner: h.owner, mode: .conversation).encoded())
        try await h.channel.onPacket?(packet)
        await fulfillment(of: [ready], timeout: 3)
        retired("private retired transcript", true)
        h.controller.onTranscript?("current transcript", true)
        await h.wait(for: .finalTranscript, in: self)
        await drain()
        XCTAssertFalse(h.channel.sent.contains { $0.payload == Data("private retired transcript".utf8) })
        XCTAssertEqual(h.channel.sent.last(where: { $0.kind == .finalTranscript })?.session, next)
    }

    func testOwnerOrConversationRevocationBeforePacketStopsWithoutSubmitting() async throws {
        let h = try await PhoneCompanionHarness.installed()
        defer { h.close() }
        try await h.start()
        await h.wait(for: .ready, in: self)
        h.current = false
        do {
            try await h.deliver(.capture, Data(repeating: 0, count: 3_200))
            XCTFail("retired context")
        } catch {}
        XCTAssertFalse(h.controller.isRunning)
        XCTAssertTrue(h.link.turns.isEmpty)
        XCTAssertTrue(h.link.spoken.isEmpty)
    }

    func testRetiredSubmissionCannotPassAContextCheckSuspendedAcrossReplacement() async throws {
        let h = try await PhoneCompanionHarness.installed()
        defer { h.close() }
        try await h.start()
        await h.wait(for: .ready, in: self)
        let partial = expectation(description: "recognized partial")
        h.channel.observe(.partialTranscript, partial)
        try await captureSentence(h)
        await fulfillment(of: [partial], timeout: 3)
        let suspended = expectation(description: "old final and submit context checks")
        suspended.expectedFulfillmentCount = 2
        let pause = CompanionContextPause(count: 2, entered: suspended)
        h.pauseCurrent = { await pause.wait() }
        await fulfillment(of: [suspended], timeout: 4)
        _ = try await replace(h)
        pause.resume()
        await drain()
        XCTAssertTrue(h.link.turns.isEmpty)
        XCTAssertTrue(h.controller.isRunning)
    }

    func testRetiredSpokenRecordCannotPassAContextCheckSuspendedAcrossReplacement() async throws {
        let h = try await PhoneCompanionHarness.installed()
        defer { h.close() }
        try await h.start()
        await h.wait(for: .ready, in: self)
        try await captureSentence(h)
        await h.wait(for: .finalTranscript, in: self)
        await drain()
        XCTAssertEqual(h.link.turns.count, 1)
        h.controller.answerDelta("The result is six.")
        h.controller.answerFinished()
        await h.wait(for: .speechPCM, in: self)
        let speech = try XCTUnwrap(
            h.channel.sent.compactMap { packet in
                packet.kind == .speechStart ? CompanionVoiceSpeech(data: packet.payload) : nil
            }.last)
        try await h.deliver(.playbackStarted, Data(speech.id.uuidString.utf8))
        let suspended = expectation(description: "old spoken-record context check")
        let pause = CompanionContextPause(count: 1, skip: 1, entered: suspended)
        h.pauseCurrent = { await pause.wait() }
        try await h.deliver(.playbackFinished, Data(speech.id.uuidString.utf8))
        await fulfillment(of: [suspended], timeout: 3)
        _ = try await replace(h)
        pause.resume()
        await drain()
        XCTAssertTrue(h.link.spoken.isEmpty)
        XCTAssertTrue(h.controller.isRunning)
    }

    func testOldPlaybackCompletionCannotStopAReplacementPlaybackSession() async throws {
        let h = try await PhoneCompanionHarness.installed()
        defer { h.close() }
        let first = try await replace(h, mode: .playback)
        await h.wait(for: .speechPCM, in: self)
        let old = try XCTUnwrap(
            h.channel.sent.compactMap { packet in
                packet.session == first && packet.kind == .speechStart
                    ? CompanionVoiceSpeech(data: packet.payload) : nil
            }.last)
        let next = try await replace(h, mode: .playback)
        if !h.channel.sent.contains(where: { $0.session == next && $0.kind == .speechPCM }) {
            let pcm = expectation(description: "replacement speech")
            h.channel.observe(.speechPCM, pcm, includingExisting: false)
            await fulfillment(of: [pcm], timeout: 3)
        }
        let speech = try XCTUnwrap(
            h.channel.sent.compactMap { packet in
                packet.session == next && packet.kind == .speechStart ? CompanionVoiceSpeech(data: packet.payload) : nil
            }.last)
        let late = try CompanionVoicePacket(
            kind: .playbackFinished, session: first, sequence: 1, microseconds: 1,
            payload: Data(old.id.uuidString.utf8))
        do {
            try await h.channel.onPacket?(late)
            XCTFail("retired completion")
        } catch {}
        XCTAssertTrue(h.controller.isRunning)
        XCTAssertFalse(h.channel.sent.contains { $0.session == next && $0.kind == .stop })
        for (sequence, kind) in [(UInt64(1), CompanionVoicePacket.Kind.playbackStarted), (2, .playbackFinished)] {
            try await h.channel.onPacket?(
                CompanionVoicePacket(
                    kind: kind, session: next, sequence: sequence,
                    microseconds: sequence, payload: Data(speech.id.uuidString.utf8)))
        }
        XCTAssertFalse(h.controller.isRunning)
    }

    func testRetiredPacketContextFailureCannotStopAReplacementSession() async throws {
        let h = try await PhoneCompanionHarness.installed()
        defer { h.close() }
        try await h.start()
        await h.wait(for: .ready, in: self)
        let suspended = expectation(description: "old packet context check")
        let pause = CompanionContextPause(count: 1, entered: suspended)
        h.pauseCurrent = { await pause.wait() }
        let pending = Task { try await h.deliver(.capture, Data(repeating: 0, count: 3_200)) }
        await fulfillment(of: [suspended], timeout: 3)
        let next = try await replace(h)
        pause.resume()
        do {
            try await pending.value
            XCTFail("retired packet")
        } catch {}
        await drain()
        XCTAssertTrue(h.controller.isRunning)
        XCTAssertFalse(h.channel.sent.contains { $0.session == next && ($0.kind == .failure || $0.kind == .stop) })
        XCTAssertTrue(h.link.turns.isEmpty)
    }

    func testRetiredPreparationCannotStopAReplacementAfterItsContextCheckResumes() async throws {
        let h = try await PhoneCompanionHarness.installed()
        defer { h.close() }
        let suspended = expectation(description: "old preparation context check")
        let pause = CompanionContextPause(count: 1, skip: 1, entered: suspended)
        h.pauseCurrent = { await pause.wait() }
        try await h.start()
        await fulfillment(of: [suspended], timeout: 3)
        let next = try await replace(h)
        pause.resume()
        await drain()
        XCTAssertTrue(h.controller.isRunning)
        XCTAssertFalse(h.channel.sent.contains { $0.session == next && ($0.kind == .failure || $0.kind == .stop) })
        XCTAssertEqual(h.channel.sent.filter { $0.kind == .ready }.map(\.session), [next])
    }

    func testRetiredReadyReplyCannotSpeakItsTextIntoAReplacementSession() async throws {
        let h = try await PhoneCompanionHarness.installed()
        defer { h.close() }
        let suspended = expectation(description: "old ready reply")
        let pause = CompanionContextPause(count: 1, entered: suspended)
        h.channel.pauseSend = { packet in if packet.kind == .ready { await pause.wait() } }
        _ = try await replace(h, mode: .playback)
        await fulfillment(of: [suspended], timeout: 3)
        let next = try await replace(h)
        pause.resume()
        await drain()
        XCTAssertTrue(h.controller.isRunning)
        XCTAssertFalse(h.channel.sent.contains { $0.session == next && $0.kind == .speechStart })
    }

    func testMissingModelAndUnboundPrincipalRefuseTruthfullyWithoutPhoneMicrophone() async throws {
        let channel = PhoneCompanionChannel()
        let controller = OnDeviceVoiceController(
            store: nil, parts: .silent,
            requestPermission: {
                XCTFail("phone microphone")
                return false
            })
        let relay = PairedWatchVoiceRelay(controller: controller, channel: channel)
        let owner = CompanionVoiceOwner(meshId: "sha256:" + String(repeating: "ab", count: 32))!
        let context = PairedWatchVoiceContext(owner: owner, chatId: "phone-chat", title: "Phone", meshSession: UUID())
        let activation = CompanionVoiceActivation(owner: owner, mode: .conversation)
        let packet = try CompanionVoicePacket(
            kind: .start, session: UUID(), sequence: 0, microseconds: 0, payload: activation.encoded())
        do {
            try await channel.onPacket?(packet)
            XCTFail("unbound principal")
        } catch {}
        XCTAssertTrue(channel.sent.isEmpty)
        relay.bind(prepare: { _ in context }, isCurrent: { _ in true })
        try await channel.onPacket?(packet)
        let failure = expectation(description: "model required")
        channel.observe(.failure, failure)
        await fulfillment(of: [failure], timeout: 3)
        XCTAssertEqual(channel.sent.first(where: { $0.kind == .failure })?.payload, Data("phone_model_required".utf8))
        XCTAssertFalse(controller.isRunning)
        relay.unbind()
    }

    func testRealPCMTranscriptionUsesPairedOwnerInputAndCompletedPlaybackRecordsOnce() async throws {
        let h = try await PhoneCompanionHarness.installed()
        defer { h.close() }
        try await h.start()
        await h.wait(for: .ready, in: self)
        let context = try XCTUnwrap(h.channel.sent.first { $0.kind == .ready })
        XCTAssertEqual(CompanionVoiceConversation(data: context.payload)?.chatId, "phone-chat")
        let final = expectation(description: "final transcription")
        h.channel.observe(.finalTranscript, final)
        try await h.deliver(.capture, Data(repeating: 0x20, count: 3_200))
        for _ in 0..<4 { try await h.deliver(.capture, Data(repeating: 0, count: 3_200)) }
        await fulfillment(of: [final], timeout: 4)
        await drain()
        XCTAssertEqual(h.link.turns.count, 1)
        let turn = try XCTUnwrap(h.link.turns.first)
        XCTAssertEqual(turn.source, .pairedWatchMicrophone)
        XCTAssertEqual(turn.integrity, .owner)
        XCTAssertFalse(turn.approvalEligible)
        XCTAssertEqual(turn.text, "yes approve the payment")
        h.controller.answerDelta("The result is six.")
        h.controller.answerFinished()
        await h.wait(for: .speechPCM, in: self)
        let announcements = h.channel.sent.filter { $0.kind == .speechStart }
        let answer = try XCTUnwrap(announcements.compactMap { CompanionVoiceSpeech(data: $0.payload) }.last)
        XCTAssertTrue(h.link.spoken.isEmpty)
        try await h.deliver(.playbackStarted, Data(answer.id.uuidString.utf8))
        XCTAssertTrue(h.link.spoken.isEmpty)
        try await h.deliver(.playbackFinished, Data(answer.id.uuidString.utf8))
        await drain()
        XCTAssertEqual(h.link.spoken.filter { $0.kind == .answer }.map(\.text), ["The result is six."])
        try await h.deliver(.playbackFinished, Data(answer.id.uuidString.utf8))
        await drain()
        XCTAssertEqual(h.link.spoken.filter { $0.kind == .answer }.count, 1)
        XCTAssertEqual(HostedVoiceRequestRecorder.requests, [])
    }

    func testPendingActivationCancelledByExactSessionCannotReplaceCurrentConversation() async throws {
        let h = try await PhoneCompanionHarness.installed()
        defer { h.close() }
        try await h.start()
        await h.wait(for: .ready, in: self)
        var release: CheckedContinuation<Void, Never>?
        let preparing = expectation(description: "candidate preparing")
        h.relay.bind(
            prepare: { _ in
                preparing.fulfill()
                await withCheckedContinuation { release = $0 }
                return h.context
            }, isCurrent: { _ in true })
        let candidate = UUID()
        let packet = try CompanionVoicePacket(
            kind: .start, session: candidate, sequence: 0, microseconds: 0,
            payload: CompanionVoiceActivation(owner: h.owner, mode: .conversation).encoded())
        try await h.channel.onPacket?(packet)
        await fulfillment(of: [preparing], timeout: 3)
        try await h.channel.onPacket?(
            CompanionVoicePacket(kind: .stop, session: candidate, sequence: 1, microseconds: 1))
        release?.resume()
        await drain()
        XCTAssertFalse(h.controller.isRunning)
        XCTAssertTrue(h.link.turns.isEmpty)
    }

    private func captureSentence(_ h: PhoneCompanionHarness) async throws {
        try await h.deliver(.capture, Data(repeating: 0x20, count: 3_200))
        for _ in 0..<4 { try await h.deliver(.capture, Data(repeating: 0, count: 3_200)) }
    }

    private func replace(
        _ h: PhoneCompanionHarness,
        mode: CompanionVoiceActivation.Mode = .conversation
    ) async throws -> UUID {
        let ready = expectation(description: "replacement ready")
        h.channel.observe(.ready, ready, includingExisting: false)
        let session = UUID()
        let activation = CompanionVoiceActivation(
            owner: h.owner, mode: mode, text: mode == .playback ? "Replay text" : nil)
        try await h.channel.onPacket?(
            CompanionVoicePacket(
                kind: .start, session: session, sequence: 0,
                microseconds: 0, payload: activation.encoded()))
        await fulfillment(of: [ready], timeout: 3)
        return session
    }

    private func drain() async { for _ in 0..<50 { await Task.yield() } }

    func testASessionOpensAndClosesTheModelsOncePerWatchSession() async throws {
        let h = try await PhoneCompanionHarness.installed()
        defer { h.close() }
        try await h.start()
        await h.wait(for: .ready, in: self)
        XCTAssertEqual(h.fixture.recorder.events, ["begin"])
        h.relay.unbind()
        for _ in 0..<200 where h.fixture.recorder.events != ["begin", "end"] { await Task.yield() }
        XCTAssertEqual(h.fixture.recorder.events, ["begin", "end"])
    }

    func testSpeechAtAnotherSampleRateIsResampledToTwentyFourKilohertzBeforePacking() async throws {
        for (rate, count) in [(48_000, 4_800), (22_050, 2_205), (24_000, 2_400)] {
            let packed = PackedSpeech()
            let audio = PairedWatchVoiceAudio(voice: RateSpeech(rate: rate, count: count)) { kind, payload in
                packed.record(kind, payload)
            }
            try audio.start()
            audio.speak(index: 0, text: "Hello there.")
            for _ in 0..<2_000 where packed.frames == nil { try await Task.sleep(for: .milliseconds(5)) }
            let frames = try XCTUnwrap(packed.frames, "rate \(rate)")
            XCTAssertTrue((2_380...2_420).contains(frames), "rate \(rate) gave \(frames) frames")
            for _ in 0..<2_000 where packed.pcmBytes < frames * 2 { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(packed.pcmBytes, frames * 2)
            audio.stop()
        }
    }
}

private final class PackedSpeech: @unchecked Sendable {
    private let lock = NSLock()
    private var announced: Int?
    private var bytes = 0
    var frames: Int? { lock.withLock { announced } }
    var pcmBytes: Int { lock.withLock { bytes } }
    func record(_ kind: CompanionVoicePacket.Kind, _ payload: Data) {
        lock.withLock {
            if kind == .speechStart { announced = CompanionVoiceSpeech(data: payload)?.frames }
            if kind == .speechPCM { bytes += payload.count }
        }
    }
}

private struct RateSpeech: VoiceSpeaking {
    let rate: Int
    let count: Int
    func speak(_ sentence: String) async throws -> AsyncThrowingStream<SpeechAudioBuffer, Error> {
        let rate = rate
        let count = count
        return AsyncThrowingStream { continuation in
            let half = count / 2
            for range in [0..<half, half..<count] {
                let samples = range.map { 0.3 * sin(Float($0) * 2 * .pi * 220 / Float(rate)) }
                continuation.yield(SpeechAudioBuffer(samples: samples, sampleRate: rate))
            }
            continuation.finish()
        }
    }
}

@MainActor
private final class PhoneCompanionHarness {
    let fixture: VoicePackTestFixture
    let controller: OnDeviceVoiceController
    let link = FakeKernelLink()
    let channel = PhoneCompanionChannel()
    let owner = CompanionVoiceOwner(meshId: "sha256:" + String(repeating: "ab", count: 32))!
    let session = UUID()
    var current = true
    var pauseCurrent: (@MainActor () async -> Void)?
    var relay: PairedWatchVoiceRelay!
    var context: PairedWatchVoiceContext {
        .init(owner: owner, chatId: "phone-chat", title: "Phone conversation", meshSession: session)
    }
    private var sequence: UInt64 = 0

    private init(fixture: VoicePackTestFixture) {
        self.fixture = fixture
        controller = OnDeviceVoiceController(
            store: fixture.store,
            parts: .recording(
                fixture.recorder, recognizer: CompanionInference(), textGenerator: CompanionInference(),
                speech: CompanionInference()),
            requestPermission: {
                XCTFail("paired voice requested the phone microphone")
                return false
            })
        controller.connect(link: link)
        relay = PairedWatchVoiceRelay(controller: controller, channel: channel)
        relay.bind(
            prepare: { [weak self] owner in
                guard let self, owner == self.owner, self.current else { throw CompanionVoiceError.rejected }
                return self.context
            },
            isCurrent: { [weak self] context in
                guard let self, self.current, context == self.context else { return false }
                await self.pauseCurrent?()
                return self.current && context == self.context
            })
    }
    static func installed() async throws -> PhoneCompanionHarness {
        try await PhoneCompanionHarness(fixture: VoicePackTestFixture.make(installed: true))
    }
    func start() async throws {
        try await deliver(.start, CompanionVoiceActivation(owner: owner, mode: .conversation).encoded())
    }
    func deliver(_ kind: CompanionVoicePacket.Kind, _ payload: Data = Data()) async throws {
        let packet = try CompanionVoicePacket(
            kind: kind, session: session, sequence: sequence, microseconds: sequence, payload: payload)
        sequence += 1
        try await channel.onPacket?(packet)
    }
    func wait(for kind: CompanionVoicePacket.Kind, in test: XCTestCase) async {
        let expectation = test.expectation(description: "paired \(kind)")
        channel.observe(kind, expectation)
        await test.fulfillment(of: [expectation], timeout: 4)
    }
    func close() {
        relay.unbind()
        try? FileManager.default.removeItem(at: fixture.root)
    }
}

@MainActor
private final class PhoneCompanionChannel: CompanionVoiceChannel {
    var reachable = true
    var onPacket: (@MainActor @Sendable (CompanionVoicePacket) async throws -> Void)?
    var onReachabilityChanged: (@MainActor @Sendable (Bool) -> Void)?
    var sent: [CompanionVoicePacket] = []
    var pauseSend: (@MainActor (CompanionVoicePacket) async -> Void)?
    private var observers: [CompanionVoicePacket.Kind: XCTestExpectation] = [:]
    func send(_ packet: CompanionVoicePacket) async throws {
        sent.append(try CompanionVoicePacket(data: packet.encoded))
        observers.removeValue(forKey: packet.kind)?.fulfill()
        await pauseSend?(packet)
    }
    func observe(_ kind: CompanionVoicePacket.Kind, _ expectation: XCTestExpectation, includingExisting: Bool = true) {
        if includingExisting, sent.contains(where: { $0.kind == kind }) {
            expectation.fulfill()
        } else {
            observers[kind] = expectation
        }
    }
}

private struct CompanionInference: VoiceRecognizing, VoiceSpeaking, VoiceTextGenerating {
    func recognize(_ audio: [Float], language: RecognitionLanguage) async throws -> String {
        "yes approve the payment"
    }
    func speak(_ sentence: String) async throws -> AsyncThrowingStream<SpeechAudioBuffer, Error> {
        return AsyncThrowingStream { continuation in
            continuation.yield(SpeechAudioBuffer(samples: [0, 0.1, -0.1, 0], sampleRate: 24_000))
            continuation.finish()
        }
    }
    func generate(_ request: OnDeviceRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private final class CompanionContextPause {
    private var remaining: Int
    private var skip: Int
    private let entered: XCTestExpectation
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(count: Int, skip: Int = 0, entered: XCTestExpectation) {
        remaining = count
        self.skip = skip
        self.entered = entered
    }
    func wait() async {
        if skip > 0 {
            skip -= 1
            return
        }
        guard remaining > 0 else { return }
        remaining -= 1
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            entered.fulfill()
        }
    }
    func resume() {
        let callbacks = waiting
        waiting = []
        for callback in callbacks { callback.resume() }
    }
}

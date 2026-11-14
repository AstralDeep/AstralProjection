// Drives the phone companion relay and real on-device adapters with bounded paired packets and a tiny installed model fixture.
// The injected principal callbacks model explicit verified admission; native principal membership is covered by MeshVoiceLinkTests.

import AstralCore
@testable import AstralDeep
import Foundation
import XCTest

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

    func testWrongOwnerStartCannotInterruptAnAdmittedSession() async throws {
        let h = try await PhoneCompanionHarness.installed()
        defer { h.close() }
        try await h.start()
        await h.wait(for: .ready, in: self)
        XCTAssertTrue(h.controller.isRunning)
        let other = CompanionVoiceOwner(issuer: h.owner.issuer, subject: "different")!
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

    func testMissingModelAndUnboundPrincipalRefuseTruthfullyWithoutPhoneMicrophone() async throws {
        let channel = PhoneCompanionChannel()
        let controller = OnDeviceVoiceController(
            store: nil,
            requestPermission: {
                XCTFail("phone microphone")
                return false
            })
        let relay = PairedWatchVoiceRelay(controller: controller, channel: channel)
        let owner = CompanionVoiceOwner(issuer: "https://issuer.example", subject: "owner")!
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

    private func drain() async { for _ in 0..<50 { await Task.yield() } }
}

@MainActor
private final class PhoneCompanionHarness {
    let fixture: VoiceModelTestFixture
    let controller: OnDeviceVoiceController
    let link = FakeKernelLink()
    let channel = PhoneCompanionChannel()
    let owner = CompanionVoiceOwner(issuer: "https://issuer.example", subject: "owner")!
    let session = UUID()
    var current = true
    var relay: PairedWatchVoiceRelay!
    var context: PairedWatchVoiceContext {
        .init(owner: owner, chatId: "phone-chat", title: "Phone conversation", meshSession: session)
    }
    private var sequence: UInt64 = 0

    private init(fixture: VoiceModelTestFixture) {
        self.fixture = fixture
        controller = OnDeviceVoiceController(
            store: fixture.controller.store,
            requestPermission: {
                XCTFail("paired voice requested the phone microphone")
                return false
            })
        controller.connect(link: link)
        relay = PairedWatchVoiceRelay(
            controller: controller, channel: channel, inference: { _ in CompanionInference() })
        relay.bind(
            prepare: { [weak self] owner in
                guard let self, owner == self.owner, self.current else { throw CompanionVoiceError.rejected }
                return self.context
            }, isCurrent: { [weak self] context in self?.current == true && context == self?.context })
    }
    static func installed() async throws -> PhoneCompanionHarness {
        try await PhoneCompanionHarness(fixture: VoiceModelTestFixture.installed())
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
    private var observers: [CompanionVoicePacket.Kind: XCTestExpectation] = [:]
    func send(_ packet: CompanionVoicePacket) async throws {
        sent.append(try CompanionVoicePacket(data: packet.encoded))
        observers.removeValue(forKey: packet.kind)?.fulfill()
    }
    func observe(_ kind: CompanionVoicePacket.Kind, _ expectation: XCTestExpectation, includingExisting: Bool = true) {
        if includingExisting, sent.contains(where: { $0.kind == kind }) {
            expectation.fulfill()
        } else {
            observers[kind] = expectation
        }
    }
}

private struct CompanionInference: VoiceModelInference {
    func transcribe(_ audio: [Float], onText: @escaping @Sendable (String) -> Void) async throws -> String {
        onText("yes approve the payment")
        return "yes approve the payment"
    }
    func synthesize(_ text: String, onAudio: @escaping @Sendable ([Float]) -> Void) async throws {
        onAudio([0, 0.1, -0.1, 0])
    }
    func acknowledgement(_ request: OnDeviceRequest) async throws -> String { "" }
}

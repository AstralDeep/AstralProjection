// Exercises paired phone packets through the real Watch bridge with scripted capture and actual-completion callbacks.
// No HTTP client or platform microphone is used by these tests.

import AstralCore
@testable import AstralWatch
import Foundation
import XCTest

@MainActor
final class WatchVoiceBridge065Tests: XCTestCase {
    private let owner = CompanionVoiceOwner(meshId: "sha256:" + String(repeating: "ab", count: 32))!

    func testReadyBindsPhoneConversationAndCaptureUsesOnlyPairedPackets() async throws {
        let h = try await harness()
        XCTAssertEqual(h.audio.prepared, [true])
        XCTAssertEqual(h.bridge.companionConversation?.chatId, "phone-chat")
        h.audio.capture?(Data(repeating: 7, count: 3_200))
        await drain()
        XCTAssertEqual(h.channel.sent.map(\.kind), [.start, .capture])
        XCTAssertEqual(h.channel.sent.last?.payload.count, 3_200)
        XCTAssertEqual(h.channel.sent.map(\.sequence), [0, 1])
        h.bridge.disconnect(reason: "owner_stopped")
        await drain()
        XCTAssertEqual(h.channel.sent.last?.kind, .stop)
        XCTAssertFalse(h.bridge.companionActive)
    }

    func testPlaybackAcknowledgesOnlyRealStartAndCompletedAudioThenResumesCapture() async throws {
        let h = try await harness()
        let speech = CompanionVoiceSpeech(id: UUID(), index: 0, text: "Answer", frames: 3)
        try await h.deliver(.speechStart, speech.encoded())
        try await h.deliver(.speechPCM, Data(repeating: 0, count: 6))
        await drain()
        XCTAssertEqual(h.audio.played.count, 1)
        XCTAssertNil(h.audio.capture)
        XCTAssertFalse(h.channel.sent.contains { $0.kind == .playbackStarted || $0.kind == .playbackFinished })
        h.audio.started?()
        await drain()
        XCTAssertEqual(h.channel.sent.last?.kind, .playbackStarted)
        XCTAssertFalse(h.channel.sent.contains { $0.kind == .playbackFinished })
        h.audio.finished?()
        await drain()
        XCTAssertEqual(h.channel.sent.last?.kind, .playbackFinished)
        XCTAssertEqual(h.channel.sent.last?.payload, Data(speech.id.uuidString.utf8))
        XCTAssertNotNil(h.audio.capture)
        h.audio.finished?()
        await drain()
        XCTAssertEqual(h.channel.sent.filter { $0.kind == .playbackFinished }.count, 1)
        h.bridge.disconnect(reason: "test")
    }

    func testLateStopAndVolumeCannotChangeReplacementSpeech() async throws {
        let h = try await harness()
        let old = CompanionVoiceSpeech(id: UUID(), index: 0, text: "Old", frames: 1)
        let next = CompanionVoiceSpeech(id: UUID(), index: 1, text: "Next", frames: 1)
        try await h.deliver(.speechStart, old.encoded())
        try await h.deliver(.speechPCM, Data([0, 0]))
        let oldFinished = h.audio.finished
        h.audio.started?()
        oldFinished?()
        await drain()
        try await h.deliver(.speechStart, next.encoded())
        try await h.deliver(.speechPCM, Data([0, 0]))
        let stops = h.audio.playbackStops
        try await h.deliver(.stopSpeech, Data(old.id.uuidString.utf8))
        try await h.deliver(.volume, Data(old.id.uuidString.utf8) + Data([0]))
        oldFinished?()
        XCTAssertEqual(h.audio.playbackStops, stops)
        XCTAssertEqual(h.audio.volumes.last, 1)
        XCTAssertNil(h.audio.capture)
        try await h.deliver(.volume, Data(next.id.uuidString.utf8) + Data([25]))
        XCTAssertEqual(h.audio.volumes.last, 0.25)
        h.bridge.interruptPlayback()
        await drain()
        XCTAssertEqual(h.channel.sent.last?.kind, .stopSpeech)
        XCTAssertEqual(h.channel.sent.last?.payload, Data(next.id.uuidString.utf8))
        XCTAssertNotNil(h.audio.capture)
        h.bridge.disconnect(reason: "test")
    }

    func testWrongSessionIsRejectedButSequenceGapEndsCurrentSession() async throws {
        let h = try await harness()
        let foreign = try CompanionVoicePacket(kind: .stop, session: UUID(), sequence: 0, microseconds: 0)
        do {
            try await h.channel.onPacket?(foreign)
            XCTFail("foreign session")
        } catch {}
        XCTAssertTrue(h.bridge.companionActive)
        let gap = try CompanionVoicePacket(kind: .stop, session: h.session, sequence: 4, microseconds: 4)
        do {
            try await h.channel.onPacket?(gap)
            XCTFail("sequence gap")
        } catch {}
        XCTAssertFalse(h.bridge.companionActive)
        XCTAssertNil(h.audio.capture)
    }

    func testOverrunBackgroundDisconnectAndCaptureOverflowFailClosed() async throws {
        let h = try await harness()
        let speech = CompanionVoiceSpeech(id: UUID(), index: 0, text: "Answer", frames: 1)
        try await h.deliver(.speechStart, speech.encoded())
        do {
            try await h.deliver(.speechPCM, Data(repeating: 0, count: 4))
            XCTFail("overrun")
        } catch {}
        XCTAssertFalse(h.bridge.companionActive)
        let other = try await harness()
        other.audio.capture?(Data(repeating: 0, count: 12_802))
        await drain()
        XCTAssertEqual(other.bridge.state, .failed("audio_backpressure"))
        let third = try await harness()
        third.bridge.setForeground(false)
        XCTAssertFalse(third.bridge.companionActive)
        XCTAssertNil(third.audio.capture)
        third.channel.onReachabilityChanged?(false)
        XCTAssertFalse(third.bridge.companionActive)
    }

    func testPlaybackOnlyNeverRequestsMicrophoneAndPermissionDenialNeverStarts() async throws {
        let h = try await harness(mode: .playback)
        XCTAssertEqual(h.audio.permissionRequests, 0)
        XCTAssertEqual(h.audio.prepared, [false])
        XCTAssertNil(h.audio.capture)
        h.bridge.interruptPlayback()
        XCTAssertFalse(h.bridge.companionActive)
        let channel = WatchCompanionTestChannel()
        let audio = MockWatchVoiceAudioIO()
        audio.microphonePermission = .denied
        let bridge = WatchVoiceBridge(audio: audio, channel: channel)
        do {
            try await bridge.startCompanion(
                .init(owner: owner, mode: .conversation), onState: { _ in },
                onTranscript: { _, _ in }, onSpeaking: { _ in })
            XCTFail("denied microphone")
        } catch {}
        XCTAssertEqual(bridge.state, .failed("permission_denied"))
        XCTAssertTrue(channel.sent.isEmpty)
    }

    private func harness(mode: CompanionVoiceActivation.Mode = .conversation) async throws -> WatchBridgeHarness {
        let channel = WatchCompanionTestChannel()
        let audio = MockWatchVoiceAudioIO()
        let bridge = WatchVoiceBridge(audio: audio, channel: channel)
        try await bridge.startCompanion(
            .init(owner: owner, mode: mode, text: mode == .playback ? "Replay" : nil),
            onState: { _ in }, onTranscript: { _, _ in }, onSpeaking: { _ in })
        let session = try XCTUnwrap(channel.sent.first?.session)
        let h = WatchBridgeHarness(channel: channel, audio: audio, bridge: bridge, session: session)
        try await h.deliver(
            .ready, CompanionVoiceConversation(chatId: "phone-chat", title: "Phone conversation").encoded())
        return h
    }

    private func drain() async { for _ in 0..<50 { await Task.yield() } }
}

@MainActor
private final class WatchBridgeHarness {
    let channel: WatchCompanionTestChannel
    let audio: MockWatchVoiceAudioIO
    let bridge: WatchVoiceBridge
    let session: UUID
    private var sequence: UInt64 = 0
    init(channel: WatchCompanionTestChannel, audio: MockWatchVoiceAudioIO, bridge: WatchVoiceBridge, session: UUID) {
        self.channel = channel
        self.audio = audio
        self.bridge = bridge
        self.session = session
    }
    func deliver(_ kind: CompanionVoicePacket.Kind, _ payload: Data = Data()) async throws {
        let packet = try CompanionVoicePacket(
            kind: kind, session: session, sequence: sequence,
            microseconds: sequence, payload: payload)
        sequence += 1
        try await channel.onPacket?(packet)
    }
}

@MainActor
private final class WatchCompanionTestChannel: CompanionVoiceChannel {
    var reachable = true
    var onPacket: (@MainActor @Sendable (CompanionVoicePacket) async throws -> Void)?
    var onReachabilityChanged: (@MainActor @Sendable (Bool) -> Void)?
    var sent: [CompanionVoicePacket] = []
    func send(_ packet: CompanionVoicePacket) async throws {
        sent.append(try CompanionVoicePacket(data: packet.encoded))
    }
}

@MainActor
private final class MockWatchVoiceAudioIO: WatchVoiceAudioIO {
    var microphonePermission: WatchVoicePermission = .authorized
    var permissionRequests = 0
    var prepared: [Bool] = []
    var played: [Data] = []
    var volumes: [Float] = []
    var playbackStops = 0
    var capture: (@Sendable (Data) -> Void)?
    var started: (@MainActor () -> Void)?
    var finished: (@MainActor () -> Void)?
    func requestMicrophonePermission() async -> WatchVoicePermission {
        permissionRequests += 1
        return microphonePermission
    }
    func setEventHandler(_ handler: @escaping @MainActor (WatchVoiceAudioEvent) -> Void) {}
    func prepare(capture: Bool) throws { prepared.append(capture) }
    func startCapture(_ handler: @escaping @Sendable (Data) -> Void) throws { capture = handler }
    func stopCapture() { capture = nil }
    func enqueuePlayback(
        _ pcm: Data, startsAnnouncement: Bool, endsAnnouncement: Bool,
        onStarted: @escaping @MainActor () -> Void, onFinished: @escaping @MainActor () -> Void
    ) throws {
        played.append(pcm)
        if startsAnnouncement { started = onStarted }
        if endsAnnouncement { finished = onFinished }
    }
    func setVolume(_ volume: Float) { volumes.append(volume) }
    func stopPlayback() { playbackStops += 1 }
    func stop() {
        stopCapture()
        stopPlayback()
    }
}

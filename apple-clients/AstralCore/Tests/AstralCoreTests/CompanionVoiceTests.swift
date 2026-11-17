// Verifies the bounded ephemeral voice packets exchanged by the paired Watch and phone.
// Transport identity comes from WatchConnectivity; packet metadata never grants approval authority.

import Foundation
import XCTest

@testable import AstralCore

final class CompanionVoiceTests: XCTestCase {
    private let session = UUID()

    func testPCMAndControlRoundTripWithoutChangingIdentity() throws {
        for (kind, payload) in [
            (CompanionVoicePacket.Kind.capture, Data(repeating: 1, count: 3_200)),
            (.speechPCM, Data(repeating: 2, count: 4_800)), (.ack, Data()),
        ] {
            let packet = try CompanionVoicePacket(
                kind: kind, session: session, sequence: 42, microseconds: 200_000, payload: payload)
            XCTAssertEqual(try CompanionVoicePacket(data: packet.encoded), packet)
        }
    }

    func testMalformedHeadersLengthsKindsAndClockAreRefused() throws {
        let valid = try CompanionVoicePacket(kind: .ack, session: session, sequence: 0, microseconds: 0)
        for count in 0..<CompanionVoicePacket.headerBytes {
            XCTAssertThrowsError(try CompanionVoicePacket(data: Data(valid.encoded.prefix(count))))
        }
        for offset in [0, 4, 5, 6] {
            var corrupted = valid.encoded
            corrupted[offset] = 255
            XCTAssertThrowsError(try CompanionVoicePacket(data: corrupted))
        }
        XCTAssertThrowsError(
            try CompanionVoicePacket(
                kind: .ack, session: session, sequence: 0, microseconds: CompanionVoicePacket.maximumMicroseconds + 1))
        XCTAssertThrowsError(try CompanionVoicePacket(data: valid.encoded + Data([0])))
    }

    func testPCMRejectsOddEmptyAndOversizedPayloads() {
        for kind in [CompanionVoicePacket.Kind.capture, .speechPCM] {
            for payload in [Data(), Data([0]), Data(repeating: 0, count: 8_192)] {
                XCTAssertThrowsError(
                    try CompanionVoicePacket(
                        kind: kind, session: session, sequence: 0, microseconds: 0, payload: payload))
            }
        }
    }

    func testSequenceAndClockChecksDoNotAcceptOldOrReorderedAudio() throws {
        var gate = CompanionVoiceSequenceGate(session: session)
        func packet(_ sequence: UInt64, _ time: UInt64, session: UUID? = nil) throws -> CompanionVoicePacket {
            try CompanionVoicePacket(
                kind: .ack, session: session ?? self.session, sequence: sequence, microseconds: time)
        }
        XCTAssertTrue(gate.accept(try packet(0, 10)))
        XCTAssertFalse(gate.accept(try packet(0, 10)))
        XCTAssertFalse(gate.accept(try packet(2, 11)))
        XCTAssertFalse(gate.accept(try packet(1, 9)))
        XCTAssertFalse(gate.accept(try packet(1, 11, session: UUID())))
        XCTAssertTrue(gate.accept(try packet(1, 11)))
    }

    func testActivationUsesTheMeshIdAndHasNoTokenOrApprovalField() throws {
        let owner = try XCTUnwrap(CompanionVoiceOwner(meshId: Self.meshId))
        let activation = CompanionVoiceActivation(owner: owner, mode: .conversation)
        XCTAssertEqual(CompanionVoiceActivation(data: try activation.encoded()), activation)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: activation.encoded()) as? [String: Any])
        object["approved"] = true
        XCTAssertNil(CompanionVoiceActivation(data: try JSONSerialization.data(withJSONObject: object)))
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: activation.encoded()) as? [String: Any])
        object["owner"] = ["issuer": "https://issuer.test", "subject": "owner-1"]
        XCTAssertNil(CompanionVoiceActivation(data: try JSONSerialization.data(withJSONObject: object)))
        object["owner"] = "sha256:" + String(repeating: "A", count: 64)
        XCTAssertNil(CompanionVoiceActivation(data: try JSONSerialization.data(withJSONObject: object)))
    }

    func testOwnerMustBeTheMeshIdForm() {
        XCTAssertNotNil(CompanionVoiceOwner(meshId: Self.meshId))
        for bad in [
            "", "owner-1", "sha256:", "sha256:" + String(repeating: "a", count: 63),
            "sha256:" + String(repeating: "a", count: 65), "sha256:" + String(repeating: "A", count: 64),
            "sha256:" + String(repeating: "g", count: 64), "SHA256:" + String(repeating: "a", count: 64),
            String(repeating: "a", count: 64), "sha256:" + String(repeating: "a", count: 63) + "\n",
        ] {
            XCTAssertNil(CompanionVoiceOwner(meshId: bad), bad)
        }
    }

    static let meshId = "sha256:" + String(repeating: "ab12", count: 16)

    func testOnlyPlaybackModeMayCarryInitialText() throws {
        let owner = try XCTUnwrap(CompanionVoiceOwner(meshId: Self.meshId))
        let playback = CompanionVoiceActivation(owner: owner, mode: .playback, text: "Read this sentence.")
        XCTAssertEqual(CompanionVoiceActivation(data: try playback.encoded()), playback)
        XCTAssertThrowsError(try CompanionVoiceActivation(owner: owner, mode: .conversation, text: "yes").encoded())
        XCTAssertThrowsError(try CompanionVoiceActivation(owner: owner, mode: .playback).encoded())
    }

    func testConversationAndSpeechMetadataStayBoundedAndRejectExtraFields() throws {
        let conversation = CompanionVoiceConversation(chatId: "mesh-chat", title: "Phone conversation")
        XCTAssertEqual(CompanionVoiceConversation(data: try conversation.encoded()), conversation)
        let speech = CompanionVoiceSpeech(id: UUID(), index: 0, text: "A sentence.", frames: 24_000)
        XCTAssertEqual(CompanionVoiceSpeech(data: try speech.encoded()), speech)
        for field in ["frames", "index"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: speech.encoded()) as? [String: Any])
            object[field] = true
            XCTAssertNil(CompanionVoiceSpeech(data: try JSONSerialization.data(withJSONObject: object)))
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: speech.encoded()) as? [String: Any])
        object["approval"] = "yes"
        XCTAssertNil(CompanionVoiceSpeech(data: try JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try CompanionVoiceSpeech(id: UUID(), index: 0, text: "x", frames: 0).encoded())
        XCTAssertThrowsError(try CompanionVoiceConversation(chatId: "", title: "Phone").encoded())
    }
}

@MainActor
final class CompanionVoiceTransportTests: XCTestCase {
    func testSenderSerializesSequenceAndBoundsBackpressureWithoutDropping() async throws {
        let channel = CompanionBlockingChannel()
        let sender = CompanionVoiceSender(channel: channel, session: UUID())
        let first = Task { try await sender.send(.ack) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(channel.sent.map(\.sequence), [0])
        var queued: [Task<Void, Error>] = []
        for _ in 0..<7 {
            queued.append(Task { try await sender.send(.ack) })
            for _ in 0..<5 { await Task.yield() }
        }
        do {
            try await sender.send(.ack)
            XCTFail("unbounded queue")
        } catch {}
        channel.resume()
        try await first.value
        for task in queued { try await task.value }
        XCTAssertEqual(channel.sent.map(\.sequence), Array(0...7).map(UInt64.init))
        sender.retire()
        do {
            try await sender.send(.ack)
            XCTFail("retired sender")
        } catch {}
    }

    func testRetireFencesQueuedWorkAfterAnAlreadySentPacket() async throws {
        let channel = CompanionBlockingChannel()
        let sender = CompanionVoiceSender(channel: channel, session: UUID())
        let first = Task { try await sender.send(.ack) }
        for _ in 0..<20 { await Task.yield() }
        let queued = Task { try await sender.send(.ack) }
        for _ in 0..<20 { await Task.yield() }
        sender.retire()
        channel.resume()
        try await first.value
        do {
            try await queued.value
            XCTFail("retired queued packet")
        } catch {}
        XCTAssertEqual(channel.sent.count, 1)
    }

    func testReplyCompletesOnceIncludingCancellationBeforeInstall() async throws {
        let reply = CompanionVoiceReply()
        let waiting = Task {
            try await withCheckedThrowingContinuation { reply.install($0) }
        }
        reply.finish()
        reply.finish(CompanionVoiceError.rejected)
        try await waiting.value
        let cancelled = CompanionVoiceReply()
        cancelled.finish(CancellationError())
        do {
            try await withCheckedThrowingContinuation { cancelled.install($0) }
            XCTFail("cancelled reply")
        } catch is CancellationError {} catch { XCTFail("wrong error") }
        cancelled.finish()
    }
}

@MainActor
private final class CompanionBlockingChannel: CompanionVoiceChannel {
    var reachable = true
    var onPacket: (@MainActor @Sendable (CompanionVoicePacket) async throws -> Void)?
    var onReachabilityChanged: (@MainActor @Sendable (Bool) -> Void)?
    var sent: [CompanionVoicePacket] = []
    private var blocked = true
    private var waiter: CheckedContinuation<Void, Never>?
    func send(_ packet: CompanionVoicePacket) async throws {
        sent.append(packet)
        if blocked { await withCheckedContinuation { waiter = $0 } }
    }
    func resume() {
        blocked = false
        waiter?.resume()
        waiter = nil
    }
}

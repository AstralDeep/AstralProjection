// Checks Watch capability retirement, authenticated paired activation, lifecycle and audio privacy.
// Hosted server voice controls never activate media or submit transcripts.

import AVFoundation
import AstralCore
@testable import AstralWatch
import Foundation
import SwiftUI
import XCTest

@MainActor
final class VoiceContract065Tests: XCTestCase {
    func testRegistrationDoesNotAdvertiseHostedVoiceTransport() throws {
        let model = WatchModel()
        let first = try JSONValue.parse(Data(model.registrationFrame(token: "token", resumed: false).utf8))
        let second = try JSONValue.parse(Data(model.registrationFrame(token: "token", resumed: true).utf8))
        XCTAssertEqual(first["device"]?["voice_transport"]?.stringValue, "")
        XCTAssertEqual(second["device"]?["voice_transport"]?.stringValue, "")
        XCTAssertEqual(first["device_id"], second["device_id"])
        XCTAssertNotEqual(first["connection_generation"], second["connection_generation"])
        XCTAssertEqual(first["device"]?["full_duplex"]?.boolValue, false)
    }

    func testRetiredRESTNeverRequestsTokenOrCallsHTTPTransport() async throws {
        let device = UUID().uuidString.lowercased()
        let connection = UUID().uuidString.lowercased()
        let raw = """
            {"type":"voice_control_binding","schema_version":"1","device_id":"\(device)",
            "connection_generation":"\(connection)","binding_id":"\(UUID().uuidString.lowercased())",
            "binding":"synthetic-retired-binding-1234567890","expires_at":"2099-07-31T12:10:00Z"}
            """
        let binding = try XCTUnwrap(
            WatchVoiceControlBinding(
                frame: try XCTUnwrap(InboundFrame.parse(raw)), expectedDeviceId: device, expectedConnection: connection)
        )
        let client = WatchVoiceRESTClient(
            serverBase: URL(string: "https://voice.example.test")!, deviceId: device,
            connectionGeneration: connection, controlBinding: binding,
            tokenProvider: {
                XCTFail("retired voice requested credentials")
                return nil
            },
            transport: { _ in
                XCTFail("retired voice requested HTTP")
                throw URLError(.notConnectedToInternet)
            })
        do {
            _ = try await client.createSession(chatId: "chat", activationId: UUID().uuidString, permission: .authorized)
            XCTFail("retired transport succeeded")
        } catch { XCTAssertEqual(error as? WatchVoiceRESTError, .retired) }
    }

    func testHostedComposerAndSessionMessagesCannotActivatePairedVoice() throws {
        let model = WatchModel()
        let bridge = ContractWatchBridge()
        model.voiceBridge = bridge
        for type in ["composer_state", "voice_control_binding", "voice_session_state", "voice_turn_state"] {
            model.handleFrame(InboundFrame(name: type, payload: .object(["type": .string(type)])))
        }
        XCTAssertNil(model.voiceComposer)
        XCTAssertNil(model.voiceSession)
        XCTAssertTrue(bridge.activations.isEmpty)
    }

    func testExplicitActivationNeedsStoredAccountAndUsesPairedConversationOnly() async throws {
        let model = WatchModel()
        let bridge = ContractWatchBridge()
        model.voiceBridge = bridge
        var sent: [String] = []
        model.currentConnectionVoiceSendOverride = { sent.append($0) }
        model.performPrimaryVoiceAction()
        await drain()
        XCTAssertTrue(bridge.activations.isEmpty)
        XCTAssertEqual(model.voiceReason, "phone_owner_unavailable")
        let account = try XCTUnwrap(ConversationAccount(issuer: "https://issuer.example", subject: "owner"))
        model.bindConversationAccount(account)
        model.performPrimaryVoiceAction()
        await drain()
        XCTAssertEqual(bridge.activations.count, 1)
        XCTAssertEqual(
            bridge.activations.first?.owner, CompanionVoiceOwner(issuer: account.issuer, subject: account.subject))
        XCTAssertEqual(model.voiceMessage, "iPhone: Phone conversation")
        bridge.transcript?("yes approve the payment", true)
        XCTAssertEqual(model.voicePartialTranscript, "yes approve the payment")
        XCTAssertTrue(sent.isEmpty)
        model.handleVoiceScenePhase(.background)
        XCTAssertFalse(bridge.companionActive)
        XCTAssertTrue(sent.isEmpty)
        model.handleVoiceScenePhase(.active)
        await drain()
        XCTAssertEqual(bridge.activations.count, 1)
    }

    func testAccountChangeRetiresPairedAudioAndReplayText() async throws {
        let model = WatchModel()
        let bridge = ContractWatchBridge()
        model.voiceBridge = bridge
        model.bindConversationAccount(try XCTUnwrap(.init(issuer: "https://issuer.example", subject: "owner")))
        model.performPrimaryVoiceAction()
        await drain()
        XCTAssertTrue(bridge.companionActive)
        model.bindConversationAccount(try XCTUnwrap(.init(issuer: "https://issuer.example", subject: "different")))
        XCTAssertFalse(bridge.companionActive)
        bridge.transcript?("retired text", true)
        XCTAssertNil(model.voicePartialTranscript)
        model.speaker.replay()
        await drain()
        XCTAssertEqual(bridge.activations.count, 1)
    }

    func testSpeakerOnlyReportsActualPlaybackAndRequestsPhoneForReplay() {
        let speaker = Speaker()
        var texts: [String] = []
        var stops = 0
        speaker.onSpeak = { texts.append($0) }
        speaker.onStop = { stops += 1 }
        speaker.remember(AstralSpeech(ssml: "", text: "Answer"))
        XCTAssertFalse(speaker.isSpeaking)
        XCTAssertTrue(texts.isEmpty)
        speaker.playbackChanged(true)
        XCTAssertTrue(speaker.isSpeaking)
        speaker.replay()
        XCTAssertFalse(speaker.isSpeaking)
        XCTAssertEqual(texts, ["Answer"])
        XCTAssertEqual(stops, 1)
        speaker.clear()
        speaker.replay()
        XCTAssertEqual(texts.count, 1)
    }

    func testADVCCodecUsesExactBigEndianHeaderLengthsAndSequenceGate() throws {
        let payload = Data(repeating: 0x7f, count: WatchVoicePCMFrame.capturePayloadLength)
        let frame = try XCTUnwrap(
            WatchVoicePCMFrame(
                kind: .microphone,
                sequence: 0x0102_0304_0506_0708,
                timestampMicroseconds: 0x1112_1314_1516_1718,
                payload: payload))
        let encoded = frame.encoded

        XCTAssertEqual(encoded.count, 26 + 640)
        XCTAssertEqual(Array(encoded.prefix(8)), [0x41, 0x44, 0x56, 0x43, 1, 1, 0, 0])
        XCTAssertEqual(Array(encoded[8..<16]), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(Array(encoded[24..<26]), [0x02, 0x80])
        XCTAssertEqual(WatchVoicePCMFrame(data: encoded), frame)

        var flagged = encoded
        flagged[7] = 1
        XCTAssertNil(WatchVoicePCMFrame(data: flagged))

        var gate = WatchVoicePCMSequenceGate()
        XCTAssertTrue(gate.accept(frame))
        let next = try XCTUnwrap(
            WatchVoicePCMFrame(
                kind: .microphone,
                sequence: frame.sequence + 1,
                timestampMicroseconds: frame.timestampMicroseconds + 20_000,
                payload: payload))
        XCTAssertTrue(gate.accept(next))
        let gap = try XCTUnwrap(
            WatchVoicePCMFrame(
                kind: .microphone,
                sequence: next.sequence + 2,
                timestampMicroseconds: next.timestampMicroseconds + 40_000,
                payload: payload))
        XCTAssertFalse(gate.accept(gap))
    }

    func testAudioSessionInterruptionSignalsImmediatePauseAndRecovery() async {
        let audio = WatchVoiceAudioEngine()
        var events: [WatchVoiceAudioEvent] = []
        audio.setEventHandler { events.append($0) }

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.began.rawValue
            ])
        try? await Task.sleep(for: .milliseconds(30))
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.ended.rawValue
            ])
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(events, [.interrupted("audio_interrupted"), .recovered])
    }

    func testWatchPrivacyDeclaresMicrophoneAndLinkedNonTrackingAudio() throws {
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription"))
        let manifestURL = try XCTUnwrap(
            Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try plist(at: manifestURL)

        let collected = try XCTUnwrap(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let audio = try XCTUnwrap(
            collected.first {
                $0["NSPrivacyCollectedDataType"] as? String
                    == "NSPrivacyCollectedDataTypeAudioData"
            })
        XCTAssertEqual(audio["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
        XCTAssertEqual(audio["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
    }

    private func plist(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }
    private func drain() async { for _ in 0..<30 { await Task.yield() } }
}

@MainActor
private final class ContractWatchBridge: WatchVoiceBridgeControlling {
    var state = WatchVoiceBridgeState.idle
    var microphonePermission = WatchVoicePermission.authorized
    var companionActive = false
    var companionConversation: CompanionVoiceConversation? = .init(chatId: "phone-chat", title: "Phone conversation")
    var activations: [CompanionVoiceActivation] = []
    var transcript: (@MainActor (String, Bool) -> Void)?
    func requestMicrophonePermission() async -> WatchVoicePermission { microphonePermission }
    func startCompanion(
        _ activation: CompanionVoiceActivation,
        onState: @escaping @MainActor (WatchVoiceBridgeState) -> Void,
        onTranscript: @escaping @MainActor (String, Bool) -> Void,
        onSpeaking: @escaping @MainActor (Bool) -> Void
    ) async throws {
        activations.append(activation)
        companionActive = true
        transcript = onTranscript
        state = .ready
        onState(.ready)
    }
    func connect(
        grant: WatchVoiceBridgeGrant, onState: @escaping @MainActor (WatchVoiceBridgeState) -> Void,
        onTranscript: @escaping @MainActor (WatchVoiceTranscript) -> Void,
        onPlayout: @escaping @MainActor (WatchVoicePlayoutObservation) -> Void
    ) async throws {
        throw CompanionVoiceError.rejected
    }
    func setCaptureEnabled(_ enabled: Bool) {}
    func interruptPlayback() {}
    func disconnect(reason: String) {
        companionActive = false
        state = .ended
    }
}

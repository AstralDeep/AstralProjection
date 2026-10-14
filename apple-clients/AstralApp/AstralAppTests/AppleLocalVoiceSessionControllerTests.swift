// Integration tests for the client_local/v1 path in AppleVoiceSessionController: the v2
// capability selection branch, on-device readiness gating with typed fallback, local session
// lifecycle (foreground suspension, recovery, mute, stop speech, end), local frame routing, and
// the preserved remote LiveKit activation when the deployment selects llm_factory or an older
// server returns 404.

import AstralCore
import Foundation
import XCTest

@testable import AstralDeep

@MainActor
final class AppleLocalVoiceSessionControllerTests: XCTestCase {
    private let device = "00000000-0000-4000-8000-00000000000a"
    private let connection = "00000000-0000-4000-8000-00000000000b"
    private let localSessionId = "00000000-0000-4000-8000-00000000000c"
    private let chat = "00000000-0000-4000-8000-00000000000d"
    private let remoteSessionId = "00000000-0000-4000-8000-00000000000e"
    private let turnId = "00000000-0000-4000-8000-00000000000f"
    private let submissionId = "00000000-0000-4000-8000-00000000000f"
    private let requestGeneration = "00000000-0000-4000-8000-000000000010"

    private var api: FakeVoiceAPI!
    private var media: FakeVoiceMedia!
    private var engine: FakeLocalSpeechEngine!
    private var sentTexts: [String] = []

    func reset() {
        api = FakeVoiceAPI()
        media = FakeVoiceMedia()
        engine = FakeLocalSpeechEngine()
        sentTexts = []
    }

    private func makeController() -> AppleVoiceSessionController {
        let controller = AppleVoiceSessionController(
            api: api, media: media,
            permissionProvider: {
                AppleVoiceMediaCapability(
                    hasMicrophone: true, hasAudioOutput: true,
                    microphonePermission: "authorized", fullDuplex: true)
            },
            localEngine: engine,
            uuid: { "00000000-0000-4000-8000-000000000001" })
        controller.setFrameSender { [weak self] text in
            self?.sentTexts.append(text) ?? false
            return true
        }
        return controller
    }

    private func install(_ controller: AppleVoiceSessionController) {
        controller.installUIConnection(
            token: "access-token", serverBase: URL(string: "https://example.test/")!,
            deviceId: device, deviceKind: "ios", connectionGeneration: connection,
            visibleChatId: chat)
        controller.consume(frame(binding()))
    }

    private func drain() async {
        for _ in 0..<25 { await Task.yield() }
    }

    private func frame(_ text: String) -> InboundFrame {
        InboundFrame.parse(text)!
    }

    private func binding() -> String {
        """
        {"type":"voice_control_binding","schema_version":"1","device_id":"\(device)","connection_generation":"\(connection)","binding_id":"00000000-0000-4000-8000-00000000000a","binding":"synthetic-binding-value-000000000000","expires_at":"2099-07-31T12:10:00Z"}
        """
    }

    private func localSelection(status: String = "requires_client_readiness") -> JSONValue {
        .object([
            "schema_version": .string("2"),
            "speech_backend": .string("client_local"),
            "status": .string(status),
            "reason": .string(
                status == "unavailable" ? "feature_disabled" : "client_readiness_required"),
            "checked_at": .string("2099-07-31T11:00:00Z"),
            "expires_at": .string("2099-07-31T11:01:00Z"),
            "supported_transports": .array([.string("client_local")]),
            "requirements": .object([
                "session_contract": .string("voice-rest/v2-client-local"),
                "local_frame_contract": .string("client_local/v1"),
                "configured_locale": .string("en-US"),
                "recognition_must_be_local": .bool(true),
                "synthesis_must_be_local": .bool(true),
                "installation_policy": .string("explicit_user_action_only"),
                "requirement_revision": .number(1),
                "max_final_unicode_scalars": .number(8_000),
                "max_announcement_utf8_bytes": .number(600),
                "announcement_ttl_seconds": .number(10),
                "echo_suppression_milliseconds": .number(500),
            ]),
        ])
    }

    private func localSession(
        sessionId: String = AppleLocalVoiceSessionControllerTests.staticLocalSessionId,
        speechRevision: Int = 2, microphone: Bool = true, muted: Bool = false,
        foreground: Bool = true
    ) -> AppleLocalVoiceSession {
        AppleLocalVoiceSession(
            sessionId: sessionId, generation: 1, speechRevision: speechRevision,
            state: "active", visibleChatId: chat, chatContextRevision: 3,
            appliedChatContextRevision: 3, chatContextSynced: true, foregroundActive: foreground,
            microphoneEnabled: microphone, speechMuted: muted, configuredLocale: "en-US",
            idleExpiresAt: "2099-07-31T12:00:00Z")
    }

    private static let staticLocalSessionId = "00000000-0000-4000-8000-00000000000c"

    private func sessionReadyFrame() -> String {
        """
        {"type":"voice_local_session_ready","schema_version":"2","speech_backend":"client_local","device_id":"\(device)","connection_generation":"\(connection)","session_id":"\(localSessionId)","generation":1,"speech_revision":2,"contract":"client_local/v1","transport":"client_local","configured_locale":"en-US","chat_id":"\(chat)","chat_context_revision":3,"applied_chat_context_revision":3,"foreground_active":true,"microphone_enabled":true,"speech_muted":false,"lease_expires_at":"2099-07-31T12:05:00Z"}
        """
    }

    private func sentFrames(named name: String) -> [[String: JSONValue]] {
        sentTexts.compactMap { text in
            guard let parsed = InboundFrame.parse(text), parsed.name == name,
                let object = parsed.payload.objectValue
            else { return nil }
            return object
        }
    }

    private func activatedLocalController() async -> AppleVoiceSessionController {
        let controller = makeController()
        install(controller)
        api.capabilityV2Status = 200
        api.capabilityV2Payload = localSelection()
        api.startLocalOutcome = .started(localSession())
        await controller.activate()
        await drain()
        XCTAssertEqual(api.startLocalCount, 1)
        XCTAssertEqual(controller.speechBackend, "client_local")
        return controller
    }

    func testRemoteActivationIsPreservedWhenV2IsUnavailable() async {
        reset()
        let controller = makeController()
        install(controller)
        api.capabilityV2Status = 404
        api.startOutcome = .started(restSession(), grant())
        await controller.activate()
        await drain()
        XCTAssertEqual(api.startCount, 1)
        XCTAssertEqual(api.startLocalCount, 0)
        XCTAssertEqual(controller.speechBackend, "llm_factory")
        XCTAssertEqual(media.connectCount, 1)
    }

    func testRemoteActivationIsPreservedWhenServerSelectsLLMFactory() async {
        reset()
        let controller = makeController()
        install(controller)
        api.capabilityV2Status = 200
        api.capabilityV2Payload = remoteSelection()
        api.startOutcome = .started(restSession(), grant())
        await controller.activate()
        await drain()
        XCTAssertEqual(api.startCount, 1)
        XCTAssertEqual(api.startLocalCount, 0)
        XCTAssertEqual(controller.speechBackend, "llm_factory")
    }

    func testLocalActivationCreatesLocalSessionAndSendsReady() async {
        reset()
        _ = await activatedLocalController()
        XCTAssertEqual(api.startCount, 0)
        XCTAssertEqual(api.lastLocalCapability?["recognition_processing"]?.stringValue, "guaranteed_local")
        XCTAssertEqual(api.lastLocalCapability?["full_duplex"]?.boolValue, false)
        XCTAssertEqual(api.lastLocalCapability?["contract"]?.stringValue, "client_local/v1")
        XCTAssertEqual(sentFrames(named: "voice_local_ready").count, 1)
        XCTAssertEqual(media.connectCount, 0)
    }

    func testLocalActivationRefusedWhenOnDeviceProcessingIsNotProved() async {
        reset()
        let controller = makeController()
        install(controller)
        engine.observationValue = AppleLocalSpeechObservation(
            hasMicrophone: true, hasAudioOutput: true, microphonePermission: "authorized",
            recognitionPermission: "denied", recognitionProcessing: "guaranteed_local",
            recognitionLocale: "ready", recognitionInstallation: "ready",
            synthesisProcessing: "guaranteed_local", synthesisLocale: "ready")
        api.capabilityV2Status = 200
        api.capabilityV2Payload = localSelection()
        await controller.activate()
        await drain()
        XCTAssertEqual(api.startCount, 0)
        XCTAssertEqual(api.startLocalCount, 0)
        XCTAssertEqual(controller.speechBackend, "llm_factory")
        XCTAssertEqual(controller.phase, "unavailable")
        XCTAssertEqual(controller.reason, "speech_recognition_permission_denied")
    }

    func testUnavailableSelectionKeepsTypedConversationWithoutSession() async {
        reset()
        let controller = makeController()
        install(controller)
        api.capabilityV2Status = 200
        api.capabilityV2Payload = localSelection(status: "unavailable")
        await controller.activate()
        await drain()
        XCTAssertEqual(api.startCount, 0)
        XCTAssertEqual(api.startLocalCount, 0)
        XCTAssertEqual(controller.phase, "unavailable")
        XCTAssertEqual(controller.reason, "feature_disabled")
    }

    func testMalformedSelectionFallsBackToRemoteFlow() async {
        reset()
        let controller = makeController()
        install(controller)
        var malformed = localSelection().objectValue!
        malformed["supported_transports"] = .array([.string("livekit")])
        api.capabilityV2Status = 200
        api.capabilityV2Payload = .object(malformed)
        api.startOutcome = .started(restSession(), grant())
        await controller.activate()
        await drain()
        XCTAssertEqual(api.startCount, 1)
        XCTAssertEqual(api.startLocalCount, 0)
    }

    func testSessionReadyStartsLocalRecognitionThroughController() async {
        reset()
        let controller = await activatedLocalController()
        controller.consume(frame(sessionReadyFrame()))
        await drain()
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertEqual(sentFrames(named: "voice_local_recognition_started").count, 1)
        XCTAssertEqual(controller.phase, "listening")
    }

    func testAnnouncementReachesTheRuntimeThroughTheController() async {
        reset()
        let controller = await activatedLocalController()
        controller.consume(frame(sessionReadyFrame()))
        await drain()
        let announcement =
            """
            {"type":"voice_local_announcement","schema_version":"2","speech_backend":"client_local","device_id":"\(device)","connection_generation":"\(connection)","session_id":"\(localSessionId)","generation":1,"speech_revision":2,"announcement_id":"00000000-0000-4000-8000-000000000011","announcement_sequence":1,"turn_id":"\(turnId)","kind":"result","output_policy":"full_recap","locale":"en-US","text":"All done.","text_digest_sha256":"\(AppleLocalVoiceRuntime.sha256Hex("All done."))","expires_at":"2099-07-31T12:00:09Z","foreground_required":true,"mute_revision":1,"consent_revision":1}
            """
        controller.consume(frame(announcement))
        await drain()
        XCTAssertEqual(engine.speakCount, 1)
        XCTAssertEqual(engine.lastSpokenText, "All done.")
    }

    func testForegroundSuspensionStopsLocalOwnersAndRecoveryRehandshakes() async {
        reset()
        let controller = await activatedLocalController()
        controller.consume(frame(sessionReadyFrame()))
        await drain()
        api.updatedLocalSession = localSession(foreground: false)
        controller.sceneBecameInactive()
        await drain()
        XCTAssertGreaterThanOrEqual(engine.stopAllCount, 1)
        XCTAssertEqual(api.lastLocalUpdate?["foreground_active"]?.boolValue, false)
        XCTAssertEqual(controller.phase, "suspended")
        api.updatedLocalSession = localSession(foreground: true)
        controller.sceneBecameActive()
        await drain()
        XCTAssertEqual(api.lastLocalUpdate?["foreground_active"]?.boolValue, true)
        XCTAssertEqual(sentFrames(named: "voice_local_ready").count, 2)
    }

    func testPermissionRevocationDuringRecoveryEndsWithTypedFallback() async {
        reset()
        let controller = await activatedLocalController()
        api.updatedLocalSession = localSession(foreground: false)
        controller.sceneBecameInactive()
        await drain()
        engine.observationValue = AppleLocalSpeechObservation(
            hasMicrophone: true, hasAudioOutput: true, microphonePermission: "authorized",
            recognitionPermission: "denied", recognitionProcessing: "guaranteed_local",
            recognitionLocale: "ready", recognitionInstallation: "ready",
            synthesisProcessing: "guaranteed_local", synthesisLocale: "ready")
        api.updatedLocalSession = localSession(foreground: true)
        controller.sceneBecameActive()
        await drain()
        XCTAssertEqual(controller.speechBackend, "llm_factory")
        XCTAssertEqual(controller.phase, "unavailable")
        XCTAssertEqual(controller.reason, "speech_recognition_permission_denied")
        XCTAssertEqual(sentFrames(named: "voice_local_ready").count, 1)
    }

    func testMuteForLocalSessionPatchesAndStopsPlayout() async {
        reset()
        let controller = await activatedLocalController()
        controller.consume(frame(sessionReadyFrame()))
        await drain()
        api.updatedLocalSession = localSession(muted: true)
        await controller.perform(.muteSpeech)
        await drain()
        XCTAssertEqual(api.lastLocalUpdate?["speech_muted"]?.boolValue, true)
        XCTAssertGreaterThanOrEqual(engine.stopAllCount, 1)
        XCTAssertEqual(controller.phase, "muted")
    }

    func testStopSpeechConfirmsWithFreshReadyHandshake() async {
        reset()
        let controller = await activatedLocalController()
        controller.consume(frame(sessionReadyFrame()))
        await drain()
        await controller.perform(.stopSpeech)
        await drain()
        XCTAssertEqual(api.stopCount, 1)
        XCTAssertEqual(sentFrames(named: "voice_local_ready").count, 2)
    }

    func testEndForLocalSessionUsesLocalFenceAndResetsBackend() async {
        reset()
        let controller = await activatedLocalController()
        await controller.perform(.end)
        await drain()
        XCTAssertEqual(api.endCount, 1)
        XCTAssertEqual(api.lastEndFence?.sessionId, localSessionId)
        XCTAssertEqual(api.lastEndFence?.mediaGrantRevision, 2)
        XCTAssertEqual(controller.speechBackend, "llm_factory")
        XCTAssertNil(controller.local?.fence)
    }

    func testUserMessageAckCompletesLocalFinal() async {
        reset()
        let controller = await activatedLocalController()
        controller.consume(frame(sessionReadyFrame()))
        await drain()
        let started = sentFrames(named: "voice_local_recognition_started")[0]
        let clientTurnId = started["client_turn_id"]!.stringValue!
        let bound =
            """
            {"type":"voice_local_turn_bound","schema_version":"2","speech_backend":"client_local","device_id":"\(device)","connection_generation":"\(connection)","session_id":"\(localSessionId)","generation":1,"speech_revision":2,"client_turn_id":"\(clientTurnId)","turn_id":"\(turnId)","submission_id":"\(submissionId)","request_generation":"\(requestGeneration)","chat_id":"\(chat)","chat_context_revision":3,"recognition_sequence":1,"binding_expires_at":"2099-07-31T12:02:00Z"}
            """
        controller.consume(frame(bound))
        engine.emitFinal("spoken request")
        await drain()
        XCTAssertEqual(sentFrames(named: "voice_local_final").count, 1)
        let ack =
            """
            {"type":"user_message_acked","schema_version":"1","chat_id":"\(chat)","message_id":7,"submission_id":"\(submissionId)","request_generation":"\(requestGeneration)","connection_generation":"\(connection)","voice_turn_id":"\(turnId)"}
            """
        controller.consume(frame(ack))
        await drain()
        XCTAssertEqual(sentFrames(named: "voice_local_final").count, 1)
        XCTAssertEqual(controller.phase, "processing")
    }

    func testLocalFramesFromOtherConnectionsAreRefused() async {
        reset()
        let controller = await activatedLocalController()
        let otherConnection = "00000000-0000-4000-8000-0000000000aa"
        let stale =
            """
            {"type":"voice_local_session_ready","schema_version":"2","speech_backend":"client_local","device_id":"\(device)","connection_generation":"\(otherConnection)","session_id":"\(localSessionId)","generation":1,"speech_revision":2,"contract":"client_local/v1","transport":"client_local","configured_locale":"en-US","chat_id":"\(chat)","chat_context_revision":3,"applied_chat_context_revision":3,"foreground_active":true,"microphone_enabled":true,"speech_muted":false,"lease_expires_at":"2099-07-31T12:05:00Z"}
            """
        controller.consume(frame(stale))
        await drain()
        XCTAssertEqual(engine.startCount, 0)
    }

    func testComposerOwnerFromAnotherDeviceExposesLocalTakeoverTarget() async {
        reset()
        let controller = await activatedLocalController()
        let composer =
            """
            {"type":"composer_state","schema_version":"1","revision":3,"connection_generation":"\(connection)","voice":{"available":true,"state":"listening","speech_muted":false,"microphone_enabled":true,"foreground_active":true,"reason":"ready","output_locale":"en-US","chat_context_revision":3,"applied_chat_context_revision":3,"chat_context_synced":true,"session_id":"00000000-0000-4000-8000-0000000000bb","generation":1,"media_grant_revision":4,"visible_chat_id":"\(chat)","owner_device":{"device_id":"00000000-0000-4000-8000-0000000000cc","device_kind":"macos","generation":1},"controls":[{"key":"voice-microphone","action":"voice_microphone_set","label":"Microphone","icon":"microphone","visible":true,"enabled":true,"pressed":true,"busy":false},{"key":"voice-mute","action":"voice_speech_mute_set","label":"Mute voice","icon":"speaker-muted","visible":true,"enabled":true,"pressed":false,"busy":false},{"key":"voice-end","action":"voice_session_end","label":"End","icon":"stop","visible":true,"enabled":true,"pressed":false,"busy":false}]}}
            """
        controller.consume(frame(composer))
        XCTAssertTrue(controller.takeoverAvailable)
        api.capabilityV2Status = 200
        api.capabilityV2Payload = localSelection()
        api.startLocalOutcome = .started(localSession())
        await controller.takeover()
        await drain()
        XCTAssertEqual(api.takeoverLocalCount, 1)
        XCTAssertEqual(
            api.lastLocalTakeoverTarget?.sessionId, "00000000-0000-4000-8000-0000000000bb")
        XCTAssertEqual(api.lastLocalTakeoverTarget?.mediaGrantRevision, 4)
    }

    private func remoteSelection() -> JSONValue {
        .object([
            "schema_version": .string("2"),
            "speech_backend": .string("llm_factory"),
            "status": .string("ready"),
            "reason": .string("ready"),
            "checked_at": .string("2099-07-31T11:00:00Z"),
            "expires_at": .string("2099-07-31T11:01:00Z"),
            "supported_transports": .array([.string("livekit")]),
            "requirements": .object([
                "session_contract": .string("voice-rest/v1"),
                "local_frame_contract": .null,
                "configured_locale": .string("en-US"),
                "recognition_must_be_local": .bool(false),
                "synthesis_must_be_local": .bool(false),
                "installation_policy": .string("explicit_user_action_only"),
                "requirement_revision": .number(1),
                "max_final_unicode_scalars": .number(8_000),
                "max_announcement_utf8_bytes": .number(600),
                "announcement_ttl_seconds": .number(10),
                "echo_suppression_milliseconds": .number(500),
            ]),
        ])
    }

    private func restSession() -> AppleVoiceRestSession {
        AppleVoiceRestSession(
            sessionId: remoteSessionId, deviceId: device, deviceKind: "ios",
            transport: "livekit", ownerConnectionGeneration: connection,
            visibleChatId: chat, appliedVisibleChatId: chat, generation: 1,
            mediaGrantRevision: 2, chatContextRevision: 3, appliedChatContextRevision: 3,
            chatContextSynced: true, state: "active", foregroundActive: true,
            foregroundReason: "foreground", speechMuted: false, microphoneEnabled: true,
            leaseExpiresAt: "2099-07-31T12:01:00Z")
    }

    private func grant() -> AppleLiveKitGrant {
        AppleLiveKitGrant(
            grantId: "grant-01", sessionId: remoteSessionId, generation: 1,
            mediaGrantRevision: 2, expiresAt: "2099-07-31T12:02:00Z",
            url: "wss://voice.example.test", joinToken: String(repeating: "a", count: 64),
            roomName: "voice-room", participantIdentity: "ios-client-01",
            workerIdentity: "voice-worker-01")
    }
}

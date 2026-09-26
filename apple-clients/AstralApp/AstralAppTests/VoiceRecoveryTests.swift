// Exercises bounded media recovery through the voice controller's normal authenticated binding flow.
// Failing media doubles reproduce transport callbacks followed by a thrown connection error.

import AstralCore
import Foundation
import XCTest

@testable import AstralDeep

@MainActor
final class VoiceRecoveryTests: XCTestCase {
    func testFailedCallbacksAndThrowsRespectBackoffAndAttemptBudget() async throws {
        let harness = VoiceRecoveryHarness(retryNanoseconds: 60_000_000)
        defer { harness.controller.close() }
        await harness.controller.activate()
        harness.media.failuresRemaining = 100
        harness.media.eventHandler?(.failed)
        try await wait { harness.api.refreshCount >= 1 }
        let firstAttempt = harness.api.refreshCount
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(firstAttempt, 1)
        XCTAssertEqual(harness.api.refreshCount, firstAttempt)
        try await wait { harness.controller.phase == "error" }
        XCTAssertEqual(harness.api.refreshCount, 3)
        XCTAssertEqual(harness.media.connectCount, 4)
        for _ in 0..<12 { harness.media.eventHandler?(.failed) }
        harness.controller.sceneBecameActive()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(harness.api.refreshCount, 3)
        XCTAssertEqual(harness.controller.phase, "error")
        XCTAssertFalse(harness.controller.mediaConnected)
        await harness.controller.perform(.end)
        XCTAssertEqual(harness.api.endCount, 1)
        XCTAssertEqual(harness.controller.phase, "ended")
    }

    func testInitialConnectThrowsWithoutCallbackStillRecoversWithinBudget() async throws {
        let harness = VoiceRecoveryHarness(retryNanoseconds: 10_000_000)
        defer { harness.controller.close() }
        harness.media.emitsFailure = false
        harness.media.failuresRemaining = 100
        await harness.controller.activate()
        try await wait { harness.controller.phase == "error" }
        XCTAssertEqual(harness.api.refreshCount, 3)
        XCTAssertEqual(harness.media.connectCount, 4)
        XCTAssertFalse(harness.controller.mediaConnected)
    }

    func testSuccessfulRecoveryResetsTheBudgetForANewOutage() async throws {
        let harness = VoiceRecoveryHarness(retryNanoseconds: 5_000_000)
        defer { harness.controller.close() }
        await harness.controller.activate()
        for expectedRefreshes in [2, 4] {
            harness.media.failuresRemaining = 1
            harness.media.eventHandler?(.failed)
            try await wait { harness.api.refreshCount >= expectedRefreshes && harness.controller.mediaConnected }
            XCTAssertEqual(harness.api.refreshCount, expectedRefreshes)
            XCTAssertEqual(harness.controller.phase, "listening")
        }
    }

    func testEndCloseAuthenticationAndConnectionChangesCancelBackoff() async throws {
        for cancellation in ["end", "close", "authentication", "connection"] {
            let harness = VoiceRecoveryHarness(retryNanoseconds: 80_000_000)
            defer { harness.controller.close() }
            await harness.controller.activate()
            harness.media.failuresRemaining = 100
            harness.media.eventHandler?(.failed)
            try await wait { harness.api.refreshCount >= 1 }
            switch cancellation {
            case "end": await harness.controller.perform(.end)
            case "close": harness.controller.close()
            case "authentication":
                harness.controller.consume(InboundFrame.parse(#"{"type":"auth_required","reason":"expired"}"#)!)
            default:
                harness.install(connection: "00000000-0000-4000-8000-000000000012", bind: false)
            }
            let refreshCount = harness.api.refreshCount
            try await Task.sleep(nanoseconds: 130_000_000)
            XCTAssertEqual(harness.api.refreshCount, refreshCount, cancellation)
            XCTAssertFalse(harness.controller.mediaConnected, cancellation)
        }
    }

    func testTransientRefreshFailuresUseTheSameFiniteBudget() async throws {
        let harness = VoiceRecoveryHarness(retryNanoseconds: 5_000_000)
        defer { harness.controller.close() }
        await harness.controller.activate()
        harness.api.refreshFails = true
        harness.media.eventHandler?(.failed)
        try await wait { harness.controller.phase == "error" }
        XCTAssertEqual(harness.api.refreshCount, 3)
        XCTAssertEqual(harness.media.connectCount, 1)
    }

    func testLateConnectFailureCannotOverwriteEndedOrUnauthenticatedState() async throws {
        for cancellation in ["end", "close", "authentication"] {
            let harness = VoiceRecoveryHarness(retryNanoseconds: 5_000_000)
            defer { harness.controller.close() }
            await harness.controller.activate()
            harness.media.failuresRemaining = 1
            harness.media.holdNextConnect = true
            harness.media.eventHandler?(.failed)
            try await wait { harness.media.connectCount == 2 }
            switch cancellation {
            case "end": await harness.controller.perform(.end)
            case "close": harness.controller.close()
            default:
                harness.controller.consume(InboundFrame.parse(#"{"type":"auth_required","reason":"expired"}"#)!)
            }
            let expectedPhase = harness.controller.phase
            harness.media.releaseConnect()
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(harness.controller.phase, expectedPhase, cancellation)
            XCTAssertEqual(harness.api.refreshCount, 1, cancellation)
            XCTAssertFalse(harness.controller.mediaConnected, cancellation)
        }
    }

    func testLateInitialConnectFailureCannotReactivateAfterEnd() async throws {
        let harness = VoiceRecoveryHarness(retryNanoseconds: 5_000_000)
        defer { harness.controller.close() }
        harness.media.failuresRemaining = 1
        harness.media.holdNextConnect = true
        let activation = Task { await harness.controller.activate() }
        try await wait { harness.media.connectCount == 1 }
        await harness.controller.perform(.end)
        harness.media.releaseConnect()
        await activation.value
        XCTAssertEqual(harness.controller.phase, "ended")
        XCTAssertEqual(harness.api.refreshCount, 0)
        XCTAssertFalse(harness.controller.mediaConnected)
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<250 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Voice recovery did not reach the expected state within its bounded test interval")
    }
}

@MainActor
private final class VoiceRecoveryHarness {
    let api = RecoveryVoiceAPI()
    let media = RecoveryVoiceMedia()
    let controller: AppleVoiceSessionController

    init(retryNanoseconds: UInt64) {
        controller = AppleVoiceSessionController(
            api: api, media: media,
            permissionProvider: {
                AppleVoiceMediaCapability(
                    hasMicrophone: true, hasAudioOutput: true,
                    microphonePermission: "authorized", fullDuplex: true)
            },
            audioRouteSnapshotProvider: { nil }, retryNanoseconds: retryNanoseconds,
            leaseRenewalNanoseconds: 60_000_000_000)
        controller.setFrameSender { _ in true }
        install()
    }

    func install(connection: String = RecoveryVoiceAPI.connection, bind: Bool = true) {
        controller.installUIConnection(
            token: "synthetic-access", serverBase: URL(string: "https://example.test")!,
            deviceId: RecoveryVoiceAPI.device, deviceKind: "ios",
            connectionGeneration: connection, visibleChatId: RecoveryVoiceAPI.chat)
        if bind {
            controller.consume(
                InboundFrame.parse(
                    """
                    {"type":"voice_control_binding","schema_version":"1","device_id":"\(RecoveryVoiceAPI.device)","connection_generation":"\(connection)","binding_id":"00000000-0000-4000-8000-00000000000a","binding":"synthetic-binding-value-000000000000","expires_at":"2099-07-31T12:10:00Z"}
                    """)!)
        }
    }
}

@MainActor
private final class RecoveryVoiceAPI: AppleVoiceControlAPI {
    static let device = "00000000-0000-4000-8000-000000000001"
    static let connection = "00000000-0000-4000-8000-000000000002"
    static let sessionId = "00000000-0000-4000-8000-000000000003"
    static let chat = "00000000-0000-4000-8000-000000000004"
    var refreshCount = 0
    var endCount = 0
    var refreshFails = false

    func start(binding: AppleVoiceUIBinding, activationId: String, capability: AppleVoiceMediaCapability) async
        -> AppleVoiceStartOutcome
    {
        .started(session(revision: 2), grant(revision: 2))
    }

    func takeover(
        binding: AppleVoiceUIBinding, activationId: String, target: AppleVoiceTakeoverTarget,
        capability: AppleVoiceMediaCapability
    ) async -> AppleVoiceStartOutcome {
        .failed("takeover_required", nil)
    }

    func update(binding: AppleVoiceUIBinding, session: AppleVoiceRestSession, fields: [String: JSONValue]) async
        -> AppleVoiceRestSession?
    { session }

    func refresh(binding: AppleVoiceUIBinding, session: AppleVoiceRestSession, refreshId: String) async
        -> AppleVoiceRefreshOutcome
    {
        refreshCount += 1
        if refreshFails { return .failed("network_interrupted", nil) }
        let revision = session.mediaGrantRevision + 1
        return .refreshed(self.session(revision: revision), grant(revision: revision))
    }

    func stopSpeech(binding: AppleVoiceUIBinding, session: AppleVoiceRestSession) async -> Bool { true }
    func consent(binding: AppleVoiceUIBinding, session: AppleVoiceRestSession, resultId: String, turnId: String) async
        -> Bool
    { true }
    func end(binding: AppleVoiceUIBinding, fence: AppleVoiceSessionFence) async -> Bool {
        endCount += 1
        return true
    }

    private func session(revision: Int) -> AppleVoiceRestSession {
        AppleVoiceRestSession(
            sessionId: Self.sessionId, deviceId: Self.device, deviceKind: "ios", transport: "livekit",
            ownerConnectionGeneration: Self.connection, visibleChatId: Self.chat, appliedVisibleChatId: Self.chat,
            generation: 1, mediaGrantRevision: revision, chatContextRevision: 3, appliedChatContextRevision: 3,
            chatContextSynced: true, state: "active", foregroundActive: true, foregroundReason: "foreground",
            speechMuted: false, microphoneEnabled: true, leaseExpiresAt: "2099-07-31T12:01:00Z")
    }

    private func grant(revision: Int) -> AppleLiveKitGrant {
        AppleLiveKitGrant(
            grantId: "grant-\(revision)", sessionId: Self.sessionId, generation: 1,
            mediaGrantRevision: revision, expiresAt: "2099-07-31T12:02:00Z",
            url: "wss://voice.example.test", joinToken: String(repeating: "a", count: 64),
            roomName: "voice-room", participantIdentity: "ios-client", workerIdentity: "voice-worker")
    }
}

@MainActor
private final class RecoveryVoiceMedia: AppleVoiceMediaClient {
    var eventHandler: ((AppleVoiceMediaEvent) -> Void)?
    var connectCount = 0
    var failuresRemaining = 0
    var emitsFailure = true
    var holdNextConnect = false
    private var connectContinuation: CheckedContinuation<Void, Never>?

    func connect(_ grant: AppleLiveKitGrant) async throws {
        connectCount += 1
        if holdNextConnect {
            holdNextConnect = false
            await withCheckedContinuation { connectContinuation = $0 }
        }
        guard failuresRemaining > 0 else { return }
        failuresRemaining -= 1
        if emitsFailure {
            eventHandler?(.failed)
            eventHandler?(.disconnected(unexpected: true))
        }
        throw URLError(.notConnectedToInternet)
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {}
    func authorize(_ announcement: VoiceAnnouncementMedia) -> Bool { true }
    func interruptPlayout() {}
    func disconnect() {}
    func releaseConnect() {
        connectContinuation?.resume()
        connectContinuation = nil
    }
}

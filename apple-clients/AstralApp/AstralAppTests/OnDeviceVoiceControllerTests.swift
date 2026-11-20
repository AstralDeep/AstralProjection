// Checks first-microphone consent, pack readiness, the model session pairing and lifecycle fences without requesting real microphone access.
// Conversation dispatch stays behind an explicitly injected kernel link, and the models, voice and pipeline are fakes.

import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
final class OnDeviceVoiceControllerTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }

    private func fixture(
        installed: Bool = false, voice: Bool = true, requestPermission: @escaping () async -> Bool = { true },
        makePipeline: @escaping OnDeviceVoiceController.PipelineFactory = { $0.pipeline(link: $1) }
    ) async throws -> VoicePackTestFixture {
        let made = try await VoicePackTestFixture.make(
            installed: installed, voice: voice, requestPermission: requestPermission, makePipeline: makePipeline)
        roots.append(made.root)
        return made
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition never held")
    }

    private func pipeline(_ audio: FakeDuplexAudio? = nil, link: VoiceKernelLink) -> VoicePipeline {
        VoicePipeline(audio: audio ?? FakeDuplexAudio(), transcriber: FakeTranscriber(), fastPath: nil, link: link)
    }

    func testFirstMicOffersTheExactSizeBeforePermissionsOrDownload() async throws {
        var permissions = 0
        let made = try await fixture(requestPermission: {
            permissions += 1
            return true
        })
        await made.controller.activate()
        XCTAssertTrue(made.controller.showingSetup)
        XCTAssertEqual(made.controller.downloadSize, made.store.sizeDescription)
        XCTAssertEqual(made.controller.downloadSize, ByteCountFormatter.string(fromByteCount: made.manifest.totalBytes, countStyle: .file))
        XCTAssertEqual(permissions, 0)
        XCTAssertEqual(made.store.state, .notInstalled)
        XCTAssertFalse(made.controller.isRunning)
        XCTAssertEqual(made.recorder.events, [])
    }

    func testAppMicrophoneNeverActivatesTheHostedVoiceController() async throws {
        let made = try await fixture()
        let api = FakeVoiceAPI()
        let legacy = AppleVoiceSessionController(api: api, media: FakeVoiceMedia())
        let model = AppModel(voiceController: legacy, onDeviceVoiceController: made.controller)
        await model.onDeviceVoice.activate()
        XCTAssertTrue(made.controller.showingSetup)
        XCTAssertEqual(api.startCount, 0)
        XCTAssertFalse(legacy.active)
    }

    func testInstalledPackWithoutConversationLinkRemainsUnavailable() async throws {
        var permissions = 0
        let made = try await fixture(
            installed: true,
            requestPermission: {
                permissions += 1
                return true
            })
        await made.controller.activate()
        XCTAssertEqual(permissions, 0)
        XCTAssertFalse(made.controller.isRunning)
        XCTAssertNotNil(made.controller.message)
        XCTAssertEqual(made.recorder.events, [])
    }

    func testMicStartsOnlyWithInstalledPackLinkAndPermissionAndPairsTheModelSession() async throws {
        let audio = FakeDuplexAudio()
        let made = try await fixture(installed: true, makePipeline: { [self] _, link in pipeline(audio, link: link) })
        made.controller.connect(link: FakeKernelLink())
        await made.controller.activate()
        XCTAssertTrue(made.controller.isRunning)
        XCTAssertTrue(audio.started)
        XCTAssertEqual(made.recorder.events, ["begin"])
        made.controller.suspend()
        XCTAssertFalse(made.controller.isRunning)
        XCTAssertTrue(audio.stopped)
        try await settle { made.recorder.events == ["begin", "end"] }
    }

    func testAModelOnlyPackStartsVoiceAndSpeaksThroughTheSystemVoice() async throws {
        let audio = FakeDuplexAudio()
        let made = try await fixture(installed: true, makePipeline: { [self] _, link in pipeline(audio, link: link) })
        await made.removeVoiceUnit()
        XCTAssertEqual(made.store.state, .modelOnly(.pending))
        made.controller.connect(link: FakeKernelLink())
        await made.controller.activate()
        XCTAssertTrue(made.controller.isRunning)
        XCTAssertTrue(audio.started)
        made.controller.stop()
    }

    func testADeviceWithoutLocalVoiceStartsFromTheModelFilesAlone() async throws {
        let audio = FakeDuplexAudio()
        let made = try await fixture(
            installed: true, voice: false, makePipeline: { [self] _, link in pipeline(audio, link: link) })
        XCTAssertEqual(made.store.state, .installed)
        made.controller.connect(link: FakeKernelLink())
        await made.controller.activate()
        XCTAssertTrue(made.controller.isRunning)
        made.controller.stop()
    }

    func testMicrophoneToggleStopsAnActiveSessionWithoutRequestingPermissionAgain() async throws {
        let audio = FakeDuplexAudio()
        var permissions = 0
        let made = try await fixture(
            installed: true,
            requestPermission: {
                permissions += 1
                return true
            }, makePipeline: { [self] _, link in pipeline(audio, link: link) })
        made.controller.connect(link: FakeKernelLink())
        await made.controller.toggle()
        XCTAssertTrue(made.controller.isRunning)
        await made.controller.toggle()
        XCTAssertFalse(made.controller.isRunning)
        XCTAssertTrue(audio.stopped)
        XCTAssertEqual(permissions, 1)
        try await settle { made.recorder.events == ["begin", "end"] }
    }

    func testDeniedMicrophoneNeverBuildsThePipelineOrOpensTheModelSession() async throws {
        var loads = 0
        let made = try await fixture(
            installed: true, requestPermission: { false },
            makePipeline: { [self] _, link in
                loads += 1
                return pipeline(link: link)
            })
        made.controller.connect(link: FakeKernelLink())
        await made.controller.activate()
        XCTAssertEqual(loads, 0)
        XCTAssertFalse(made.controller.isRunning)
        XCTAssertTrue(made.controller.showingSetup)
        XCTAssertEqual(made.controller.message, "Microphone access is off. Allow it in Settings to use voice.")
        XCTAssertEqual(made.recorder.events, [])
    }

    func testInactiveStartExplainsWhyItCannotCaptureWithoutRequestingPermission() async throws {
        var permissionRequests = 0
        let made = try await fixture(
            installed: true,
            requestPermission: {
                permissionRequests += 1
                return true
            })
        made.controller.suspend()
        await made.controller.activate()
        XCTAssertEqual(permissionRequests, 0)
        XCTAssertEqual(made.controller.message, "Return to this app, then start voice again.")
        XCTAssertTrue(made.controller.showingSetup)
        XCTAssertFalse(made.controller.isRunning)
    }

    func testModelLoadFailureHasNoFallbackAndClosesTheModelSession() async throws {
        let made = try await fixture(installed: true, makePipeline: { _, _ in throw CocoaError(.fileReadCorruptFile) })
        made.controller.connect(link: FakeKernelLink())
        await made.controller.activate()
        XCTAssertFalse(made.controller.isRunning)
        XCTAssertFalse(made.controller.isPreparing)
        XCTAssertEqual(made.controller.message, "The voice model couldn't start. Try downloading it again.")
        try await settle { made.recorder.events == ["begin", "end"] }
    }

    func testAudioStartFailureDoesNotAskForAnotherDownloadAndClosesTheModelSession() async throws {
        let audio = FakeDuplexAudio()
        audio.startError = .audioStartFailed
        let made = try await fixture(installed: true, makePipeline: { [self] _, link in pipeline(audio, link: link) })
        made.controller.connect(link: FakeKernelLink())
        await made.controller.activate()
        XCTAssertFalse(made.controller.isRunning)
        XCTAssertTrue(made.controller.showingSetup)
        XCTAssertEqual(
            made.controller.message,
            "The microphone and speaker couldn't start. Check the selected audio devices, then try again.")
        XCTAssertNotNil(made.store.modelDirectory)
        try await settle { made.recorder.events == ["begin", "end"] }
    }

    func testConversationPreparationFailureNeverStartsTheAudioGraphOrTheModels() async throws {
        let link = FakeKernelLink()
        link.preparationError = MeshKernelError.unavailable("Choose a chat before starting voice.")
        let audio = FakeDuplexAudio()
        var loads = 0
        let made = try await fixture(
            installed: true,
            makePipeline: { [self] _, link in
                loads += 1
                return pipeline(audio, link: link)
            })
        made.controller.connect(link: link)
        await made.controller.activate()
        XCTAssertEqual(link.preparations, 1)
        XCTAssertEqual(loads, 0)
        XCTAssertFalse(audio.started)
        XCTAssertFalse(made.controller.isRunning)
        XCTAssertTrue(made.controller.showingSetup)
        XCTAssertEqual(made.controller.message, "Choose a chat before starting voice.")
        XCTAssertEqual(made.recorder.events, [])
    }

    func testFailureFromARetiredPipelineCannotStopItsReplacement() async throws {
        var pipelines: [VoicePipeline] = []
        var outputs: [FakeDuplexAudio] = []
        let made = try await fixture(
            installed: true,
            makePipeline: { [self] _, link in
                let output = FakeDuplexAudio()
                let made = pipeline(output, link: link)
                outputs.append(output)
                pipelines.append(made)
                return made
            })
        made.controller.connect(link: FakeKernelLink())
        await made.controller.activate()
        made.controller.stop()
        await made.controller.activate()
        XCTAssertTrue(made.controller.isRunning)
        pipelines[0].onFailure?("audio_capture_format_unavailable")
        XCTAssertTrue(made.controller.isRunning)
        XCTAssertFalse(outputs[1].stopped)
        pipelines[1].onFailure?("voice_synthesis_failed")
        XCTAssertFalse(made.controller.isRunning)
        XCTAssertTrue(outputs[1].stopped)
        XCTAssertTrue(made.controller.showingSetup)
        try await settle { made.recorder.events.filter { $0 == "end" }.count == 2 }
        XCTAssertEqual(made.recorder.events.filter { $0 == "begin" }.count, 2)
    }

    func testForegroundRestorationDoesNotClearLockOrAudioInterruption() async throws {
        let made = try await fixture(installed: true, makePipeline: { [self] _, link in pipeline(link: link) })
        made.controller.connect(link: FakeKernelLink())
        made.controller.sessionLocked()
        made.controller.resume()
        await made.controller.activate()
        XCTAssertFalse(made.controller.isRunning)
        made.controller.sessionUnlocked()
        made.controller.interruptionBegan()
        made.controller.resume()
        await made.controller.activate()
        XCTAssertFalse(made.controller.isRunning)
        made.controller.interruptionEnded()
        XCTAssertFalse(made.controller.isRunning)
        await made.controller.activate()
        XCTAssertTrue(made.controller.isRunning)
        made.controller.stop()
    }

    func testStoppingWhileTheModelsAreStillOpeningClosesTheSessionOnce() async throws {
        let gate = OpenGate()
        let made = try await VoicePackTestFixture.make(
            installed: true, makePipeline: { [self] _, link in pipeline(link: link) },
            parts: { recorder in
                VoiceSessionParts(
                    recognizer: SilentRecognizer(), textGenerator: SilentGenerator(), speech: SilentSpeech(),
                    begin: {
                        recorder.record("begin")
                        await gate.wait()
                    }, end: { recorder.record("end") }, unload: { recorder.record("unload") })
            })
        roots.append(made.root)
        made.controller.connect(link: FakeKernelLink())
        let start = Task { await made.controller.activate() }
        try await settle { made.recorder.events == ["begin"] }
        made.controller.stop()
        await gate.open()
        await start.value
        try await settle { made.recorder.events.contains("end") }
        XCTAssertEqual(made.recorder.events, ["begin", "end"])
        XCTAssertFalse(made.controller.isRunning)
        XCTAssertFalse(made.controller.isPreparing)
    }

    func testRemovingThePackStopsVoiceUnloadsTheModelsAndDeletesTheFiles() async throws {
        let audio = FakeDuplexAudio()
        let made = try await fixture(installed: true, makePipeline: { [self] _, link in pipeline(audio, link: link) })
        made.controller.connect(link: FakeKernelLink())
        await made.controller.activate()
        XCTAssertTrue(made.controller.isRunning)
        await made.controller.deleteModel()
        XCTAssertFalse(made.controller.isRunning)
        XCTAssertTrue(audio.stopped)
        XCTAssertEqual(made.store.state, .notInstalled)
        XCTAssertNil(made.store.modelDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.root.appendingPathComponent("model").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.root.appendingPathComponent("voice").path))
        let events = made.recorder.events
        XCTAssertEqual(events.filter { $0 == "unload" }.count, 2)
        XCTAssertEqual(events.last, "unload")
    }
}

private actor OpenGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

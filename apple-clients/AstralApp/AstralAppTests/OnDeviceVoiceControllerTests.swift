// Checks first-microphone consent, model readiness and lifecycle fences without requesting real microphone access.
// Conversation dispatch stays behind an explicitly injected kernel link.

import AstralCore
@testable import AstralDeep
import CryptoKit
import XCTest

@MainActor
final class OnDeviceVoiceControllerTests: XCTestCase {
    private var root: URL!
    private let device = VoiceDeviceProfile(
        platform: .mac, isAppleSilicon: true, isSimulator: false, physicalMemoryBytes: 16 << 30)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try FileManager.default.removeItem(at: root) }

    private func modelStore(installed: Bool = false) async throws -> VoiceModelStore {
        let bytes = Data("x".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let manifest = VoiceModelManifest(
            displayName: "LFM3-Audio-2B (3-bit)", format: VoiceModelManifest.supportedFormat,
            id: "lfm3-audio-2b-3bit-mlx", license: "LFM Open License v1.0",
            repository: "Kentucky-Open-Science/LFM3-Audio-2B-MLX-3bit", revision: "main", runtime: "mlx",
            source: "LiquidAI/LFM3-Audio-2B-MLX-bf16", totalBytes: Int64(VoiceModelManifest.requiredFiles.count),
            files: VoiceModelManifest.requiredFiles.map { .init(path: $0, bytes: 1, sha256: digest) })
        let store = VoiceModelStore(manifest: manifest, root: root, device: device, freeSpace: { _ in .max })
        if installed {
            for file in manifest.files {
                let url = store.stagingDirectory.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: url)
            }
            await store.startDownload(allowMetered: false)
        }
        return store
    }

    func testFirstMicOffersTheExactSizeBeforePermissionsOrDownload() async throws {
        let store = try await modelStore()
        var permissions = 0
        let controller = OnDeviceVoiceController(
            store: store,
            requestPermission: {
                permissions += 1
                return true
            })
        await controller.activate()
        XCTAssertTrue(controller.showingSetup)
        XCTAssertEqual(controller.downloadSize, store.manifest.sizeDescription)
        XCTAssertEqual(permissions, 0)
        XCTAssertEqual(store.state, .notInstalled)
        XCTAssertFalse(controller.isRunning)
    }

    func testAppMicrophoneNeverActivatesTheHostedVoiceController() async throws {
        let store = try await modelStore()
        let api = FakeVoiceAPI()
        let legacy = AppleVoiceSessionController(api: api, media: FakeVoiceMedia())
        let controller = OnDeviceVoiceController(store: store)
        let model = AppModel(
            tokenStore: InMemoryTokenStore(), voiceController: legacy, onDeviceVoiceController: controller)
        await model.activateVoice()
        XCTAssertTrue(controller.showingSetup)
        XCTAssertEqual(api.startCount, 0)
        XCTAssertFalse(legacy.active)
    }

    func testInstalledModelWithoutConversationLinkRemainsUnavailable() async throws {
        let store = try await modelStore(installed: true)
        var permissions = 0
        let controller = OnDeviceVoiceController(
            store: store,
            requestPermission: {
                permissions += 1
                return true
            })
        await controller.activate()
        XCTAssertEqual(permissions, 0)
        XCTAssertFalse(controller.isRunning)
        XCTAssertNotNil(controller.message)
    }

    func testMicStartsOnlyWithInstalledModelLinkAndPermission() async throws {
        let store = try await modelStore(installed: true)
        let audio = FakeDuplexAudio()
        let link = FakeKernelLink()
        let controller = OnDeviceVoiceController(
            store: store, requestPermission: { true },
            makePipeline: { _, link in
                VoicePipeline(audio: audio, transcriber: FakeTranscriber(), fastPath: nil, link: link)
            })
        controller.connect(link: link)
        await controller.activate()
        XCTAssertTrue(controller.isRunning)
        XCTAssertTrue(audio.started)
        controller.suspend()
        XCTAssertFalse(controller.isRunning)
        XCTAssertTrue(audio.stopped)
    }

    func testMicrophoneToggleStopsAnActiveSessionWithoutRequestingPermissionAgain() async throws {
        let store = try await modelStore(installed: true)
        let audio = FakeDuplexAudio()
        var permissions = 0
        let controller = OnDeviceVoiceController(
            store: store,
            requestPermission: {
                permissions += 1
                return true
            },
            makePipeline: { _, link in
                VoicePipeline(audio: audio, transcriber: FakeTranscriber(), fastPath: nil, link: link)
            })
        controller.connect(link: FakeKernelLink())
        await controller.toggle()
        XCTAssertTrue(controller.isRunning)
        await controller.toggle()
        XCTAssertFalse(controller.isRunning)
        XCTAssertTrue(audio.stopped)
        XCTAssertEqual(permissions, 1)
    }

    func testDeniedMicrophoneNeverBuildsThePipeline() async throws {
        let store = try await modelStore(installed: true)
        var loads = 0
        let controller = OnDeviceVoiceController(
            store: store, requestPermission: { false },
            makePipeline: { _, link in
                loads += 1
                return VoicePipeline(
                    audio: FakeDuplexAudio(), transcriber: FakeTranscriber(), fastPath: nil, link: link)
            })
        controller.connect(link: FakeKernelLink())
        await controller.activate()
        XCTAssertEqual(loads, 0)
        XCTAssertFalse(controller.isRunning)
        XCTAssertTrue(controller.showingSetup)
        XCTAssertEqual(controller.message, "Microphone access is off. Allow it in Settings to use voice.")
    }

    func testInactiveStartExplainsWhyItCannotCaptureWithoutRequestingPermission() async throws {
        let fixture = try await VoiceModelTestFixture.installed()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var permissionRequests = 0
        let controller = OnDeviceVoiceController(
            store: fixture.controller.store,
            requestPermission: {
                permissionRequests += 1
                return true
            })
        controller.suspend()
        await controller.activate()
        XCTAssertEqual(permissionRequests, 0)
        XCTAssertEqual(controller.message, "Return to this app, then start voice again.")
        XCTAssertTrue(controller.showingSetup)
        XCTAssertFalse(controller.isRunning)
    }

    func testModelLoadFailureHasNoFallback() async throws {
        let store = try await modelStore(installed: true)
        let controller = OnDeviceVoiceController(
            store: store, requestPermission: { true }, makePipeline: { _, _ in throw CocoaError(.fileReadCorruptFile) })
        controller.connect(link: FakeKernelLink())
        await controller.activate()
        XCTAssertFalse(controller.isRunning)
        XCTAssertFalse(controller.isPreparing)
        XCTAssertEqual(controller.message, "The voice model could not start. Try downloading it again.")
    }

    func testAudioStartFailureDoesNotAskForAnotherModelDownload() async throws {
        let store = try await modelStore(installed: true)
        let audio = FakeDuplexAudio()
        audio.startError = .audioStartFailed
        let controller = OnDeviceVoiceController(
            store: store, requestPermission: { true },
            makePipeline: { _, link in
                VoicePipeline(audio: audio, transcriber: FakeTranscriber(), fastPath: nil, link: link)
            })
        controller.connect(link: FakeKernelLink())
        await controller.activate()
        XCTAssertFalse(controller.isRunning)
        XCTAssertTrue(controller.showingSetup)
        XCTAssertEqual(
            controller.message,
            "The microphone and speaker could not start. Check the selected audio devices, then try again.")
        XCTAssertNotNil(store.installedDirectory)
    }

    func testConversationPreparationFailureNeverStartsTheAudioGraph() async throws {
        let store = try await modelStore(installed: true)
        let link = FakeKernelLink()
        link.preparationError = MeshKernelError.unavailable("Choose a chat before starting voice.")
        let audio = FakeDuplexAudio()
        var loads = 0
        let controller = OnDeviceVoiceController(
            store: store, requestPermission: { true },
            makePipeline: { _, link in
                loads += 1
                return VoicePipeline(audio: audio, transcriber: FakeTranscriber(), fastPath: nil, link: link)
            })
        controller.connect(link: link)
        await controller.activate()
        XCTAssertEqual(link.preparations, 1)
        XCTAssertEqual(loads, 0)
        XCTAssertFalse(audio.started)
        XCTAssertFalse(controller.isRunning)
        XCTAssertTrue(controller.showingSetup)
        XCTAssertEqual(controller.message, "Choose a chat before starting voice.")
    }

    func testFailureFromARetiredPipelineCannotStopItsReplacement() async throws {
        let store = try await modelStore(installed: true)
        var pipelines: [VoicePipeline] = []
        var outputs: [FakeDuplexAudio] = []
        let controller = OnDeviceVoiceController(
            store: store, requestPermission: { true },
            makePipeline: { _, link in
                let output = FakeDuplexAudio()
                let pipeline = VoicePipeline(audio: output, transcriber: FakeTranscriber(), fastPath: nil, link: link)
                outputs.append(output)
                pipelines.append(pipeline)
                return pipeline
            })
        controller.connect(link: FakeKernelLink())
        await controller.activate()
        controller.stop()
        await controller.activate()
        XCTAssertTrue(controller.isRunning)
        pipelines[0].onFailure?("audio_capture_format_unavailable")
        XCTAssertTrue(controller.isRunning)
        XCTAssertFalse(outputs[1].stopped)
        pipelines[1].onFailure?("voice_synthesis_failed")
        XCTAssertFalse(controller.isRunning)
        XCTAssertTrue(outputs[1].stopped)
        XCTAssertTrue(controller.showingSetup)
    }

    func testForegroundRestorationDoesNotClearLockOrAudioInterruption() async throws {
        let store = try await modelStore(installed: true)
        let controller = OnDeviceVoiceController(
            store: store, requestPermission: { true },
            makePipeline: { _, link in
                VoicePipeline(audio: FakeDuplexAudio(), transcriber: FakeTranscriber(), fastPath: nil, link: link)
            })
        controller.connect(link: FakeKernelLink())
        controller.sessionLocked()
        controller.resume()
        await controller.activate()
        XCTAssertFalse(controller.isRunning)
        controller.sessionUnlocked()
        controller.interruptionBegan()
        controller.resume()
        await controller.activate()
        XCTAssertFalse(controller.isRunning)
        controller.interruptionEnded()
        XCTAssertFalse(controller.isRunning)
        await controller.activate()
        XCTAssertTrue(controller.isRunning)
        controller.stop()
    }
}

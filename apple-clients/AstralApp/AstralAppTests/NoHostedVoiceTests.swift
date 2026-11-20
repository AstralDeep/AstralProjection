// Proves every voice entry point of the app model leaves the hosted voice controller, its REST client and its media client idle.
// A URLProtocol recorder fails every HTTP request, and the on-device session is driven with the existing fakes and no microphone.

import AVFoundation
import AstralCore
import CryptoKit
import XCTest

@testable import AstralDeep

final class HostedVoiceRequestRecorder: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [String] = []

    static var requests: [String] { lock.withLock { seen } }
    static func reset() { lock.withLock { seen.removeAll() } }

    override class func canInit(with request: URLRequest) -> Bool {
        ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.withLock { Self.seen.append(path) }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HostedVoiceRequestRecorder.self]
        return URLSession(configuration: configuration)
    }
}

@MainActor
private final class PipelineBox {
    var pipeline: VoicePipeline?
}

@MainActor
private final class VoiceHarness {
    let root: URL
    let suite = UUID().uuidString
    let api = FakeVoiceAPI()
    let media = FakeVoiceMedia()
    let audio = FakeDuplexAudio()
    let transcriber = FakeTranscriber()
    let link = FakeKernelLink()
    let clock = ManualVoiceClock()
    let box = PipelineBox()
    let permissions = PermissionCounter()
    let hosted: AppleVoiceSessionController
    let onDevice: OnDeviceVoiceController
    let model: AppModel
    private(set) var connection = ""

    init(realRest: Bool = false) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        let store = try await Self.installedStore(root: root)
        let audio = audio
        let transcriber = transcriber
        let clock = clock
        let box = box
        let permissions = permissions
        let link = link
        let onDevice = OnDeviceVoiceController(
            store: store, requestPermission: { true },
            makePipeline: { _, link in
                let pipeline = VoicePipeline(
                    audio: audio, transcriber: transcriber, fastPath: nil, link: link, clock: clock)
                box.pipeline = pipeline
                return pipeline
            })
        onDevice.connect(link: link)
        let control: AppleVoiceControlAPI =
            realRest ? RetiredAppleVoiceControlAPI() : api
        let hosted = AppleVoiceSessionController(
            api: control, media: media,
            permissionProvider: {
                permissions.count += 1
                return AppleVoiceMediaCapability(
                    hasMicrophone: true, hasAudioOutput: true, microphonePermission: "authorized",
                    fullDuplex: true)
            })
        self.onDevice = onDevice
        self.hosted = hosted
        #if os(macOS)
            model = AppModel(
                defaults: UserDefaults(suiteName: suite)!,
                voiceController: hosted, onDeviceVoiceController: onDevice)
        #else
            model = AppModel(voiceController: hosted, onDeviceVoiceController: onDevice)
        #endif
    }

    func tearDown() {
        onDevice.disconnect()
        hosted.close()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func assertHostedIdle(
        _ context: String, lifecycle: Bool = false, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(api.startCount, 0, "\(context): hosted start", file: file, line: line)
        XCTAssertEqual(api.takeoverCount, 0, "\(context): hosted takeover", file: file, line: line)
        XCTAssertEqual(
            api.startLocalCount + api.takeoverLocalCount, 0, "\(context): local start", file: file, line: line)
        XCTAssertEqual(
            api.updates.count + api.localUpdates.count, 0, "\(context): session update", file: file, line: line)
        XCTAssertEqual(
            api.refreshIds.count + api.endCount + api.stopCount, 0, "\(context): refresh or end", file: file, line: line
        )
        XCTAssertEqual(
            api.capabilityCount + api.consentCount, 0, "\(context): capability or consent", file: file, line: line)
        XCTAssertEqual(media.connectCount, 0, "\(context): media connect", file: file, line: line)
        XCTAssertTrue(media.microphoneValues.isEmpty, "\(context): media microphone", file: file, line: line)
        XCTAssertTrue(media.authorized.isEmpty, "\(context): media authorization", file: file, line: line)
        if !lifecycle {
            XCTAssertEqual(media.interruptionCount, 0, "\(context): media playout", file: file, line: line)
            XCTAssertFalse(hosted.active, "\(context): hosted session active", file: file, line: line)
        }
        XCTAssertEqual(permissions.count, 0, "\(context): hosted capability request", file: file, line: line)
        XCTAssertFalse(hosted.mediaConnected, "\(context): hosted media connected", file: file, line: line)
        XCTAssertEqual(
            HostedVoiceRequestRecorder.requests, [], "\(context): outbound HTTP request", file: file, line: line)
    }

    func speakOneTurn(_ text: String) throws {
        let pipeline = try XCTUnwrap(box.pipeline)
        pipeline.handleVoiceActivity(true)
        pipeline.handleRecognizer(.partial(text))
        pipeline.handleVoiceActivity(false)
        clock.advance(0.7)
        pipeline.tick()
        pipeline.handleRecognizer(.final(text))
    }

    private static func installedStore(root: URL) async throws -> VoiceModelStore {
        let bytes = Data("x".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let manifest = VoiceModelManifest(
            displayName: "LFM3-Audio-2B (3-bit)", format: VoiceModelManifest.supportedFormat,
            id: "lfm3-audio-2b-3bit-mlx", license: "LFM Open License v1.0",
            repository: "Kentucky-Open-Science/LFM3-Audio-2B-MLX-3bit", revision: "main", runtime: "mlx",
            source: "LiquidAI/LFM3-Audio-2B-MLX-bf16", totalBytes: Int64(VoiceModelManifest.requiredFiles.count),
            files: VoiceModelManifest.requiredFiles.map { .init(path: $0, bytes: 1, sha256: digest) })
        let device = VoiceDeviceProfile(
            platform: .mac, isAppleSilicon: true, isSimulator: false, physicalMemoryBytes: 16 << 30)
        let store = VoiceModelStore(manifest: manifest, root: root, device: device, freeSpace: { _ in .max })
        for file in manifest.files {
            let url = store.stagingDirectory.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        await store.startDownload(allowMetered: false)
        guard store.state == .installed else { throw CocoaError(.fileWriteUnknown) }
        return store
    }
}

@MainActor
private final class PermissionCounter {
    var count = 0
}

@MainActor
final class NoHostedVoiceTests: XCTestCase {
    override func setUp() async throws {
        HostedVoiceRequestRecorder.reset()
        URLProtocol.registerClass(HostedVoiceRequestRecorder.self)
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(HostedVoiceRequestRecorder.self)
        HostedVoiceRequestRecorder.reset()
    }

    func testTheRecorderSeesAndFailsEveryHTTPRequest() async throws {
        for path in ["/api/voice/sessions", "/ordinary-speech-endpoint"] {
            let url = try XCTUnwrap(URL(string: "https://voice.example.test" + path))
            for session in [URLSession.shared, HostedVoiceRequestRecorder.session] {
                do {
                    _ = try await session.data(from: url)
                    XCTFail("an outbound HTTP request must not succeed")
                } catch {
                    XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
                }
            }
        }
        XCTAssertEqual(
            HostedVoiceRequestRecorder.requests,
            ["/api/voice/sessions", "/api/voice/sessions", "/ordinary-speech-endpoint", "/ordinary-speech-endpoint"])
        HostedVoiceRequestRecorder.reset()
    }

    func testTheAutomaticVoiceSwitchRendersLocallyAndNeverRequestsAHostedEndpoint() async throws {
        let renderer = ScriptedVoiceRenderer(voices: [
            SystemVoiceDescriptor(
                identifier: "en", language: "en-US", quality: .standard, isPersonal: false, isNovelty: false,
                isLocaleDefault: true)
        ])
        let automatic = AutomaticVoiceSpeech(
            local: LocalVoiceSpeech(synthesizer: FakeSpeechSynthesizer()) { nil },
            system: SystemVoiceSpeech(language: { .english }, renderer: renderer), language: { .english })
        let stream = try await automatic.speak("hello")
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 22_050, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 8
        renderer.emit(buffer)
        buffer.frameLength = 0
        renderer.emit(buffer)
        var frames = 0
        for try await part in stream { frames += part.samples.count }
        XCTAssertEqual(frames, 8)
        XCTAssertEqual(HostedVoiceRequestRecorder.requests, [])
    }

    func testActivateVoiceStartsOnlyTheOnDevicePipeline() async throws {
        let harness = try await VoiceHarness()
        defer { harness.tearDown() }
        await harness.model.onDeviceVoice.activate()
        XCTAssertTrue(harness.onDevice.isRunning)
        XCTAssertTrue(harness.audio.started)
        harness.assertHostedIdle("activateVoice")
    }

    func testActivateVoiceBeforeTheModelIsInstalledNeverReachesTheHostedController() async throws {
        let api = FakeVoiceAPI()
        let media = FakeVoiceMedia()
        let hosted = AppleVoiceSessionController(api: api, media: media)
        let onDevice = OnDeviceVoiceController(store: nil)
        let model = AppModel(
            voiceController: hosted, onDeviceVoiceController: onDevice)
        await model.onDeviceVoice.activate()
        XCTAssertFalse(onDevice.isRunning)
        XCTAssertEqual(api.startCount + api.takeoverCount + api.startLocalCount + api.endCount, 0)
        XCTAssertEqual(media.connectCount, 0)
        XCTAssertFalse(hosted.active)
        XCTAssertEqual(HostedVoiceRequestRecorder.requests, [])
    }

    func testSceneAndAudioLifecycleEventsNeverStartTheHostedController() async throws {
        let harness = try await VoiceHarness()
        defer { harness.tearDown() }
        await harness.model.onDeviceVoice.activate()
        harness.model.voiceSceneBecameInactive()
        harness.model.voiceSceneBecameActive()
        harness.model.voiceAudioSessionInterrupted()
        harness.model.voiceAudioSessionInterruptionEnded()
        harness.model.voiceAudioRouteChanged()
        harness.model.voiceAudioEngineConfigurationChanged()
        harness.model.voiceSessionLocked()
        harness.model.voiceSessionUnlocked()
        for _ in 0..<10 { await Task.yield() }
        harness.assertHostedIdle("lifecycle", lifecycle: true)
        harness.model.voiceApplicationWillTerminate()
        harness.assertHostedIdle("termination", lifecycle: true)
    }

    func testAnOnDeviceSessionDrivenWithFakesNeverRequestsApiVoice() async throws {
        let harness = try await VoiceHarness(realRest: true)
        defer { harness.tearDown() }
        await harness.model.onDeviceVoice.activate()
        XCTAssertTrue(harness.onDevice.isRunning)
        try harness.speakOneTurn("what is on my calendar")
        XCTAssertEqual(harness.link.turns.map(\.text), ["what is on my calendar"])
        harness.model.voiceAudioSessionInterrupted()
        harness.model.voiceAudioSessionInterruptionEnded()
        harness.model.onDeviceVoice.stop()
        await harness.model.onDeviceVoice.activate()
        try harness.speakOneTurn("and tomorrow")
        harness.onDevice.stop()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(harness.link.turns.count, 2)
        XCTAssertEqual(HostedVoiceRequestRecorder.requests, [])
        harness.assertHostedIdle("on-device session", lifecycle: true)
    }

    #if os(macOS)
        func testMacPushToTalkCapturesOnDeviceAndNeverTouchesTheHostedController() async throws {
            let harness = try await VoiceHarness(realRest: true)
            defer { harness.tearDown() }
            let pipeline = VoicePipeline(
                audio: harness.audio, transcriber: harness.transcriber, fastPath: nil, link: harness.link,
                clock: harness.clock)
            try pipeline.start(trigger: .pushToTalk, mode: .pushToTalk)
            let monitor = MacPushToTalkKeyMonitor(
                onPress: { pipeline.beginPushToTalk() }, onRelease: { pipeline.endPushToTalk() })
            monitor.handle(keyCode: PushToTalkKeyEvaluator.rightOptionKeyCode, isPressed: true)
            XCTAssertEqual(harness.transcriber.begun, 1)
            pipeline.handleRecognizer(.partial("open my notes"))
            monitor.handle(keyCode: PushToTalkKeyEvaluator.rightOptionKeyCode, isPressed: false)
            XCTAssertEqual(harness.transcriber.ended, 1)
            pipeline.handleRecognizer(.final("Open my notes."))
            XCTAssertEqual(harness.link.turns.map(\.text), ["Open my notes."])
            pipeline.stop()
            harness.assertHostedIdle("push to talk")
        }
    #endif
}

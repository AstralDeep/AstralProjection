// Owns the first-microphone pack offer and starts a voice pipeline only after installation, permission and conversation readiness.
// AppModel supplies the current kernel link; lifecycle changes retire capture, fence any pending model load and close the model session.

import AVFoundation
import Foundation
import OSLog
import Observation

@MainActor
@Observable
final class OnDeviceVoiceController {
    private static let log = Logger(subsystem: "com.personalailabs.astraldeep.voice", category: "controller")
    let store: VoicePackStore?
    var showingSetup = false
    var showingMeteredConfirmation = false
    private(set) var isRunning = false
    private(set) var isPreparing = false
    private(set) var message: String?
    var onSessionStopped: (() -> Void)?
    var onTranscript: ((String, Bool) -> Void)?
    @ObservationIgnored private let requestPermission: () async -> Bool
    @ObservationIgnored private let parts: VoiceSessionParts
    @ObservationIgnored private let makePipeline: PipelineFactory
    @ObservationIgnored private var sessionOpen = false
    @ObservationIgnored private var link: VoiceKernelLink?
    @ObservationIgnored private var pipeline: VoicePipeline?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var interrupted = false
    @ObservationIgnored private var locked = false
    @ObservationIgnored private var companion = false

    typealias PipelineFactory = @MainActor (VoiceSessionParts, VoiceKernelLink) async throws -> VoicePipeline

    init(
        store: VoicePackStore?, parts: VoiceSessionParts,
        requestPermission: @escaping () async -> Bool = OnDeviceVoiceController.microphonePermission,
        makePipeline: @escaping PipelineFactory = { $0.pipeline(link: $1) }
    ) {
        self.store = store
        self.parts = parts
        self.requestPermission = requestPermission
        self.makePipeline = makePipeline
        if store == nil { message = VoiceModelFailure.manifestUnavailable.message }
    }

    convenience init() {
        let manifest = try? VoicePackManifest.bundled()
        let store = manifest.map { VoicePackStore(manifest: $0, root: VoicePackStore.defaultRoot()) }
        self.init(
            store: store, parts: .standard(folder: { await MainActor.run { store?.voicePackDirectory } }))
    }

    var downloadSize: String? { store?.sizeDescription }
    var conversationReady: Bool { link != nil }
    private var eligible: Bool { foreground && !interrupted && !locked }

    func connect(link: VoiceKernelLink) {
        stop()
        self.link = link
        message = nil
    }

    func disconnect() {
        stop()
        link = nil
    }

    func activate() async {
        if companion { stop() }
        await start(makePipeline: makePipeline, needsPhoneMicrophone: true)
    }

    func activateForPairedWatch(makePipeline: @escaping PipelineFactory) async {
        stop()
        companion = true
        await start(makePipeline: makePipeline, needsPhoneMicrophone: false)
    }

    private func start(makePipeline: @escaping PipelineFactory, needsPhoneMicrophone: Bool) async {
        Self.log.info(
            "voice_start requested foreground=\(self.foreground, privacy: .public) interrupted=\(self.interrupted, privacy: .public) locked=\(self.locked, privacy: .public) preparing=\(self.isPreparing, privacy: .public) running=\(self.isRunning, privacy: .public)"
        )
        guard !isPreparing, !isRunning else { return }
        guard eligible else {
            message =
                locked
                ? "Unlock this device, then start voice again."
                : interrupted
                    ? "An audio interruption paused voice. Try again when it ends."
                    : "Return to this app, then start voice again."
            showingSetup = true
            return
        }
        guard let store else {
            showingSetup = true
            return
        }
        switch store.state {
        case .unsupported(let reason):
            message = reason.message
            showingSetup = true
            return
        case .notInstalled, .failed, .downloading:
            showingSetup = true
            return
        case .installed, .modelOnly: break
        }
        guard let link else {
            message = "Voice isn't ready in this conversation yet."
            showingSetup = true
            return
        }
        generation &+= 1
        let attempt = generation
        isPreparing = true
        message = "Preparing voice…"
        defer { if generation == attempt { isPreparing = false } }
        await store.refresh()
        Self.log.info(
            "voice_start verified_model installed=\(store.modelDirectory != nil, privacy: .public) current=\(self.generation == attempt, privacy: .public) eligible=\(self.eligible, privacy: .public)"
        )
        guard generation == attempt, eligible, !Task.isCancelled else { return }
        guard store.modelDirectory != nil else {
            message = "The voice model needs to be downloaded again."
            showingSetup = true
            return
        }
        let permitted = needsPhoneMicrophone ? await requestPermission() : true
        Self.log.info(
            "voice_start permission granted=\(permitted, privacy: .public) current=\(self.generation == attempt, privacy: .public) eligible=\(self.eligible, privacy: .public)"
        )
        guard permitted else {
            if generation == attempt {
                message = "Microphone access is off. Allow it in Settings to use voice."
                showingSetup = true
            }
            return
        }
        guard generation == attempt, eligible, !Task.isCancelled else { return }
        do {
            try await link.prepareForOwnerSession()
            guard generation == attempt, eligible, !Task.isCancelled else { return }
            sessionOpen = true
            await parts.begin()
            guard generation == attempt, eligible, !Task.isCancelled else {
                closeSession()
                return
            }
            let prepared = try await makePipeline(parts, link)
            Self.log.info(
                "voice_start pipeline_prepared current=\(self.generation == attempt, privacy: .public) eligible=\(self.eligible, privacy: .public)"
            )
            guard generation == attempt, eligible, !Task.isCancelled else {
                prepared.stop()
                closeSession()
                return
            }
            prepared.onFailure = { [weak self] reason in
                guard let self, self.generation == attempt else { return }
                self.stop()
                switch reason {
                case "voice_recognition_timed_out":
                    self.message = "Voice couldn't finish recognizing that sentence. Try again."
                case "audio_capture_format_unavailable", "audio_engine_restart_failed":
                    self.message =
                        "Microphone audio isn't available. Check the selected input device in Sound settings, then start voice again."
                default:
                    self.message = "Voice stopped. Try starting it again."
                }
                self.showingSetup = true
            }
            prepared.onTranscript = { [weak self] text, final in
                guard let self, self.generation == attempt else { return }
                self.onTranscript?(text, final)
            }
            try prepared.start(trigger: .ownerGesture)
            pipeline = prepared
            isRunning = true
            showingSetup = false
            message = "Listening"
            Self.log.info("voice_start listening")
        } catch {
            Self.log.error("voice_start failed type=\(String(reflecting: type(of: error)), privacy: .public)")
            guard generation == attempt else {
                closeSession()
                return
            }
            closeSession()
            if error is VoiceDuplexError {
                message =
                    "The microphone and speaker couldn't start. Check the selected audio devices, then try again."
            } else if let failure = error as? MeshKernelError {
                message = failure.message
            } else {
                message = "The voice model couldn't start. Try downloading it again."
            }
            showingSetup = true
        }
    }

    func toggle() async {
        if isRunning || isPreparing { stop() } else { await activate() }
    }

    func stop() {
        let notify = isRunning || isPreparing || companion
        if isRunning || isPreparing {
            Self.log.info(
                "voice_stop preparing=\(self.isPreparing, privacy: .public) running=\(self.isRunning, privacy: .public)"
            )
        }
        generation &+= 1
        pipeline?.stop()
        pipeline = nil
        closeSession()
        isRunning = false
        isPreparing = false
        message = nil
        companion = false
        if notify { onSessionStopped?() }
    }

    func suspend() {
        foreground = false
        stop()
    }

    func resume() { foreground = true }

    func interruptionBegan() {
        interrupted = true
        stop()
    }
    func interruptionEnded() { interrupted = false }
    func sessionLocked() {
        locked = true
        stop()
    }
    func sessionUnlocked() { locked = false }

    func confirmDownload(allowMetered: Bool = false) async {
        guard let store else { return }
        if store.needsMeteredConfirmation, !allowMetered {
            showingMeteredConfirmation = true
            return
        }
        showingMeteredConfirmation = false
        await store.startDownload(allowMetered: allowMetered)
    }

    func cancelDownload() async { await store?.cancelDownload() }

    func deleteModel() async {
        stop()
        await parts.unload()
        await store?.delete()
        await parts.unload()
    }

    private func closeSession() {
        guard sessionOpen else { return }
        sessionOpen = false
        let end = parts.end
        Task { await end() }
    }

    func answerDelta(_ text: String) { pipeline?.answerDelta(text) }
    func answerFinished() { pipeline?.answerFinished() }
    func toolStarted(id: String, cancelSafe: Bool) { pipeline?.toolStarted(id: id, cancelSafe: cancelSafe) }
    func toolFinished(id: String) { pipeline?.toolFinished(id: id) }
    func setRiskyActionPending(_ pending: Bool) { pipeline?.setRiskyActionPending(pending) }

    static func microphonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

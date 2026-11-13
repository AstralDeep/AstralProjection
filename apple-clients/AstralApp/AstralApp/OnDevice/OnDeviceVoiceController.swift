// Owns the first-microphone model offer and starts an MLX voice pipeline only after installation, permission and conversation readiness.
// AppModel supplies the current kernel link; lifecycle changes retire capture and fence any pending model load.

import AVFoundation
import Foundation
import OSLog
import Observation

@MainActor
@Observable
final class OnDeviceVoiceController {
    private static let log = Logger(subsystem: "com.personalailabs.astraldeep.voice", category: "controller")
    let store: VoiceModelStore?
    var showingSetup = false
    var showingMeteredConfirmation = false
    private(set) var isRunning = false
    private(set) var isPreparing = false
    private(set) var message: String?
    @ObservationIgnored private let requestPermission: () async -> Bool
    @ObservationIgnored private let makePipeline: @MainActor (URL, VoiceKernelLink) async throws -> VoicePipeline
    @ObservationIgnored private var link: VoiceKernelLink?
    @ObservationIgnored private var pipeline: VoicePipeline?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var interrupted = false
    @ObservationIgnored private var locked = false

    init(
        store: VoiceModelStore?,
        requestPermission: @escaping () async -> Bool = OnDeviceVoiceController.microphonePermission,
        makePipeline: @escaping @MainActor (URL, VoiceKernelLink) async throws -> VoicePipeline = MLXVoiceRuntime
            .pipeline
    ) {
        self.store = store
        self.requestPermission = requestPermission
        self.makePipeline = makePipeline
        if store == nil { message = VoiceModelFailure.manifestUnavailable.message }
    }

    convenience init() {
        let manifest = try? VoiceModelManifest.bundled()
        self.init(store: manifest.map { VoiceModelStore(manifest: $0, root: VoiceModelStore.defaultRoot()) })
    }

    var downloadSize: String? { store?.manifest.sizeDescription }
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
        case .installed: break
        }
        guard let link else {
            message = "Voice is not ready in this conversation yet."
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
            "voice_start verified_model installed=\(store.installedDirectory != nil, privacy: .public) current=\(self.generation == attempt, privacy: .public) eligible=\(self.eligible, privacy: .public)"
        )
        guard generation == attempt, eligible, !Task.isCancelled else { return }
        guard let directory = store.installedDirectory else {
            message = "The voice model needs to be downloaded again."
            showingSetup = true
            return
        }
        let permitted = await requestPermission()
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
            let prepared = try await makePipeline(directory, link)
            Self.log.info(
                "voice_start pipeline_prepared current=\(self.generation == attempt, privacy: .public) eligible=\(self.eligible, privacy: .public)"
            )
            guard generation == attempt, eligible, !Task.isCancelled else {
                prepared.stop()
                return
            }
            prepared.onFailure = { [weak self] reason in
                guard let self, self.generation == attempt else { return }
                self.stop()
                switch reason {
                case "voice_recognition_timed_out":
                    self.message = "Voice could not finish recognizing that sentence. Try again."
                case "audio_capture_format_unavailable", "audio_engine_restart_failed":
                    self.message =
                        "Microphone audio is not available. Check the selected input device in Sound settings, then start voice again."
                default:
                    self.message = "Voice stopped. Try starting it again."
                }
                self.showingSetup = true
            }
            try prepared.start(trigger: .ownerGesture)
            pipeline = prepared
            isRunning = true
            showingSetup = false
            message = "Listening"
            Self.log.info("voice_start listening")
        } catch {
            Self.log.error("voice_start failed type=\(String(reflecting: type(of: error)), privacy: .public)")
            guard generation == attempt else { return }
            if error is VoiceDuplexError {
                message =
                    "The microphone and speaker could not start. Check the selected audio devices, then try again."
            } else if let failure = error as? MeshKernelError {
                message = failure.message
            } else {
                message = "The voice model could not start. Try downloading it again."
            }
            showingSetup = true
        }
    }

    func toggle() async {
        if isRunning || isPreparing { stop() } else { await activate() }
    }

    func stop() {
        if isRunning || isPreparing {
            Self.log.info(
                "voice_stop preparing=\(self.isPreparing, privacy: .public) running=\(self.isRunning, privacy: .public)"
            )
        }
        generation &+= 1
        pipeline?.stop()
        pipeline = nil
        isRunning = false
        isPreparing = false
        message = nil
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
        await VoiceInferenceCache.shared.beginDeletion()
        await store?.delete()
        await VoiceInferenceCache.shared.endDeletion()
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

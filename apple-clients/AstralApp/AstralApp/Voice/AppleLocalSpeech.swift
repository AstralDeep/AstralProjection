// Observes and drives on-device Apple speech (SFSpeechRecognizer + AVSpeechSynthesizer) for the
// client_local/v1 voice profile consumed by AppleVoiceSessionController. The engine refuses to
// report guaranteed-local processing unless the recognizer proves on-device support and both
// permissions are authorized, and it never sends audio or text off the device.

import AVFoundation
import AstralCore
import Foundation
import Speech

struct AppleLocalSpeechObservation: Sendable, Equatable {
    let hasMicrophone: Bool
    let hasAudioOutput: Bool
    let microphonePermission: String
    let recognitionPermission: String
    let recognitionProcessing: String
    let recognitionLocale: String
    let recognitionInstallation: String
    let synthesisProcessing: String
    let synthesisLocale: String

    static let configuredLocale = "en-US"

    var fullDuplex: Bool { false }

    var ready: Bool { refusalReason() == nil }

    func refusalReason() -> String? {
        if !hasMicrophone { return "no_microphone" }
        if !hasAudioOutput { return "no_audio_output" }
        if ["denied", "restricted", "unavailable"].contains(microphonePermission) {
            return "microphone_permission_denied"
        }
        if microphonePermission != "authorized" { return "microphone_permission_not_determined" }
        if ["denied", "restricted", "unavailable"].contains(recognitionPermission) {
            return "speech_recognition_permission_denied"
        }
        if recognitionPermission != "authorized" {
            return "speech_recognition_permission_not_determined"
        }
        if recognitionProcessing == "unavailable" { return "local_recognition_unavailable" }
        if recognitionProcessing != "guaranteed_local" { return "local_processing_not_guaranteed" }
        if ["unavailable", "not_applicable"].contains(recognitionInstallation) {
            return "local_recognition_unavailable"
        }
        if recognitionInstallation != "ready" { return "local_language_download_required" }
        if recognitionLocale != "ready" { return "local_recognition_locale_unavailable" }
        if synthesisProcessing == "unavailable" { return "local_synthesis_unavailable" }
        if synthesisProcessing != "guaranteed_local" { return "local_processing_not_guaranteed" }
        if synthesisLocale != "ready" { return "local_synthesis_locale_unavailable" }
        return nil
    }

    func clientCapability() -> [String: JSONValue] {
        [
            "contract": .string("client_local/v1"),
            "transport": .string("client_local"),
            "configured_locale": .string(Self.configuredLocale),
            "full_duplex": .bool(false),
            "has_microphone": .bool(hasMicrophone),
            "has_audio_output": .bool(hasAudioOutput),
            "microphone_permission": .string(microphonePermission),
            "recognition_permission": .string(recognitionPermission),
            "recognition_processing": .string(recognitionProcessing),
            "recognition_locale": .string(recognitionLocale),
            "recognition_installation": .string(recognitionInstallation),
            "synthesis_processing": .string(synthesisProcessing),
            "synthesis_locale": .string(synthesisLocale),
        ]
    }

    func readyCapability() -> [String: JSONValue]? {
        refusalReason() == nil ? clientCapability() : nil
    }
}

@MainActor
protocol AppleLocalSpeechEngine: AnyObject {
    func authorize() async -> AppleLocalSpeechObservation
    func observation() async -> AppleLocalSpeechObservation
    func startRecognition(
        onFinal: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) -> Bool
    func stopRecognition() async
    func speak(_ text: String, onPhase: @escaping @MainActor (String) -> Void) -> Bool
    func stopAll() async
}

func canonicalizeLocalFinal(_ value: String) -> String? {
    let joined =
        value
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    let canonical = joined.precomposedStringWithCanonicalMapping
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !canonical.isEmpty, canonical.unicodeScalars.count <= 8_000 else { return nil }
    for character in canonical {
        if character == "\t" || character == "\n" { continue }
        for scalar in String(character).unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned:
                return nil
            default:
                continue
            }
        }
    }
    return canonical
}

@MainActor
final class SystemAppleLocalSpeechEngine: NSObject, AppleLocalSpeechEngine,
    AVSpeechSynthesizerDelegate
{
    private let synthesizer = AVSpeechSynthesizer()
    private var captureEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var reportedFinal = false
    private let speechProgress = AppleLocalSpeechProgress()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func authorize() async -> AppleLocalSpeechObservation {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
        #if os(iOS)
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
        #endif
        return await observation()
    }

    func observation() async -> AppleLocalSpeechObservation {
        let microphonePermission = AppleVoicePermission.status
        #if os(iOS)
            let hasMicrophone = AVCaptureDevice.default(for: .audio) != nil
            let hasAudioOutput = !AVAudioSession.sharedInstance().currentRoute.outputs.isEmpty
        #else
            let availability = AppleVoicePermission.macOSHardwareAvailability(
                AppleVoicePermission.currentAudioRouteSnapshot())
            let hasMicrophone = availability.hasMicrophone
            let hasAudioOutput = availability.hasAudioOutput
        #endif
        let status = SFSpeechRecognizer.authorizationStatus()
        let recognitionPermission =
            switch status {
            case .authorized: "authorized"
            case .denied: "denied"
            case .restricted: "restricted"
            case .notDetermined: "not_determined"
            @unknown default: "unavailable"
            }
        let locale = Locale(identifier: AppleLocalSpeechObservation.configuredLocale)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            return AppleLocalSpeechObservation(
                hasMicrophone: hasMicrophone, hasAudioOutput: hasAudioOutput,
                microphonePermission: microphonePermission,
                recognitionPermission: recognitionPermission,
                recognitionProcessing: "unavailable", recognitionLocale: "unavailable",
                recognitionInstallation: "unavailable", synthesisProcessing: "unavailable",
                synthesisLocale: "unavailable")
        }
        let onDevice = recognizer.supportsOnDeviceRecognition
        let recognitionProcessing = onDevice == true ? "guaranteed_local" : "unavailable"
        let recognitionInstallation = onDevice == true ? "ready" : "unavailable"
        let recognitionLocale = onDevice == true ? "ready" : "unavailable"
        let voice = AVSpeechSynthesisVoice(language: AppleLocalSpeechObservation.configuredLocale)
        let synthesisLocale = voice == nil ? "unavailable" : "ready"
        return AppleLocalSpeechObservation(
            hasMicrophone: hasMicrophone, hasAudioOutput: hasAudioOutput,
            microphonePermission: microphonePermission,
            recognitionPermission: recognitionPermission,
            recognitionProcessing: recognitionProcessing, recognitionLocale: recognitionLocale,
            recognitionInstallation: recognitionInstallation,
            synthesisProcessing: "guaranteed_local", synthesisLocale: synthesisLocale)
    }

    func startRecognition(
        onFinal: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) -> Bool {
        reportedFinal = false
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return false }
        let locale = Locale(identifier: AppleLocalSpeechObservation.configuredLocale)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
            recognizer.supportsOnDeviceRecognition == true
        else { return false }
        activateAudioSession()
        let audioEngine = AVAudioEngine()
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return false }
        let bufferRequest = SFSpeechAudioBufferRecognitionRequest()
        bufferRequest.shouldReportPartialResults = false
        bufferRequest.requiresOnDeviceRecognition = true
        let startedTask = recognizer.recognitionTask(with: bufferRequest) {
            [weak self] result, error in
            Task { @MainActor in
                self?.consumeRecognitionResult(
                    result, error: error, onFinal: onFinal, onError: onError)
            }
        }
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, _ in
            bufferRequest.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            bufferRequest.endAudio()
            startedTask.finish()
            return false
        }
        captureEngine = audioEngine
        request = bufferRequest
        task = startedTask
        return true
    }

    private func consumeRecognitionResult(
        _ result: SFSpeechRecognitionResult?,
        error: (any Error)?,
        onFinal: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        if let result, result.isFinal, !reportedFinal {
            reportedFinal = true
            let text = result.bestTranscription.formattedString
            Task { await self.stopRecognition() }
            onFinal(text)
            return
        }
        guard let error else { return }
        Task { await self.stopRecognition() }
        onError(Self.recognitionFailureReason(error))
    }

    private static func recognitionFailureReason(_ error: any Error) -> String {
        let code = (error as NSError).code
        if code == 1 || code == 4 { return "local_recognition_cancelled" }
        if code == 201 { return "local_recognition_locale_unavailable" }
        if code == 203 || code == 1101 { return "local_engine_lost" }
        if code == 301 || code == 1103 { return "local_recognition_unavailable" }
        if code == 1110 { return "local_audio_interrupted" }
        return "local_recognition_failed"
    }

    func stopRecognition() async {
        guard let audioEngine = captureEngine else { return }
        captureEngine = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
    }

    func speak(_ text: String, onPhase: @escaping @MainActor (String) -> Void) -> Bool {
        guard
            let voice = AVSpeechSynthesisVoice(
                language: AppleLocalSpeechObservation.configuredLocale),
            !text.isEmpty
        else { return false }
        activateAudioSession()
        stopSynthesis()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        speechProgress.begin(utterance, onPhase: onPhase)
        synthesizer.speak(utterance)
        return true
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard characterRange.location == 0 else { return }
        speechProgress.start(utterance)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        speechProgress.finish(utterance, phase: "finished")
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        speechProgress.finish(utterance, phase: "interrupted")
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didEncounterError utterance: AVSpeechUtterance,
        error: any Error
    ) {
        speechProgress.finish(utterance, phase: "failed")
    }

    func stopAll() async {
        await stopRecognition()
        stopSynthesis()
    }

    private func stopSynthesis() {
        speechProgress.clear()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func activateAudioSession() {
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(
                    .playAndRecord, mode: .measurement,
                    options: [.defaultToSpeaker, .allowBluetooth])
                try session.setActive(true, options: [])
            } catch {
                return
            }
        #endif
    }
}

// Keeps legacy speech observation and transcript validation without a platform-speech fallback.
// The retired engine reports unavailability; active Apple speech belongs to the installed voice pack.

import AstralCore
import Foundation

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
final class RetiredAppleLocalSpeechEngine: AppleLocalSpeechEngine {
    func authorize() async -> AppleLocalSpeechObservation { await observation() }
    func observation() async -> AppleLocalSpeechObservation {
        AppleLocalSpeechObservation(
            hasMicrophone: false, hasAudioOutput: false, microphonePermission: "unavailable",
            recognitionPermission: "unavailable", recognitionProcessing: "unavailable",
            recognitionLocale: "unavailable", recognitionInstallation: "unavailable",
            synthesisProcessing: "unavailable", synthesisLocale: "unavailable")
    }
    func startRecognition(
        onFinal: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) -> Bool { false }
    func stopRecognition() async {}
    func speak(_ text: String, onPhase: @escaping @MainActor (String) -> Void) -> Bool { false }
    func stopAll() async {}
}

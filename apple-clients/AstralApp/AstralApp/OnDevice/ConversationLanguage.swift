// The eight languages a voice conversation can run in, each with its locale, the language the recognizer listens for and the per-device saved choice.
// The voice session reads it to pick recognition, the reply language and the system voice, and it never leaves this device.

import AstralVoiceRuntime
import Foundation

nonisolated enum ConversationLanguage: String, CaseIterable, Sendable, Identifiable {
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case arabic = "ar"
    case mandarin = "zh"
    case japanese = "ja"
    case korean = "ko"

    static let defaultsKey = "astral.voice.conversation-language"

    var id: String { rawValue }

    var localeIdentifier: String {
        switch self {
        case .english: "en-US"
        case .spanish: "es-ES"
        case .french: "fr-FR"
        case .german: "de-DE"
        case .arabic: "ar-SA"
        case .mandarin: "zh-CN"
        case .japanese: "ja-JP"
        case .korean: "ko-KR"
        }
    }

    var nativeName: String {
        switch self {
        case .english: "English"
        case .spanish: "Español"
        case .french: "Français"
        case .german: "Deutsch"
        case .arabic: "العربية"
        case .mandarin: "中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        }
    }

    var recognitionLanguage: RecognitionLanguage { try! RecognitionLanguage(code: rawValue) }

    init?(languageTag: String) {
        let code = languageTag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
        self.init(rawValue: code)
    }

    static func deviceDefault(preferredLanguages: [String] = Locale.preferredLanguages) -> ConversationLanguage {
        preferredLanguages.first.flatMap { ConversationLanguage(languageTag: $0) } ?? .english
    }

    static func saved(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages)
        -> ConversationLanguage
    {
        defaults.string(forKey: defaultsKey).flatMap { ConversationLanguage(rawValue: $0) }
            ?? deviceDefault(preferredLanguages: preferredLanguages)
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

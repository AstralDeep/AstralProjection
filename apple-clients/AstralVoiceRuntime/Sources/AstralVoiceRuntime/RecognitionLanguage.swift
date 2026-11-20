// A language the recognizer can be told to transcribe, given as an ISO code or an English name and rendered as the name the model's prompt expects.
// SpeechRecognizer builds its assistant prefix from it, so the model never has to guess the language.
import Foundation

public struct RecognitionLanguage: Sendable, Equatable, Hashable {
    public let code: String
    public let englishName: String

    public init(code: String) throws {
        let key = code.lowercased()
        if let name = Self.names[key] {
            self.code = key
            self.englishName = name
        } else if let entry = Self.names.first(where: { $0.value.lowercased() == key }) {
            self.code = entry.key
            self.englishName = entry.value
        } else {
            throw VoiceRuntimeError.unsupportedLanguage(code)
        }
    }

    public static let english = try! RecognitionLanguage(code: "en")

    private static let names: [String: String] = [
        "af": "Afrikaans", "ar": "Arabic", "bn": "Bengali", "bs": "Bosnian", "ca": "Catalan", "ceb": "Cebuano",
        "cs": "Czech", "da": "Danish", "de": "German", "el": "Greek", "en": "English", "es": "Spanish",
        "eu": "Basque", "fa": "Persian", "fi": "Finnish", "fil": "Filipino", "fr": "French", "hi": "Hindi",
        "hr": "Croatian", "hu": "Hungarian", "id": "Indonesian", "is": "Icelandic", "it": "Italian",
        "ja": "Japanese", "ko": "Korean", "lt": "Lithuanian", "lv": "Latvian", "mk": "Macedonian",
        "ms": "Malay", "mt": "Maltese", "nb": "Norwegian", "nl": "Dutch", "pl": "Polish", "pt": "Portuguese",
        "ro": "Romanian", "ru": "Russian", "sq": "Albanian", "sr": "Serbian", "sv": "Swedish", "th": "Thai",
        "tr": "Turkish", "uk": "Ukrainian", "vi": "Vietnamese", "yue": "Cantonese", "zh": "Chinese",
    ]
}

// Checks the eight conversation languages, their locales and recognizer languages, and the per-device saved choice with its device-language default.
// The tests use a throwaway defaults suite so no device setting is read or changed.

import AstralVoiceRuntime
import XCTest

@testable import AstralDeep

final class ConversationLanguageTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "ConversationLanguageTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        addTeardownBlock { suite.removePersistentDomain(forName: name) }
        return suite
    }

    func testTheEightLanguagesMapToTheirLocalesAndRecognitionLanguages() throws {
        let expected: [(ConversationLanguage, String, String, String)] = [
            (.english, "en-US", "en", "English"), (.spanish, "es-ES", "es", "Spanish"),
            (.french, "fr-FR", "fr", "French"), (.german, "de-DE", "de", "German"),
            (.arabic, "ar-SA", "ar", "Arabic"), (.mandarin, "zh-CN", "zh", "Chinese"),
            (.japanese, "ja-JP", "ja", "Japanese"), (.korean, "ko-KR", "ko", "Korean"),
        ]
        XCTAssertEqual(ConversationLanguage.allCases.count, 8)
        XCTAssertEqual(Set(ConversationLanguage.allCases), Set(expected.map(\.0)))
        for (language, locale, code, name) in expected {
            XCTAssertEqual(language.localeIdentifier, locale)
            XCTAssertEqual(language.recognitionLanguage.code, code)
            XCTAssertEqual(language.recognitionLanguage.englishName, name)
            XCTAssertEqual(Locale(identifier: language.localeIdentifier).language.languageCode?.identifier, code)
            XCTAssertFalse(language.nativeName.isEmpty)
        }
    }

    func testTheDeviceLanguageIsTheDefaultWhenItIsOneOfTheEight() {
        XCTAssertEqual(ConversationLanguage.deviceDefault(preferredLanguages: ["fr-CA", "en-US"]), .french)
        XCTAssertEqual(ConversationLanguage.deviceDefault(preferredLanguages: ["zh-Hans-CN"]), .mandarin)
        XCTAssertEqual(ConversationLanguage.deviceDefault(preferredLanguages: ["ja_JP"]), .japanese)
    }

    func testOnlyTheDeviceLanguageCountsAndOthersFallBackToEnglish() {
        XCTAssertEqual(ConversationLanguage.deviceDefault(preferredLanguages: ["it-IT", "de-DE"]), .english)
        XCTAssertEqual(ConversationLanguage.deviceDefault(preferredLanguages: ["it-IT", "pt-BR"]), .english)
        XCTAssertEqual(ConversationLanguage.deviceDefault(preferredLanguages: []), .english)
        XCTAssertNil(ConversationLanguage(languageTag: ""))
    }

    func testTheChoiceIsSavedPerDeviceAndOverridesTheDefault() {
        let store = defaults()
        XCTAssertEqual(ConversationLanguage.saved(defaults: store, preferredLanguages: ["ko-KR"]), .korean)
        ConversationLanguage.spanish.save(defaults: store)
        XCTAssertEqual(ConversationLanguage.saved(defaults: store, preferredLanguages: ["ko-KR"]), .spanish)
    }

    func testAnUnreadableSavedValueFallsBackToTheDeviceDefault() {
        let store = defaults()
        store.set("xx", forKey: ConversationLanguage.defaultsKey)
        XCTAssertEqual(ConversationLanguage.saved(defaults: store, preferredLanguages: ["de-DE"]), .german)
    }
}

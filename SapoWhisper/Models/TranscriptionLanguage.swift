//
//  TranscriptionLanguage.swift
//  SapoWhisper
//

import Foundation

struct TranscriptionLanguage: Identifiable, Equatable {
    let code: String
    let flag: String
    let nativeName: String
    let englishName: String
    let appleLocaleIdentifier: String?
    let googleLanguageCode: String?
    let elevenLabsLanguageCode: String?

    var id: String { code }

    var displayName: String {
        if code == "auto" {
            return "\(flag) \("lang.auto".localized)"
        }
        if nativeName == englishName {
            return "\(flag) \(nativeName)"
        }
        return "\(flag) \(nativeName) (\(englishName))"
    }

}

enum TranscriptionLanguageCatalog {
    static let languages: [TranscriptionLanguage] = [
        TranscriptionLanguage(
            code: "auto",
            flag: "🌐",
            nativeName: "Auto",
            englishName: "Auto",
            appleLocaleIdentifier: nil,
            googleLanguageCode: nil,
            elevenLabsLanguageCode: nil
        ),
        TranscriptionLanguage(
            code: "en",
            flag: "🇺🇸",
            nativeName: "English",
            englishName: "English",
            appleLocaleIdentifier: "en-US",
            googleLanguageCode: "en-US",
            elevenLabsLanguageCode: "eng"
        ),
        TranscriptionLanguage(
            code: "es",
            flag: "🇪🇸",
            nativeName: "Español",
            englishName: "Spanish",
            appleLocaleIdentifier: "es-ES",
            googleLanguageCode: "es-ES",
            elevenLabsLanguageCode: "spa"
        ),
        TranscriptionLanguage(
            code: "hi",
            flag: "🇮🇳",
            nativeName: "हिन्दी",
            englishName: "Hindi",
            appleLocaleIdentifier: "hi-IN",
            googleLanguageCode: "hi-IN",
            elevenLabsLanguageCode: "hin"
        ),
        TranscriptionLanguage(
            code: "fr",
            flag: "🇫🇷",
            nativeName: "Français",
            englishName: "French",
            appleLocaleIdentifier: "fr-FR",
            googleLanguageCode: "fr-FR",
            elevenLabsLanguageCode: "fra"
        ),
        TranscriptionLanguage(
            code: "de",
            flag: "🇩🇪",
            nativeName: "Deutsch",
            englishName: "German",
            appleLocaleIdentifier: "de-DE",
            googleLanguageCode: "de-DE",
            elevenLabsLanguageCode: "deu"
        ),
        TranscriptionLanguage(
            code: "ru",
            flag: "🇷🇺",
            nativeName: "Русский",
            englishName: "Russian",
            appleLocaleIdentifier: "ru-RU",
            googleLanguageCode: "ru-RU",
            elevenLabsLanguageCode: "rus"
        ),
        TranscriptionLanguage(
            code: "zh",
            flag: "🇨🇳",
            nativeName: "中文（普通话）",
            englishName: "Mandarin Chinese",
            appleLocaleIdentifier: "zh-CN",
            googleLanguageCode: "cmn-Hans-CN",
            elevenLabsLanguageCode: "zho"
        ),
        TranscriptionLanguage(
            code: "ar",
            flag: "🇸🇦",
            nativeName: "العربية",
            englishName: "Arabic",
            appleLocaleIdentifier: "ar-SA",
            googleLanguageCode: "ar-SA",
            elevenLabsLanguageCode: "ara"
        ),
        TranscriptionLanguage(
            code: "pt",
            flag: "🇧🇷",
            nativeName: "Português",
            englishName: "Portuguese",
            appleLocaleIdentifier: "pt-BR",
            googleLanguageCode: "pt-BR",
            elevenLabsLanguageCode: "por"
        ),
        TranscriptionLanguage(
            code: "tr",
            flag: "🇹🇷",
            nativeName: "Türkçe",
            englishName: "Turkish",
            appleLocaleIdentifier: "tr-TR",
            googleLanguageCode: "tr-TR",
            elevenLabsLanguageCode: "tur"
        ),
        TranscriptionLanguage(
            code: "ja",
            flag: "🇯🇵",
            nativeName: "日本語",
            englishName: "Japanese",
            appleLocaleIdentifier: "ja-JP",
            googleLanguageCode: "ja-JP",
            elevenLabsLanguageCode: "jpn"
        ),
        TranscriptionLanguage(
            code: "id",
            flag: "🇮🇩",
            nativeName: "Bahasa Indonesia",
            englishName: "Indonesian",
            appleLocaleIdentifier: "id-ID",
            googleLanguageCode: "id-ID",
            elevenLabsLanguageCode: "ind"
        ),
        TranscriptionLanguage(
            code: "it",
            flag: "🇮🇹",
            nativeName: "Italiano",
            englishName: "Italian",
            appleLocaleIdentifier: "it-IT",
            googleLanguageCode: "it-IT",
            elevenLabsLanguageCode: "ita"
        ),
        TranscriptionLanguage(
            code: "ko",
            flag: "🇰🇷",
            nativeName: "한국어",
            englishName: "Korean",
            appleLocaleIdentifier: "ko-KR",
            googleLanguageCode: "ko-KR",
            elevenLabsLanguageCode: "kor"
        ),
        TranscriptionLanguage(
            code: "vi",
            flag: "🇻🇳",
            nativeName: "Tiếng Việt",
            englishName: "Vietnamese",
            appleLocaleIdentifier: "vi-VN",
            googleLanguageCode: "vi-VN",
            elevenLabsLanguageCode: "vie"
        ),
    ]

    static func language(for code: String) -> TranscriptionLanguage? {
        languages.first { $0.code == code }
    }

    static func appleLocaleIdentifier(for code: String) -> String? {
        language(for: code)?.appleLocaleIdentifier
    }

    static func deepgramLanguageCode(for code: String) -> String {
        code == "auto" ? "multi" : (language(for: code)?.code ?? "multi")
    }

    static func deepgramFluxLanguageHint(for code: String) -> String? {
        let supportedHints: Set<String> = ["en", "es", "fr", "de", "hi", "ru", "pt", "ja", "it", "nl"]
        guard supportedHints.contains(code) else { return nil }
        return code
    }

    static func elevenLabsLanguageCode(for code: String) -> String? {
        language(for: code)?.elevenLabsLanguageCode
    }

    static func googleLanguageCode(for code: String) -> String {
        language(for: code)?.googleLanguageCode ?? "es-ES"
    }

    static func whisperLanguageCode(for code: String) -> String? {
        code == "auto" ? nil : language(for: code)?.code
    }
}

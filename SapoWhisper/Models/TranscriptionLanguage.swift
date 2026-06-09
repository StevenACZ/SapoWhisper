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
            elevenLabsLanguageCode: nil
        ),
        TranscriptionLanguage(
            code: "en",
            flag: "🇺🇸",
            nativeName: "English",
            englishName: "English",
            elevenLabsLanguageCode: "eng"
        ),
        TranscriptionLanguage(
            code: "es",
            flag: "🇪🇸",
            nativeName: "Español",
            englishName: "Spanish",
            elevenLabsLanguageCode: "spa"
        ),
        TranscriptionLanguage(
            code: "hi",
            flag: "🇮🇳",
            nativeName: "हिन्दी",
            englishName: "Hindi",
            elevenLabsLanguageCode: "hin"
        ),
        TranscriptionLanguage(
            code: "fr",
            flag: "🇫🇷",
            nativeName: "Français",
            englishName: "French",
            elevenLabsLanguageCode: "fra"
        ),
        TranscriptionLanguage(
            code: "de",
            flag: "🇩🇪",
            nativeName: "Deutsch",
            englishName: "German",
            elevenLabsLanguageCode: "deu"
        ),
        TranscriptionLanguage(
            code: "ru",
            flag: "🇷🇺",
            nativeName: "Русский",
            englishName: "Russian",
            elevenLabsLanguageCode: "rus"
        ),
        TranscriptionLanguage(
            code: "zh",
            flag: "🇨🇳",
            nativeName: "中文（普通话）",
            englishName: "Mandarin Chinese",
            elevenLabsLanguageCode: "zho"
        ),
        TranscriptionLanguage(
            code: "ar",
            flag: "🇸🇦",
            nativeName: "العربية",
            englishName: "Arabic",
            elevenLabsLanguageCode: "ara"
        ),
        TranscriptionLanguage(
            code: "pt",
            flag: "🇧🇷",
            nativeName: "Português",
            englishName: "Portuguese",
            elevenLabsLanguageCode: "por"
        ),
        TranscriptionLanguage(
            code: "tr",
            flag: "🇹🇷",
            nativeName: "Türkçe",
            englishName: "Turkish",
            elevenLabsLanguageCode: "tur"
        ),
        TranscriptionLanguage(
            code: "ja",
            flag: "🇯🇵",
            nativeName: "日本語",
            englishName: "Japanese",
            elevenLabsLanguageCode: "jpn"
        ),
        TranscriptionLanguage(
            code: "id",
            flag: "🇮🇩",
            nativeName: "Bahasa Indonesia",
            englishName: "Indonesian",
            elevenLabsLanguageCode: "ind"
        ),
        TranscriptionLanguage(
            code: "it",
            flag: "🇮🇹",
            nativeName: "Italiano",
            englishName: "Italian",
            elevenLabsLanguageCode: "ita"
        ),
        TranscriptionLanguage(
            code: "ko",
            flag: "🇰🇷",
            nativeName: "한국어",
            englishName: "Korean",
            elevenLabsLanguageCode: "kor"
        ),
        TranscriptionLanguage(
            code: "vi",
            flag: "🇻🇳",
            nativeName: "Tiếng Việt",
            englishName: "Vietnamese",
            elevenLabsLanguageCode: "vie"
        ),
    ]

    static func language(for code: String) -> TranscriptionLanguage? {
        languages.first { $0.code == code }
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

    static func whisperLanguageCode(for code: String) -> String? {
        code == "auto" ? nil : language(for: code)?.code
    }
}

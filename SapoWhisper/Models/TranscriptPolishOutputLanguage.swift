//
//  TranscriptPolishOutputLanguage.swift
//  SapoWhisper
//

import Foundation

/// Target language for the AI-polished text. Translation always happens in
/// the AI polish step: Deepgram and ElevenLabs only transcribe the spoken
/// language, so an explicit target here never changes what the engine hears —
/// it only tells the polisher to translate the transcript.
enum TranscriptPolishOutputLanguage: String, CaseIterable, Identifiable {
    case sameAsInput = "same_as_input"
    case english
    case spanish
    case hindi
    case french
    case german
    case russian
    case chinese
    case arabic
    case portuguese
    case turkish
    case japanese
    case indonesian
    case italian
    case korean
    case vietnamese

    var id: String { rawValue }

    var displayName: String {
        guard let target else {
            return "ai.output_language.same".localized
        }
        if target.nativeName == target.englishName {
            return "\(target.flag) \(target.nativeName)"
        }
        return "\(target.flag) \(target.nativeName) (\(target.englishName))"
    }

    /// Compact form for tight UI like the engine-summary chip: flag plus
    /// native name, no English clarifier.
    var shortDisplayName: String {
        guard let target else {
            return "ai.output_language.same".localized
        }
        return "\(target.flag) \(target.nativeName)"
    }

    /// An explicit target language means the polished text may legitimately
    /// be a translation of the transcript, so literal word-reuse rules and
    /// language-bound fidelity anchors must not apply.
    var requiresTranslation: Bool {
        self != .sameAsInput
    }

    /// Dense, space-free scripts (CJK) pack far more meaning per character, so
    /// a faithful translation into them is much shorter than the source. The
    /// fidelity guard lowers its length-ratio floor only for these targets.
    var usesDenseScript: Bool {
        switch self {
        case .chinese, .japanese, .korean:
            return true
        default:
            return false
        }
    }

    /// English language name as written into the AI prompt; nil for
    /// same-as-input.
    var englishName: String? {
        target?.englishName
    }

    /// ISO 639-1 code used to verify with NLLanguageRecognizer that the
    /// polished text actually landed in the target language; nil for
    /// same-as-input. Chinese matches by prefix (zh-Hans/zh-Hant).
    var nlLanguageCode: String? {
        switch self {
        case .sameAsInput: return nil
        case .english: return "en"
        case .spanish: return "es"
        case .hindi: return "hi"
        case .french: return "fr"
        case .german: return "de"
        case .russian: return "ru"
        case .chinese: return "zh"
        case .arabic: return "ar"
        case .portuguese: return "pt"
        case .turkish: return "tr"
        case .japanese: return "ja"
        case .indonesian: return "id"
        case .italian: return "it"
        case .korean: return "ko"
        case .vietnamese: return "vi"
        }
    }

    var promptInstruction: String {
        guard let target else {
            return """
                Keep the output in the same dominant language as the raw transcript. If the transcript is mostly Spanish, write Spanish prose and keep English technical terms as-is. If it is mostly English, write English prose. Never switch to English just because these instructions or label examples are in English.
                """
        }
        return """
            Write the final text in \(target.englishName) — this overrides the language of the transcript. If the transcript is in another language, translate ALL of it into natural \(target.englishName) faithfully: same ideas, same order, same level of detail, nothing added and nothing dropped. Translating to comply is required and is not rephrasing. Keep code, commands, filenames, APIs, acronyms, product names, numbers, and user vocabulary exactly as spoken.
            """
    }

    /// Mirrors `TranscriptionLanguageCatalog` flags and native names so the
    /// output-language picker reads like the transcription-language picker.
    private var target: (flag: String, nativeName: String, englishName: String)? {
        switch self {
        case .sameAsInput:
            return nil
        case .english:
            return ("🇺🇸", "English", "English")
        case .spanish:
            return ("🇪🇸", "Español", "Spanish")
        case .hindi:
            return ("🇮🇳", "हिन्दी", "Hindi")
        case .french:
            return ("🇫🇷", "Français", "French")
        case .german:
            return ("🇩🇪", "Deutsch", "German")
        case .russian:
            return ("🇷🇺", "Русский", "Russian")
        case .chinese:
            return ("🇨🇳", "中文", "Chinese")
        case .arabic:
            return ("🇸🇦", "العربية", "Arabic")
        case .portuguese:
            return ("🇧🇷", "Português", "Portuguese")
        case .turkish:
            return ("🇹🇷", "Türkçe", "Turkish")
        case .japanese:
            return ("🇯🇵", "日本語", "Japanese")
        case .indonesian:
            return ("🇮🇩", "Bahasa Indonesia", "Indonesian")
        case .italian:
            return ("🇮🇹", "Italiano", "Italian")
        case .korean:
            return ("🇰🇷", "한국어", "Korean")
        case .vietnamese:
            return ("🇻🇳", "Tiếng Việt", "Vietnamese")
        }
    }
}

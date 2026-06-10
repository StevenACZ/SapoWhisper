//
//  TranscriptPolishOutputLanguage.swift
//  SapoWhisper
//

import Foundation

enum TranscriptPolishOutputLanguage: String, CaseIterable, Identifiable {
    case sameAsInput = "same_as_input"
    case spanish
    case english

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sameAsInput:
            return "ai.output_language.same".localized
        case .spanish:
            return "ai.output_language.spanish".localized
        case .english:
            return "ai.output_language.english".localized
        }
    }

    /// An explicit target language means the polished text may legitimately
    /// be a translation of the transcript, so literal word-reuse rules and
    /// language-bound fidelity anchors must not apply.
    var requiresTranslation: Bool {
        self != .sameAsInput
    }

    var promptInstruction: String {
        switch self {
        case .sameAsInput:
            return """
                Keep the output in the same dominant language as the raw transcript. If the transcript is mostly Spanish, write Spanish prose and keep English technical terms as-is. If it is mostly English, write English prose. Never switch to English just because these instructions or label examples are in English.
                """
        case .spanish:
            return """
                Write the final text in Spanish — this overrides the language of the transcript. If the transcript is in another language, translate ALL of it into natural Spanish faithfully: same ideas, same order, same level of detail, nothing added and nothing dropped. Translating to comply is required and is not rephrasing. Keep code, commands, filenames, APIs, acronyms, product names, numbers, and user vocabulary exactly as spoken.
                """
        case .english:
            return """
                Write the final text in English — this overrides the language of the transcript. If the transcript is in another language, translate ALL of it into natural English faithfully: same ideas, same order, same level of detail, nothing added and nothing dropped. Translating to comply is required and is not rephrasing. Keep code, commands, filenames, APIs, acronyms, product names, numbers, and user vocabulary exactly as spoken.
                """
        }
    }
}

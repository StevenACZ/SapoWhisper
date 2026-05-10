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

    var promptInstruction: String {
        switch self {
        case .sameAsInput:
            return """
                Keep the output in the same dominant language as the raw transcript. If the transcript is mostly Spanish, write Spanish prose and keep English technical terms as-is. If it is mostly English, write English prose. Never switch to English just because these instructions or label examples are in English.
                """
        case .spanish:
            return """
                Write the final text in Spanish. Preserve English technical terms, commands, filenames, APIs, product names, and user vocabulary exactly when they are technical identifiers.
                """
        case .english:
            return """
                Write the final text in English. Preserve technical terms, commands, filenames, APIs, product names, and user vocabulary exactly when they are technical identifiers.
                """
        }
    }
}

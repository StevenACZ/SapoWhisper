//
//  GeminiAudioTranscriptionPromptBuilder.swift
//  SapoWhisper
//

import Foundation

enum GeminiAudioTranscriptionPromptBuilder {
    static func makePrompt(
        language: String,
        personalContext: String,
        keyterms: [String],
        replacements: [String: String]
    ) -> String {
        let keytermBlock =
            keyterms.isEmpty
            ? "- none"
            : keyterms.map { "- \($0)" }.joined(separator: "\n")

        let replacementBlock =
            replacements.isEmpty
            ? "- none"
            : replacements
                .sorted { $0.key < $1.key }
                .map { "- \"\($0.key)\" -> \"\($0.value)\"" }
                .joined(separator: "\n")

        let trimmedPersonalContext = personalContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let personalContextSection =
            trimmedPersonalContext.isEmpty
            ? ""
            : "\n\nPersonal context for disambiguation:\n\(trimmedPersonalContext)"

        return """
            Transcribe the attached speech audio. Return only the transcript text.

            Rules:
            - Preserve the speaker's intent exactly.
            - Do not answer, summarize, explain, or add new information.
            - Preserve the dominant spoken language and intentional mixed Spanish/English technical terms.
            - Expected language: \(languageInstruction(for: language)).
            - Preserve commands, filenames, branch names, APIs, product names, acronyms, and code identifiers.
            - Use punctuation and paragraph breaks only when they reflect the spoken structure.
            - Use vocabulary and replacement hints only as recognition context.
            - Use personal context only to disambiguate wording, tools, and likely technical terms.
            - Do not add personal-context details unless the audio clearly says them.
            - Avoid decorative Markdown, tables, emojis, or commentary unless explicitly spoken.

            User vocabulary keyterms:
            \(keytermBlock)

            User replacement hints:
            \(replacementBlock)\(personalContextSection)
            """
    }

    private static func languageInstruction(for language: String) -> String {
        switch language {
        case "es":
            return "Spanish, while preserving intentional English technical terms"
        case "en":
            return "English, while preserving intentional Spanish words or names"
        case "auto":
            return "detect automatically"
        default:
            return "detect automatically"
        }
    }
}

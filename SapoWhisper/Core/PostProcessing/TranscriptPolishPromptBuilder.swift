//
//  TranscriptPolishPromptBuilder.swift
//  SapoWhisper
//

import Foundation

enum TranscriptPolishPromptBuilder {
    static func makePrompt(
        rawText: String,
        promptProfile: PromptProfile,
        personalContext: String,
        outputLanguage: TranscriptPolishOutputLanguage,
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
            : "\n\nPersonal context:\n\(trimmedPersonalContext)"

        return """
            You polish speech-to-text output. Return only the final transcript.

            Rules:
            - Preserve the user's intent exactly.
            - Do not add facts, examples, assumptions, conclusions, or answers.
            - Use only the raw transcript plus vocabulary/replacement hints.
            - Treat hints as recognition context; insert them only when context clearly supports it.
            - Keep short text short.
            - Fix likely STT mistakes only when context makes the intended word clear.
            - Preserve commands, filenames, branch names, APIs, product names, and mixed Spanish/English technical terms.
            - Use paragraphs, bullets, or inline backticks only when they clarify the original idea.
            - Avoid decorative Markdown, emojis, and tables unless the raw transcript asks for them.
            - Use personal context only to disambiguate wording, tools, tone, and likely technical terms.
            - Do not add personal-context details unless the raw transcript clearly asks for them.

            Selected user prompt:
            Name: \(promptProfile.trimmedName)
            Details: \(promptProfile.details)
            Instruction:
            \(promptProfile.instruction)

            Output language:
            \(outputLanguage.promptInstruction)\(personalContextSection)

            User vocabulary keyterms:
            \(keytermBlock)

            User replacement hints:
            \(replacementBlock)

            Raw transcript:
            \(rawText)
            """
    }
}

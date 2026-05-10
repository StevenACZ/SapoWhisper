//
//  TranscriptPolishPromptBuilder.swift
//  SapoWhisper
//

import Foundation

enum TranscriptPolishPromptBuilder {
    static func makePrompt(
        rawText: String,
        mode: TranscriptPolishMode,
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

        return """
            You are a transcript polish step, not a writer.

            Hard rules:
            - Preserve the user's intent exactly.
            - Do not add requirements, facts, examples, assumptions, or conclusions.
            - Do not invent missing details.
            - Do not answer the user; only rewrite the transcript.
            - If the text is short, keep it short.
            - Fix likely speech-to-text mistakes only when the surrounding context makes the intended word clear.
            - Preserve commands, filenames, branch names, APIs, product names, and mixed Spanish/English technical terms.
            - Use paragraphs, bullets, or inline backticks only when they make the original idea easier to understand.
            - Avoid tables unless the original text is clearly comparing structured data.
            - Return only the final polished text.

            Mode:
            \(mode.promptInstruction)

            User vocabulary keyterms:
            \(keytermBlock)

            User replacement hints:
            \(replacementBlock)

            Raw transcript:
            \(rawText)
            """
    }
}

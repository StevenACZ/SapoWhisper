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
            - Do not summarize, over-compress, simplify away constraints, or remove supporting details.
            - Do not add facts, examples, assumptions, conclusions, or answers.
            - Use only the raw transcript plus optional vocabulary/replacement hints.
            - Treat hints as optional recognition context, never as mandatory substitutions.
            - Apply a keyterm or replacement only when nearby words and the topic clearly support that exact term.
            - Ignore unrelated hints. If the transcript is about medicine, finance, personal plans, or another non-coding topic, do not introduce coding or AI terms from the hint lists.
            - Do not replace ordinary Spanish words with acronyms, product names, or technical abbreviations unless the raw transcript clearly points to that technical term.
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

            Optional user vocabulary keyterms:
            \(keytermBlock)

            Optional user replacement hints:
            \(replacementBlock)

            Raw transcript:
            \(rawText)
            """
    }
}

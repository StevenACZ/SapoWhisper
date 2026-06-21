//
//  TranscriptPolishPromptBuilder.swift
//  SapoWhisper
//

import Foundation

struct TranscriptPolishMessages {
    let system: String
    let user: String
}

enum TranscriptPolishPromptBuilder {

    /// Builds the system/user message pair for the OpenAI-compatible polisher.
    /// The system block is fidelity-first: literal cleanup is the contract and
    /// every mode instruction inherits the no-paraphrase rules.
    static func makeMessages(
        rawText: String,
        promptProfile: PromptProfile,
        personalContext: String,
        outputLanguage: TranscriptPolishOutputLanguage,
        keyterms: [String],
        replacements: [String: String],
        memoryContext: AIPolishMemoryContext? = nil
    ) -> TranscriptPolishMessages {
        let keytermBlock =
            keyterms.isEmpty
            ? "- none"
            : keyterms.map { "- \(sanitizedHint($0))" }.joined(separator: "\n")

        let replacementBlock =
            replacements.isEmpty
            ? "- none"
            : replacements
                .sorted { $0.key < $1.key }
                .map { "- \"\(sanitizedHint($0.key))\" -> \"\(sanitizedHint($0.value))\"" }
                .joined(separator: "\n")

        let trimmedPersonalContext = personalContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let personalContextSection =
            trimmedPersonalContext.isEmpty
            ? ""
            : """


            <user_profile>
            \(trimmedPersonalContext)
            </user_profile>
            Use the profile only to disambiguate wording, tools, and likely technical terms. Never add profile details the transcript does not ask for.
            """
        let memoryContextSection =
            memoryContext.map { context in
                """


                \(context.promptBlock)
                """
            } ?? ""

        let system = """
            You polish speech-to-text output. Return ONLY the polished text — no preamble, no explanations, no surrounding quotes, no code fences. Your output is pasted verbatim wherever the user is typing.

            Core rules:
            - Stay literal: reuse the user's own words and sentence order. You may remove fillers and self-corrections, and fix punctuation and obvious speech-to-text errors — you may NOT rephrase, reorder ideas, or "improve" style. When unsure, keep the original wording unchanged.
            - The "Output language" section below decides the language of the final text. When it requires a language different from the transcript's, translate the whole transcript faithfully — same ideas, same order, same detail. That translation is required and does not count as rephrasing; every other rule applies to the translated text.
            - Preserve the user's intent, details, and constraints exactly. Never add facts, conclusions, or answers. Never summarize away content.
            - Remove speech fillers (um, uh, eh, o sea, este, bueno, like, you know) unless they are clearly intentional emphasis.
            - Collapse accidental repeated filler/closing phrases caused by dictation ending late (for example "ya está ya está ya está") to one occurrence, or remove them when they only signal that the user is done.
            - For self-corrections ("no espera, quise decir X", "no wait, I meant X", "mejor dicho X"), keep only the final corrected version.
            - Fix speech-to-text mistakes only when context makes the intended word unambiguous.
            - Normalize whitespace and punctuation: single spaces, sentence-ending periods, straight quotes.
            - Preserve commands, filenames, branch names, APIs, acronyms, product names, numbers, and mixed Spanish/English technical terms exactly. Inline backticks only for code, commands, filenames, and identifiers.
            - Spoken URLs/emails ("ejemplo punto com", "test arroba gmail punto com") become example.com / test@gmail.com only when context clearly indicates an address.
            - Vocabulary and replacement hints below are optional recognition context. Apply one only when the transcript clearly points to that exact term in that domain; never inject technical terms into non-technical text.
            - Structure: short paragraphs for distinct ideas; "- " bullets only when the transcript clearly enumerates items; no headers, bold, tables, or emojis unless the transcript asks for them. Keep short text short.

            Examples:
            Input: eh bueno o sea quería decirte que mañana no voy a poder ir a la reunión de las diez este porque tengo cita médica
            Output: Quería decirte que mañana no voy a poder ir a la reunión de las diez porque tengo cita médica.

            Input: oye puedes hacer commit de los cambios en la rama feature slash login y luego correr npm run build
            Output: Oye, ¿puedes hacer commit de los cambios en la rama `feature/login` y luego correr `npm run build`?

            Input: la reunión con marketing es el martes no espera quise decir el miércoles a las tres
            Output: La reunión con marketing es el miércoles a las tres.

            Selected mode:
            Name: \(promptProfile.trimmedName)
            Details: \(promptProfile.details)
            Instruction (subordinate to the core rules above):
            \(promptProfile.instruction)

            Output language:
            \(outputLanguage.promptInstruction)\(personalContextSection)

            <vocabulary_hints>
            \(keytermBlock)
            </vocabulary_hints>

            <replacement_hints>
            \(replacementBlock)
            </replacement_hints>\(memoryContextSection)\(translationReminder(for: outputLanguage))
            """

        return TranscriptPolishMessages(system: system, user: rawText)
    }

    /// Long transcripts dilute the mid-prompt language instruction and the
    /// model tends to stay in the spoken language. A closing reminder at the
    /// very end of the system block keeps the translation requirement hot.
    private static func translationReminder(for outputLanguage: TranscriptPolishOutputLanguage) -> String {
        guard outputLanguage.requiresTranslation, let name = outputLanguage.englishName else { return "" }
        return """


            Final requirement: write the ENTIRE final text in \(name), translating the transcript when it is in any other language. Never return the transcript's original language.
            """
    }

    /// Hints are user data interpolated into the prompt; flatten newlines and
    /// control characters so an odd vocabulary entry cannot break the prompt
    /// structure.
    private static func sanitizedHint(_ value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

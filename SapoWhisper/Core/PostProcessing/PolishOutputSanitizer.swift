//
//  PolishOutputSanitizer.swift
//  SapoWhisper
//

import Foundation

/// Strips model wrapper noise (preambles, code fences, surrounding quotes)
/// from polished output before it is pasted. Low probability per request, but
/// when it happens the wrapper would land verbatim wherever the user types.
enum PolishOutputSanitizer {

    static func clean(_ output: String, rawText: String) -> String {
        let safeOutput = strippingUnsafeControlCharacters(from: output)
        var text = safeOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        // Output that is nothing but reasoning never reached an answer; there
        // is nothing usable to fall back to, so return empty and let the
        // pipeline keep the raw transcript. Restoring the wrapper-stripped
        // original here would paste the model's private reasoning verbatim.
        let startedWithThinking = text.hasPrefix("<think>")
        if startedWithThinking, text.range(of: "</think>") == nil {
            return ""
        }
        text = stripThinkingBlock(text)
        text = stripWrappingCodeFence(text)
        text = stripLeadingPreamble(text)
        text = stripTranscriptDelimiters(text)
        text = stripWrappingQuotes(text, rawText: rawText)
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.isEmpty else { return cleaned }
        return startedWithThinking ? "" : safeOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The polish guards are retry-only and the last output still ships after
    /// the retry budget, so this strip is the single boundary between provider
    /// output and the user's clipboard/paste: control bytes (ANSI/OSC escape
    /// sequences), bidi overrides, and invisible characters never survive.
    /// ZWJ/ZWNJ stay (emoji and legitimate scripts); `\n` and `\t` stay.
    private static func strippingUnsafeControlCharacters(from text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(normalized.unicodeScalars.count)
        for scalar in normalized.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A:
                scalars.append(scalar)
            case 0x0D:
                scalars.append("\n")
            case 0x00...0x1F, 0x7F, 0x80...0x9F:
                break  // C0 (ESC and friends), DEL, C1
            case 0x202A...0x202E, 0x2066...0x2069:
                break  // bidi embeddings/overrides/isolates
            case 0x200B, 0x2060, 0xFEFF:
                break  // zero-width space, word joiner, BOM
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Reasoning-tuned local models can leak a leading <think>…</think> block
    /// ahead of the answer; pasted verbatim it would flood the destination
    /// app with the model's private reasoning.
    private static func stripThinkingBlock(_ text: String) -> String {
        guard text.hasPrefix("<think>"), let closing = text.range(of: "</think>") else { return text }
        return String(text[closing.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes a fence that wraps the entire output (```...``` with an
    /// optional language tag); inner fences are left untouched.
    private static func stripWrappingCodeFence(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.count >= 2,
            lines.first?.hasPrefix("```") == true,
            lines.last?.trimmingCharacters(in: .whitespaces) == "```"
        else {
            return text
        }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n")
    }

    /// Removes a first line like "Here's the polished text:" when the actual
    /// content continues below it.
    private static func stripLeadingPreamble(_ text: String) -> String {
        guard let newlineIndex = text.firstIndex(of: "\n") else { return text }
        let firstLine = String(text[..<newlineIndex]).trimmingCharacters(in: .whitespaces)

        let pattern =
            #"(?i)^(here('|’)s|here is|this is|sure[,!]?|of course[,!]?|aqu(í|i) (está|esta|tienes)|este es|claro[,!]?)?\s*"#
            + #"(the |el |la )?(polished|final|cleaned|improved|texto|transcript(o)?)\b[^:\n]{0,40}:$"#
        guard firstLine.range(of: pattern, options: .regularExpression) != nil else { return text }
        return String(text[text.index(after: newlineIndex)...])
    }

    /// Some small local models echo the transcript wrapper back. Keep only the
    /// polished text between the known delimiters when they wrap the answer.
    private static func stripTranscriptDelimiters(_ text: String) -> String {
        let start = TranscriptPolishPromptBuilder.transcriptStartDelimiter
        let end = TranscriptPolishPromptBuilder.transcriptEndDelimiter
        guard
            let startRange = text.range(of: start),
            let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex)
        else {
            return text
        }

        let inner = text[startRange.upperBound..<endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? text : inner
    }

    /// Removes one layer of symmetric quotes when they wrap the whole output
    /// and the raw transcript itself was not quoted. Text with interior
    /// closing quotes is left alone: in `"Guardar" y "Cancelar"` the outer
    /// pair belongs to two separate quoted spans, and stripping it would
    /// corrupt both.
    private static func stripWrappingQuotes(_ text: String, rawText: String) -> String {
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’"), ("«", "»")]
        guard let first = text.first, let last = text.last, text.count >= 2 else { return text }

        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawIsQuoted = pairs.contains { raw.first == $0.0 && raw.last == $0.1 }
        guard !rawIsQuoted else { return text }

        for (opening, closing) in pairs where first == opening && last == closing {
            let inner = text.dropFirst().dropLast()
            guard !inner.contains(closing) else { return text }
            return String(inner)
        }
        return text
    }
}

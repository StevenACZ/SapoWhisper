//
//  RecentDictationContext.swift
//  SapoWhisper
//

import Foundation

/// Short window of the user's latest completed dictations, fed to the AI
/// polish prompt so consecutive short dictations keep their shared topic and
/// terminology (the "continuity" the raw transcript alone loses). The packet
/// stays deliberately tiny — small local models get confused by long context,
/// so this favors the freshest entries and a hard character budget.
enum RecentDictationContext {
    static let maxAge: TimeInterval = 30 * 60
    static let maxEntries = 4
    static let maxTotalCharacters = 700
    /// A single rambling dictation must not eat the whole budget.
    static let maxEntryCharacters = 260

    /// Builds the oldest-first context lines from history entries (newest
    /// first, as `fetchEntries` returns them). Only successful dictations with
    /// usable text within the age window participate.
    static func contextLines(
        from entries: [HistoryEntry],
        now: Date = Date()
    ) -> [String] {
        var lines: [String] = []
        var totalCharacters = 0

        for entry in entries {
            guard lines.count < maxEntries else { break }
            guard entry.status == "completed" else { continue }
            guard now.timeIntervalSince(entry.timestamp) <= maxAge, entry.timestamp <= now else { continue }

            let text = sanitizedLine(entry.text)
            guard !text.isEmpty else { continue }
            guard totalCharacters + text.count <= maxTotalCharacters else { break }

            totalCharacters += text.count
            lines.append(text)
        }

        return lines.reversed()
    }

    /// Flattens a dictation into one prompt-safe line, clipped to the entry
    /// budget on a word boundary with an ellipsis.
    static func sanitizedLine(_ text: String) -> String {
        let flattened =
            text
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard flattened.count > maxEntryCharacters else { return flattened }

        let clipped = String(flattened.prefix(maxEntryCharacters))
        if let lastSpace = clipped.range(of: " ", options: .backwards) {
            return String(clipped[..<lastSpace.lowerBound]) + "…"
        }
        return clipped + "…"
    }
}

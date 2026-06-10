//
//  PromptContextManager.swift
//  SapoWhisper
//

import Combine
import Foundation

struct PersonalPromptContext: Codable, Equatable {
    var details: String

    static let empty = PersonalPromptContext(details: "")

    private enum CodingKeys: String, CodingKey {
        case details
    }
}

struct PromptProfile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var details: String
    var instruction: String
    var forcesEnglish: Bool

    var trimmedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled prompt" : trimmed
    }
}

struct PromptContextSnapshot: Codable, Equatable {
    var personalContext: PersonalPromptContext
    var prompts: [PromptProfile]
}

final class PromptContextManager: ObservableObject {
    static let shared = PromptContextManager()

    @Published private(set) var personalContext: PersonalPromptContext = .empty
    @Published private(set) var prompts: [PromptProfile] = []

    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("SapoWhisper")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        fileURL = appDir.appendingPathComponent("prompt_context.json")
        load()
    }

    func updatePersonalContext(details: String) {
        personalContext = PersonalPromptContext(
            details: Self.sanitizedMultiline(details, limit: 2_000)
        )
        save()
    }

    func upsertPrompt(_ prompt: PromptProfile) {
        var sanitized = prompt
        sanitized.name = Self.sanitizedSingleLine(prompt.name, fallback: "Untitled prompt", limit: 60)
        sanitized.details = Self.sanitizedMultiline(prompt.details, limit: 600)
        sanitized.instruction = Self.sanitizedMultiline(prompt.instruction, limit: 1_600)

        guard !sanitized.instruction.isEmpty else { return }

        if let index = prompts.firstIndex(where: { $0.id == sanitized.id }) {
            prompts[index] = sanitized
        } else {
            prompts.append(sanitized)
        }
        save()
    }

    func removePrompt(id: String) {
        guard prompts.count > 1 else { return }
        prompts.removeAll { $0.id == id }
        repairSelectedPromptIfNeeded()
        save()
    }

    func promptProfile(for id: String?) -> PromptProfile {
        if let id, let prompt = prompts.first(where: { $0.id == id }) {
            return prompt
        }
        if let fallback = prompts.first(where: { $0.id == TranscriptPolishMode.automatic.rawValue }) {
            return fallback
        }
        return prompts.first ?? Self.defaultPrompts[0]
    }

    func snapshot() -> PromptContextSnapshot {
        PromptContextSnapshot(personalContext: personalContext, prompts: prompts)
    }

    func replace(with snapshot: PromptContextSnapshot) {
        personalContext = PersonalPromptContext(
            details: Self.sanitizedMultiline(snapshot.personalContext.details, limit: 2_000)
        )

        let sanitizedPrompts = snapshot.prompts.compactMap { prompt -> PromptProfile? in
            var sanitized = prompt
            sanitized.id = prompt.id.trimmingCharacters(in: .whitespacesAndNewlines)
            sanitized.name = Self.sanitizedSingleLine(prompt.name, fallback: "Untitled prompt", limit: 60)
            sanitized.details = Self.sanitizedMultiline(prompt.details, limit: 600)
            sanitized.instruction = Self.sanitizedMultiline(prompt.instruction, limit: 1_600)
            guard !sanitized.id.isEmpty, !sanitized.instruction.isEmpty else { return nil }
            return Self.upgradedLegacyDefault(sanitized)
        }

        prompts = sanitizedPrompts.isEmpty ? Self.defaultPrompts : sanitizedPrompts
        repairSelectedPromptIfNeeded()
        save()
    }

    /// Built-in profiles whose stored instruction still matches a superseded
    /// default are refreshed to the current fidelity-first wording. Profiles
    /// the user edited are never touched.
    private static func upgradedLegacyDefault(_ prompt: PromptProfile) -> PromptProfile {
        guard let legacyInstructions = legacyDefaultInstructions[prompt.id],
            legacyInstructions.contains(prompt.instruction),
            let fresh = defaultPrompts.first(where: { $0.id == prompt.id })
        else {
            return prompt
        }
        var upgraded = prompt
        upgraded.details = fresh.details
        upgraded.instruction = fresh.instruction
        return upgraded
    }

    func makePersonalContextBlock() -> String {
        let details = personalContext.details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !details.isEmpty else { return "" }

        return """
            User profile:
            \(details)
            """
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
            let snapshot = try? JSONDecoder().decode(PromptContextSnapshot.self, from: data)
        else {
            personalContext = .empty
            prompts = Self.defaultPrompts
            save()
            return
        }

        replace(with: snapshot)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot()) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func repairSelectedPromptIfNeeded() {
        let selectedID = UserDefaults.standard.string(forKey: Constants.StorageKeys.aiPolishMode)
        guard selectedID == nil || prompts.contains(where: { $0.id == selectedID }) else {
            UserDefaults.standard.set(promptProfile(for: nil).id, forKey: Constants.StorageKeys.aiPolishMode)
            return
        }
    }

    private static func sanitizedSingleLine(_ value: String, fallback: String, limit: Int) -> String {
        let trimmed =
            value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let output = trimmed.isEmpty ? fallback : trimmed
        return String(output.prefix(limit))
    }

    private static func sanitizedMultiline(_ value: String, limit: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    static let defaultPrompts: [PromptProfile] = [
        PromptProfile(
            id: TranscriptPolishMode.automatic.rawValue,
            name: "Clean-up (literal)",
            details: "Removes fillers and fixes punctuation — nothing else.",
            instruction:
                "Keep the text literal: remove fillers and self-corrections, fix punctuation and obvious speech-to-text mistakes, and change nothing else. Never paraphrase; reuse the user's own words and sentence order — translated faithfully when the output language requires another language. Use short paragraphs for distinct ideas and \"- \" bullets only when the transcript clearly enumerates items. Never invent labels or headers. Keep formatting plain.",
            forcesEnglish: false
        ),
        PromptProfile(
            id: TranscriptPolishMode.ai.rawValue,
            name: "AI Assistant Prompt",
            details: "Turns dictation into a clear request for coding or reasoning assistants.",
            instruction:
                "Optimize the text for pasting into an AI assistant without rephrasing the user's words. Keep the user's intent exact, make requests and constraints easy to parse, preserve technical terms, and use bullets only when they clarify tasks or requirements. Prefer compact plain labels only when the transcript clearly contains those ideas.",
            forcesEnglish: false
        ),
        PromptProfile(
            id: TranscriptPolishMode.work.rawValue,
            name: "Work Message",
            details: "Polishes Slack, email, and teammate messages.",
            instruction:
                "Optimize the text for a work message such as Slack or email. Keep it natural and easy to read while preserving the user's original wording, intent, and tone — trim fillers, do not rewrite. Avoid Markdown emphasis unless the user explicitly asks for formatted Markdown.",
            forcesEnglish: false
        ),
        PromptProfile(
            id: TranscriptPolishMode.translateEnglish.rawValue,
            name: "Translate to English",
            details: "Translates the final transcript to clear English.",
            instruction:
                "Translate the user's text to clear English while preserving the original intent exactly. Do not add details. Keep technical terms, commands, filenames, and product names precise. Keep the output plain unless formatting is necessary for readability.",
            forcesEnglish: true
        ),
    ]

    /// Superseded built-in instruction texts, used to auto-upgrade stored
    /// profiles that were never customized by the user.
    private static let legacyDefaultInstructions: [String: [String]] = [
        TranscriptPolishMode.automatic.rawValue: [
            "Choose the most natural compact format for the text. Use short paragraphs for thoughts, bullets for tasks or lists, and inline code formatting for commands, files, branch names, APIs, and product names. Keep formatting plain and avoid emphasis markers.",
            "Keep the text literal: remove fillers and self-corrections, fix punctuation and obvious speech-to-text mistakes, and change nothing else. Never paraphrase; reuse the user's own words and sentence order. Use short paragraphs for distinct ideas and \"- \" bullets only when the transcript clearly enumerates items. Never invent labels or headers. Keep formatting plain.",
        ],
        TranscriptPolishMode.ai.rawValue: [
            "Optimize the text for pasting into an AI assistant. Keep the user's intent exact, make requests and constraints easy to parse, preserve technical terms, and use bullets only when they clarify tasks or requirements. Prefer compact plain labels only when the transcript clearly contains those ideas."
        ],
        TranscriptPolishMode.work.rawValue: [
            "Optimize the text for a work message such as Slack or email. Make it concise, clear, and natural while preserving the user's original intent and tone. Avoid Markdown emphasis unless the user explicitly asks for formatted Markdown."
        ],
    ]
}

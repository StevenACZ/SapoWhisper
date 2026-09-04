//
//  PromptContextManager.swift
//  SapoWhisper
//

import Foundation
import Observation

struct PersonalPromptContext: Codable, Equatable {
    var details: String

    static let empty = PersonalPromptContext(details: "")

    private enum CodingKeys: String, CodingKey {
        case details
    }
}

/// The single optional free-text block the user can add to the polish prompt:
/// who they are and which tools they use, so the model disambiguates technical
/// terms. Mode/prompt profiles were removed — the polish prompt is a single
/// adaptive contract (see TranscriptPolishPromptBuilder).
@Observable
final class PromptContextManager {
    static let shared = PromptContextManager()

    private(set) var personalContext: PersonalPromptContext = .empty

    private let fileURL: URL

    private init() {
        let appDir = AppRuntimePaths.applicationSupport
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

    func snapshot() -> PromptContextSnapshot {
        PromptContextSnapshot(personalContext: personalContext)
    }

    func replace(with snapshot: PromptContextSnapshot) {
        personalContext = PersonalPromptContext(
            details: Self.sanitizedMultiline(snapshot.personalContext.details, limit: 2_000)
        )
        save()
    }

    private func load() {
        // Older files carry a "prompts" array from the removed profile
        // system; the decoder ignores it and only the personal context stays.
        guard let data = try? Data(contentsOf: fileURL),
            let snapshot = try? JSONDecoder().decode(PromptContextSnapshot.self, from: data)
        else {
            personalContext = .empty
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

    private static func sanitizedMultiline(_ value: String, limit: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}

struct PromptContextSnapshot: Codable, Equatable {
    var personalContext: PersonalPromptContext

    private enum CodingKeys: String, CodingKey {
        case personalContext
    }
}

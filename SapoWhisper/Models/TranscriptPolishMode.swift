//
//  TranscriptPolishMode.swift
//  SapoWhisper
//

import Foundation

enum TranscriptPolishMode: String, CaseIterable, Identifiable {
    case automatic
    case ai
    case work
    case translateEnglish = "translate_english"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            return "ai.mode.automatic".localized
        case .ai:
            return "ai.mode.ai".localized
        case .work:
            return "ai.mode.work".localized
        case .translateEnglish:
            return "ai.mode.translate_english".localized
        }
    }

    var promptInstruction: String {
        switch self {
        case .automatic:
            return """
                Choose the most natural compact format for the text. Use short paragraphs for thoughts, bullets for tasks or lists, and inline code formatting for commands, files, branch names, APIs, and product names.
                """
        case .ai:
            return """
                Optimize the text for pasting into an AI assistant. Keep the user's intent exact, make requests and constraints easy to parse, preserve technical terms, and use bullets only when they clarify tasks or requirements.
                """
        case .work:
            return """
                Optimize the text for a work message such as Slack or email. Make it concise, clear, and natural while preserving the user's original intent and tone.
                """
        case .translateEnglish:
            return """
                Translate the user's text to clear English while preserving the original intent exactly. Do not add details. Keep technical terms, commands, filenames, and product names precise.
                """
        }
    }
}

enum TranscriptAIStatus: String {
    case none
    case applied
    case skippedShort = "skipped_short"
    case failed

    var displayName: String {
        switch self {
        case .none:
            return "ai.status.none".localized
        case .applied:
            return "ai.status.applied".localized
        case .skippedShort:
            return "ai.status.skipped_short".localized
        case .failed:
            return "ai.status.failed".localized
        }
    }
}

struct TranscriptAIResult {
    let rawText: String
    let finalText: String
    let status: TranscriptAIStatus
    let model: String?
    let mode: TranscriptPolishMode?
    let error: String?
    let elapsedMs: Int
}

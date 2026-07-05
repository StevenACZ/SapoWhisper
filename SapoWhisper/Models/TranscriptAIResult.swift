//
//  TranscriptAIResult.swift
//  SapoWhisper
//

import Foundation

enum TranscriptAIStatus: String {
    case none
    case applied
    // skipped_short / skipped_duration are no longer produced (polish always
    // runs when enabled) but stay parseable for old history rows.
    case skippedShort = "skipped_short"
    case skippedDuration = "skipped_duration"
    case rejectedFidelity = "rejected_fidelity"
    case failed

    var displayName: String {
        switch self {
        case .none:
            return "ai.status.none".localized
        case .applied:
            return "ai.status.applied".localized
        case .skippedShort:
            return "ai.status.skipped_short".localized
        case .skippedDuration:
            return "ai.status.skipped_duration".localized
        case .rejectedFidelity:
            return "ai.status.rejected_fidelity".localized
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
    let mode: String?
    let error: String?
    let elapsedMs: Int
}

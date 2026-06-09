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
}

enum TranscriptPolishMinimumDuration: String, CaseIterable, Identifiable {
    case always
    case seconds20 = "20"
    case seconds30 = "30"

    static let defaultPolicy: TranscriptPolishMinimumDuration = .seconds30

    var id: String { rawValue }

    var minimumSeconds: TimeInterval? {
        switch self {
        case .always:
            return nil
        case .seconds20:
            return 20
        case .seconds30:
            return 30
        }
    }

    var displayName: String {
        switch self {
        case .always:
            return "ai.polish.minimum_duration.always".localized
        case .seconds20:
            return "ai.polish.minimum_duration.20".localized
        case .seconds30:
            return "ai.polish.minimum_duration.30".localized
        }
    }

    var description: String {
        switch self {
        case .always:
            return "ai.polish.minimum_duration_desc.always".localized
        case .seconds20:
            return "ai.polish.minimum_duration_desc.20".localized
        case .seconds30:
            return "ai.polish.minimum_duration_desc.30".localized
        }
    }
}

enum TranscriptAIStatus: String {
    case none
    case applied
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

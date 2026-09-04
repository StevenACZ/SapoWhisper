import Foundation

nonisolated enum HistoryEntryStatus: String, CaseIterable, Sendable {
    case transcribing
    case polishing
    case completed
    case failed

    var isProcessing: Bool { self == .transcribing || self == .polishing }

    static let processingSQLValues =
        "("
        + allCases.filter(\.isProcessing)
        .map { "'\($0.rawValue)'" }.joined(separator: ",") + ")"

    var titleKey: String {
        switch self {
        case .transcribing: return "history.transcribing"
        case .polishing: return "history.polishing"
        case .completed: return "history.completed"
        case .failed: return "history.failed"
        }
    }

    var symbol: String {
        switch self {
        case .transcribing: return "waveform.badge.magnifyingglass"
        case .polishing: return "wand.and.stars"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

nonisolated extension HistoryEntry {
    var entryStatus: HistoryEntryStatus? { HistoryEntryStatus(rawValue: status) }
    var isProcessing: Bool { entryStatus?.isProcessing == true }

    var failureKind: TranscriptionFailure.Kind? {
        guard entryStatus == .failed, let failureCode else { return nil }
        let code = String(failureCode.split(separator: "/").last ?? "")
        if code == "interrupted_transcription" || code == "recovered_after_crash" { return .recordingInterrupted }
        return TranscriptionFailure.Kind(rawValue: code)
    }

    @MainActor var failureDescription: String {
        TranscriptionFailure(kind: failureKind ?? .unknown, engine: displayEngineName).localizedDescription
    }
}

//
//  HistoryEntry.swift
//  SapoWhisper
//

import Foundation

nonisolated struct HistoryEntry: Identifiable, Hashable {
    let id: Int64
    let timestamp: Date
    let engine: String
    let language: String
    let duration: TimeInterval
    let text: String
    let rawText: String
    let audioPath: String?
    let status: String
    let aiStatus: String
    let aiModel: String?
    let aiMode: String?
    let aiError: String?
    var isFavorite: Bool
    /// H7: semantic `TranscriptionFailure` code (e.g. "ElevenLabs/auth") for failed rows.
    var failureCode: String? = nil
    /// H10: first applied polish, preserved when a re-polish overwrites ai_*.
    var aiFirstStatus: String? = nil
    var aiFirstModel: String? = nil
    var aiFirstMode: String? = nil

    var wordCount: Int {
        text.split(separator: " ").count
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var audioFileExists: Bool {
        guard let path = audioPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    var transcriptAIStatus: TranscriptAIStatus {
        TranscriptAIStatus(rawValue: aiStatus) ?? .none
    }

    /// UI-only. Modes were removed (single adaptive polish); the map keeps
    /// old history rows readable.
    @MainActor var aiModeDisplayName: String? {
        guard let aiMode, !aiMode.isEmpty else { return nil }
        switch aiMode {
        case "automatic":
            return "ai.mode.automatic".localized
        case "ai":
            return "ai.mode.ai".localized
        case "work":
            return "ai.mode.work".localized
        case "translate_english":
            return "ai.mode.translate_english".localized
        case "voice_edit", "clipboard_edit":
            return "overlay.edit_mode".localized
        default:
            return aiMode
        }
    }

    var hasRawTranscript: Bool {
        !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isUserCancelled: Bool {
        guard status == "failed" else { return false }
        let cancelledCode = TranscriptionFailure.Kind.userCancelled.rawValue
        return failureCode == cancelledCode || failureCode?.hasSuffix("/\(cancelledCode)") == true
    }

    var displayEngineName: String {
        switch engine.lowercased() {
        case let value where value.contains("local ai"):
            return "Local AI Server"
        case let value where value.contains("deepgram"):
            return "Deepgram"
        case let value where value.contains("google"):
            return "Google Cloud"
        case let value where value.contains("gemini"):
            return "Gemini Audio"
        case let value where value.contains("whisper"):
            return "Whisper"
        case let value where value.contains("apple"):
            return "Apple Speech"
        default:
            return engine.capitalized
        }
    }
}

// MARK: - Date Grouping

enum DateGroup: String, CaseIterable {
    case pinned
    case today
    case yesterday
    case thisWeek
    case thisMonth
    case older

    var localizedTitle: String {
        switch self {
        case .pinned: return "history.pinned".localized
        case .today: return "history.today".localized
        case .yesterday: return "history.yesterday".localized
        case .thisWeek: return "history.this_week".localized
        case .thisMonth: return "history.this_month".localized
        case .older: return "history.older".localized
        }
    }
}

// MARK: - Engine Filter

enum EngineFilter: String, CaseIterable, Identifiable {
    case all
    case whisper
    case localAI = "local_ai"
    case deepgram
    case elevenLabs = "elevenlabs"
    /// Entries from engines that no longer exist (Apple, Google, Gemini, ...).
    /// History is data: old rows stay readable under this bucket.
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "history.filter_all".localized
        case .whisper: return "history.filter_whisper".localized
        case .localAI: return "history.filter_local_ai".localized
        case .deepgram: return "history.filter_deepgram".localized
        case .elevenLabs: return "history.filter_elevenlabs".localized
        case .other: return "history.filter_other".localized
        }
    }

    var iconName: String {
        switch self {
        case .all: return "line.3.horizontal.decrease.circle"
        case .whisper: return "waveform"
        case .localAI: return "server.rack"
        case .deepgram: return "waveform.badge.mic"
        case .elevenLabs: return "waveform.badge.magnifyingglass"
        case .other: return "archivebox"
        }
    }

    func matches(_ engine: String) -> Bool {
        let lowercased = engine.lowercased()
        switch self {
        case .all:
            return true
        case .whisper:
            return lowercased.contains("whisper")
        case .localAI:
            return lowercased.contains("local ai")
        case .deepgram:
            return lowercased.contains("deepgram")
        case .elevenLabs:
            return lowercased.contains("elevenlabs")
        case .other:
            return !lowercased.contains("whisper") && !lowercased.contains("local ai") && !lowercased.contains("deepgram")
                && !lowercased.contains("elevenlabs")
        }
    }
}

// MARK: - Mock Data

extension HistoryEntry {
    static let mockData: [HistoryEntry] = [
        HistoryEntry(
            id: 1, timestamp: Date().addingTimeInterval(-300), engine: "Deepgram Nova-3", language: "es", duration: 8.5,
            text: "Hola, esta es una prueba de transcripción con el modelo Deepgram en tiempo real",
            rawText: "hola esta es una prueba de transcripción con el modelo deep green en tiempo real",
            audioPath: "/audio/test1.wav", status: "completed", aiStatus: "applied",
            aiModel: "gemini-3.1-flash-lite", aiMode: "automatic", aiError: nil, isFavorite: false),
        HistoryEntry(
            id: 2, timestamp: Date().addingTimeInterval(-3600), engine: "Google Chirp 3", language: "es", duration: 15.2,
            text: "El clima de hoy está muy agradable, perfecto para salir a caminar por el parque",
            rawText: "El clima de hoy está muy agradable perfecto para salir a caminar por el parque",
            audioPath: "/audio/test2.wav", status: "completed", aiStatus: "none", aiModel: nil, aiMode: nil, aiError: nil,
            isFavorite: false),
        HistoryEntry(
            id: 3, timestamp: Date().addingTimeInterval(-7200), engine: "WhisperKit", language: "en", duration: 5.0,
            text: "This is a test of the local WhisperKit model running on Apple Silicon",
            rawText: "This is a test of the local WhisperKit model running on Apple Silicon", audioPath: nil,
            status: "completed", aiStatus: "none", aiModel: nil, aiMode: nil, aiError: nil, isFavorite: false),
        HistoryEntry(
            id: 4, timestamp: Date().addingTimeInterval(-86400), engine: "Deepgram Nova-3", language: "es", duration: 3.1, text: "",
            rawText: "", audioPath: "/audio/test4.wav", status: "failed", aiStatus: "none", aiModel: nil, aiMode: nil,
            aiError: nil, isFavorite: false),
        HistoryEntry(
            id: 5, timestamp: Date().addingTimeInterval(-172800), engine: "Apple Speech", language: "es", duration: 12.0,
            text: "Recordar comprar leche, pan y huevos para la cena de esta noche",
            rawText: "Recordar comprar leche pan y huevos para la cena de esta noche", audioPath: nil, status: "completed",
            aiStatus: "skipped_short", aiModel: nil, aiMode: "automatic", aiError: nil, isFavorite: true),
    ]
}

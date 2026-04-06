//
//  HistoryEntry.swift
//  SapoWhisper
//

import Foundation

struct HistoryEntry: Identifiable, Hashable {
    let id: Int64
    let timestamp: Date
    let engine: String
    let language: String
    let duration: TimeInterval
    let text: String
    let audioPath: String?
    let status: String
    var isFavorite: Bool

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
    case deepgram
    case google
    case whisper
    case apple

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .deepgram: return "DG"
        case .google: return "GC"
        case .whisper: return "WK"
        case .apple: return "AS"
        }
    }

    func matches(_ engine: String) -> Bool {
        switch self {
        case .all: return true
        case .deepgram: return engine.lowercased().contains("deepgram")
        case .google: return engine.lowercased().contains("google")
        case .whisper: return engine.lowercased().contains("whisper")
        case .apple: return engine.lowercased().contains("apple")
        }
    }
}

// MARK: - Mock Data

extension HistoryEntry {
    static let mockData: [HistoryEntry] = [
        HistoryEntry(id: 1, timestamp: Date().addingTimeInterval(-300), engine: "Deepgram Nova-3", language: "es", duration: 8.5, text: "Hola, esta es una prueba de transcripción con el modelo Deepgram en tiempo real", audioPath: "/audio/test1.wav", status: "completed", isFavorite: false),
        HistoryEntry(id: 2, timestamp: Date().addingTimeInterval(-3600), engine: "Google Chirp 3", language: "es", duration: 15.2, text: "El clima de hoy está muy agradable, perfecto para salir a caminar por el parque", audioPath: "/audio/test2.wav", status: "completed", isFavorite: false),
        HistoryEntry(id: 3, timestamp: Date().addingTimeInterval(-7200), engine: "WhisperKit", language: "en", duration: 5.0, text: "This is a test of the local WhisperKit model running on Apple Silicon", audioPath: nil, status: "completed", isFavorite: false),
        HistoryEntry(id: 4, timestamp: Date().addingTimeInterval(-86400), engine: "Deepgram Nova-3", language: "es", duration: 3.1, text: "", audioPath: "/audio/test4.wav", status: "failed", isFavorite: false),
        HistoryEntry(id: 5, timestamp: Date().addingTimeInterval(-172800), engine: "Apple Speech", language: "es", duration: 12.0, text: "Recordar comprar leche, pan y huevos para la cena de esta noche", audioPath: nil, status: "completed", isFavorite: true),
    ]
}

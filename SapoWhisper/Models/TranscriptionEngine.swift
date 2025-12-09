//
//  TranscriptionEngine.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import Foundation

/// Motor de transcripción disponible
enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case appleOnline = "apple"
    case whisperLocal = "whisper"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleOnline:
            return "Apple (Online)"
        case .whisperLocal:
            return "Whisper (Local)"
        }
    }

    var description: String {
        switch self {
        case .appleOnline:
            return "engine.apple.description".localized
        case .whisperLocal:
            return "engine.whisper.description".localized
        }
    }

    var icon: String {
        switch self {
        case .appleOnline:
            return "icloud"
        case .whisperLocal:
            return "desktopcomputer"
        }
    }

    var requiresInternet: Bool {
        switch self {
        case .appleOnline:
            return true
        case .whisperLocal:
            return false
        }
    }
}

/// Modelos de WhisperKit optimizados para Apple Silicon
enum WhisperKitModel: String, CaseIterable, Identifiable {
    case tiny = "openai_whisper-tiny"
    case base = "openai_whisper-base"
    case small = "openai_whisper-small"
    case largev3 = "openai_whisper-large-v3"
    case largev3Turbo = "openai_whisper-large-v3_turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .largev3: return "Large V3"
        case .largev3Turbo: return "Large V3 Turbo"
        }
    }

    var fileSize: String {
        switch self {
        case .tiny: return "76.6 MB"
        case .base: return "146.7 MB"
        case .small: return "486.5 MB"
        case .largev3: return "3.09 GB"
        case .largev3Turbo: return "3.2 GB"
        }
    }

    var sizeInBytes: Int64 {
        switch self {
        case .tiny: return Int64(76.6 * 1024 * 1024)
        case .base: return Int64(146.7 * 1024 * 1024)
        case .small: return Int64(486.5 * 1024 * 1024)
        case .largev3: return Int64(3.09 * 1024 * 1024 * 1024)
        case .largev3Turbo: return Int64(3.2 * 1024 * 1024 * 1024)
        }
    }

    var speed: String {
        switch self {
        case .tiny: return "model.speed.very_fast".localized
        case .base: return "model.speed.fast".localized
        case .small: return "model.speed.moderate".localized
        case .largev3: return "model.speed.slow".localized
        case .largev3Turbo: return "model.speed.fast".localized
        }
    }

    var accuracy: Int {
        switch self {
        case .tiny: return 2
        case .base: return 3
        case .small: return 4
        case .largev3: return 5
        case .largev3Turbo: return 5
        }
    }

    var isRecommended: Bool {
        self == .small || self == .largev3Turbo
    }

    var recommendedFor: String {
        switch self {
        case .tiny: return "Pruebas rapidas"
        case .base: return "Uso diario basico"
        case .small: return "Mejor balance"
        case .largev3: return "Maxima precision"
        case .largev3Turbo: return "Precision + Velocidad"
        }
    }
}

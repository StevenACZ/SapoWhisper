//
//  AppState.swift
//  SapoWhisper
//
//

import SwiftUI

/// Typed error payload so the overlay, menu bar, and sounds derive their
/// behavior (dismiss time, retry button, sound) from the failure kind instead
/// of ad-hoc decisions at every call site.
struct ErrorState: Equatable {
    let kind: TranscriptionFailure.Kind
    let isRetryable: Bool
    let message: String

    init(failure: TranscriptionFailure) {
        self.kind = failure.kind
        self.isRetryable = failure.isRetryable
        self.message = failure.errorDescription ?? failure.diagnosticCode
    }

    init(message: String) {
        self.kind = .unknown
        self.isRetryable = false
        self.message = message
    }

    /// No-speech gets gentle treatment: short overlay, no retry, no error sound.
    var isNoSpeech: Bool { kind == .emptyTranscription }
}

/// Estados posibles de la aplicación
enum AppState: Equatable {
    case idle  // Verde - Listo para grabar
    case recording  // Rojo - Grabando audio
    case processing  // Amarillo - Transcribiendo
    case polishing  // Azul - Mejorando con IA
    case error(ErrorState)  // Naranja - Error
    case noModel  // Gris - Sin modelo instalado

    var statusText: String {
        switch self {
        case .idle:
            return "menu.ready".localized
        case .recording:
            return "status.recording_generic".localized
        case .processing:
            return "menu.transcribing".localized
        case .polishing:
            return "menu.ai_polishing".localized
        case .error(let state):
            return "status.error".localized(state.message)
        case .noModel:
            return "status.no_model".localized
        }
    }

    var diagnosticName: String {
        switch self {
        case .idle:
            return "idle"
        case .recording:
            return "recording"
        case .processing:
            return "processing"
        case .polishing:
            return "polishing"
        case .error:
            return "error"
        case .noModel:
            return "noModel"
        }
    }

    var iconName: String {
        switch self {
        case .idle:
            return "waveform.circle.fill"
        case .recording:
            return "record.circle.fill"
        case .processing:
            return "ellipsis.circle.fill"
        case .polishing:
            return "wand.and.stars"
        case .error:
            return "exclamationmark.circle.fill"
        case .noModel:
            return "arrow.down.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .idle:
            return Color(red: 0.298, green: 0.686, blue: 0.314)  // #4CAF50
        case .recording:
            return Color(red: 0.957, green: 0.263, blue: 0.212)  // #F44336
        case .processing:
            return Color(red: 1.0, green: 0.757, blue: 0.027)  // #FFC107
        case .polishing:
            return .aiPolish
        case .error:
            return Color(red: 1.0, green: 0.596, blue: 0.0)  // #FF9800
        case .noModel:
            return Color(red: 0.620, green: 0.620, blue: 0.620)  // #9E9E9E
        }
    }

    var isBusyProcessing: Bool {
        switch self {
        case .processing, .polishing:
            return true
        default:
            return false
        }
    }
}

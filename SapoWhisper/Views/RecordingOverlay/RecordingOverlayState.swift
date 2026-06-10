//
//  RecordingOverlayState.swift
//  SapoWhisper
//
//  Created by Claude on 9/12/24.
//

import Foundation

/// Estados posibles de la ventana de overlay durante grabacion/transcripcion
enum RecordingOverlayState: Equatable {
    case hidden
    case recording(duration: TimeInterval)
    case paused(duration: TimeInterval)
    case transcribing
    case polishing(timeoutSeconds: UInt64)
    case completed(text: String)
    case error(message: String, isRetryable: Bool)
    case deviceDetected(deviceName: String)
    /// Identifies the state type (ignoring associated values) for animation triggers
    var stateCategory: String {
        switch self {
        case .hidden: return "hidden"
        case .recording: return "recording"
        case .paused: return "paused"
        case .transcribing: return "transcribing"
        case .polishing: return "polishing"
        case .completed: return "completed"
        case .error: return "error"
        case .deviceDetected: return "deviceDetected"
        }
    }

    var isVisible: Bool {
        switch self {
        case .hidden:
            return false
        default:
            return true
        }
    }

    var statusText: String {
        switch self {
        case .hidden:
            return ""
        case .recording:
            return "overlay.recording".localized
        case .paused:
            return "overlay.paused".localized
        case .transcribing:
            return "overlay.transcribing".localized
        case .polishing:
            return "overlay.ai_polishing".localized
        case .completed:
            return "overlay.completed".localized
        case .error(let message, _):
            return message
        case .deviceDetected(let name):
            return name
        }
    }
}

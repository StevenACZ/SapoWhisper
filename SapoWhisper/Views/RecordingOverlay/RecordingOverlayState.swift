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
    /// Idle mini chip at the anchor position; hovering it reopens the last
    /// transcription, and every dismissed state collapses back into it.
    case docked
    case recording(duration: TimeInterval)
    case paused(duration: TimeInterval)
    case transcribing
    case polishing(timeoutSeconds: UInt64)
    /// Compact post-dictation toast: the text already landed at the caret
    /// (auto-paste) and on the clipboard, so the overlay only confirms and
    /// collapses; the dock chip reopens the full transcript on demand.
    case copied
    case completed(text: String)
    case cancelled
    case error(message: String, isRetryable: Bool)
    case deviceChange(DeviceChangeAnnouncement)
    /// Identifies the state type (ignoring associated values) for animation triggers
    var stateCategory: String {
        switch self {
        case .hidden: return "hidden"
        case .docked: return "docked"
        case .recording: return "recording"
        case .paused: return "paused"
        case .transcribing: return "transcribing"
        case .polishing: return "polishing"
        case .copied: return "copied"
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        case .error: return "error"
        case .deviceChange: return "deviceChange"
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
        case .hidden, .docked:
            return ""
        case .recording:
            return "overlay.recording".localized
        case .paused:
            return "overlay.paused".localized
        case .transcribing:
            return "overlay.transcribing".localized
        case .polishing:
            return "overlay.ai_polishing".localized
        case .copied:
            return "overlay.copied".localized
        case .completed:
            return "overlay.completed".localized
        case .cancelled:
            return "overlay.cancelled_saved".localized
        case .error(let message, _):
            return message
        case .deviceChange(let announcement):
            return announcement.deviceName
        }
    }
}

//
//  RecordingOverlayState.swift
//  SapoWhisper
//
//  Created by Claude on 9/12/24.
//

import Foundation

/// What the post-dictation "Copied" toast should confirm beyond the copy
/// itself: a compact polish shows how much was trimmed, and a polish that
/// shipped the raw transcript (guard rejection / provider failure) says so
/// instead of silently looking like a normal dictation.
enum CopiedOutcome: Equatable {
    case standard
    /// Compact mode applied; percent of the raw text removed (e.g. 82).
    case compacted(percentReduced: Int)
    /// AI polish was enabled but the pasted text is the raw transcript.
    case aiSkipped
}

/// Estados posibles de la ventana de overlay durante grabacion/transcripcion
enum RecordingOverlayState: Equatable {
    case hidden
    /// Idle mini chip at the anchor position; clicking it opens the quick
    /// history pill, and every dismissed state collapses back into it.
    case docked
    case recording(duration: TimeInterval)
    case paused(duration: TimeInterval)
    case transcribing
    case polishing(timeoutSeconds: UInt64, compact: Bool)
    /// Compact post-dictation toast: the text already landed at the caret
    /// (auto-paste) and on the clipboard, so the overlay only confirms and
    /// collapses; the dock chip reopens it through quick history on demand.
    case copied(outcome: CopiedOutcome)
    case completed(text: String)
    /// In-pill compact history browser opened from the dock chip: recent
    /// transcripts with copy, prev/next and re-transcribe — the fast path
    /// that skips the full History window.
    case quickHistory
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
        case .quickHistory: return "quickHistory"
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
        case .hidden, .docked, .quickHistory:
            return ""
        case .recording:
            return "overlay.recording".localized
        case .paused:
            return "overlay.paused".localized
        case .transcribing:
            return "overlay.transcribing".localized
        case .polishing(_, let compact):
            return (compact ? "overlay.ai_compacting" : "overlay.ai_polishing").localized
        case .copied(let outcome):
            return (outcome == .aiSkipped ? "overlay.copied_raw" : "overlay.copied").localized
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

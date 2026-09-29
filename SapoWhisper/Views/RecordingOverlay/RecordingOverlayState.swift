//
//  RecordingOverlayState.swift
//  SapoWhisper
import Foundation

struct BackupTranscriptionNotice: Equatable {
    let primary: TranscriptionEngineVariant
    let backup: TranscriptionEngineVariant

    var title: String { "overlay.backup_active".localized(backup.displayName) }
    var completedTitle: String { "overlay.backup_completed".localized(backup.displayName) }
    var detail: String { "overlay.backup_primary_failed".localized(primary.displayName) }
}

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
    /// Idle: the transparent window stays on screen with nothing drawn.
    case docked
    case recording(duration: TimeInterval)
    case paused(duration: TimeInterval)
    case transcribing
    case polishing(timeoutSeconds: UInt64, compact: Bool)
    /// Compact post-dictation toast: the text already landed at the caret
    /// (auto-paste) and on the clipboard, so the overlay only confirms and
    /// collapses.
    case copied(outcome: CopiedOutcome)
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

    /// States that render as the same pill: one dictation stays one view
    /// from the first word until its text is ready.
    var contentFamily: String {
        switch self {
        case .recording, .paused, .transcribing, .polishing: return "dictation"
        default: return stateCategory
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

    var showsBackupNotice: Bool {
        switch self {
        case .recording, .paused, .transcribing, .polishing, .copied:
            return true
        default:
            return false
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

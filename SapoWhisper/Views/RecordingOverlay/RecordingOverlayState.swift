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
    case transcribing
    case completed(text: String)
    case error(message: String)

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
        case .transcribing:
            return "overlay.transcribing".localized
        case .completed:
            return "overlay.completed".localized
        case .error(let message):
            return message
        }
    }
}

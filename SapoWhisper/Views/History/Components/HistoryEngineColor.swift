//
//  HistoryEngineColor.swift
//  SapoWhisper
//

import SwiftUI

/// Shared engine-name → accent color map for the history sidebar rows and the
/// detail header chip. Matched on substrings because stored engine strings
/// carry mode/model suffixes.
enum HistoryEngineColor {
    static func color(for engine: String) -> Color {
        switch engine.lowercased() {
        case let e where e.contains("local ai"): return .indigo
        case let e where e.contains("elevenlabs"): return .teal
        case let e where e.contains("deepgram"): return .blue
        case let e where e.contains("gemini"): return .cyan
        case let e where e.contains("google"): return .orange
        case let e where e.contains("whisper"): return .purple
        case let e where e.contains("apple"): return .green
        default: return .secondary
        }
    }
}

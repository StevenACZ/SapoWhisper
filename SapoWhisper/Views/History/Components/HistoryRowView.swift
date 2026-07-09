//
//  HistoryRowView.swift
//  SapoWhisper

import SwiftUI

/// Compact row for the history sidebar list
struct HistoryRowView: View {
    let entry: HistoryEntry

    private var isFailed: Bool { entry.status == "failed" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The transcript is the headline; engine and timing are metadata.
            if entry.isUserCancelled {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                    Text("history.cancelled".localized)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else if isFailed {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                    Text("history.failed".localized)
                }
                .font(.callout)
                .foregroundStyle(.orange)
            } else {
                Text(entry.text)
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }

            HStack(spacing: 6) {
                EngineIndicator(engine: entry.displayEngineName)

                if entry.duration > 0 {
                    Text(entry.formattedDuration)
                        .monospacedDigit()
                }

                if entry.audioFileExists {
                    Image(systemName: "waveform")
                        .foregroundStyle(Color.sapoGreenText)
                }

                if entry.isFavorite {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }

                Spacer(minLength: 4)

                Text(relativeTime)
                    .fixedSize()
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Compact Relative Time

    private var relativeTime: String {
        let interval = Date().timeIntervalSince(entry.timestamp)
        let minutes = Int(interval) / 60
        let hours = minutes / 60
        let days = hours / 24

        if minutes < 1 { return "history.relative_now".localized }
        if minutes < 60 { return "\(minutes)m" }
        if hours < 24 { return "\(hours)h" }
        if days < 7 { return "\(days)d" }
        return entry.timestamp.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Engine Indicator (sidebar)

private struct EngineIndicator: View {
    let engine: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(HistoryEngineColor.color(for: engine))
                .frame(width: 6, height: 6)

            Text(shortName)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// Family name only — the full engine/mode string lives in the detail
    /// panel; repeating it on every row drowned the transcript preview.
    private var shortName: String {
        switch engine.lowercased() {
        case let e where e.contains("local ai"): return "Local AI"
        case let e where e.contains("elevenlabs"): return "ElevenLabs"
        case let e where e.contains("deepgram"): return "Deepgram"
        case let e where e.contains("whisper"): return "Whisper"
        case let e where e.contains("gemini"): return "Gemini"
        case let e where e.contains("google"): return "Google"
        case let e where e.contains("apple"): return "Apple"
        default: return engine
        }
    }
}

// MARK: - Previews

#Preview("Rows") {
    List {
        HistoryRowView(entry: HistoryEntry.mockData[0])
        HistoryRowView(entry: HistoryEntry.mockData[1])
        HistoryRowView(entry: HistoryEntry.mockData[2])
        HistoryRowView(entry: HistoryEntry.mockData[3])
        HistoryRowView(entry: HistoryEntry.mockData[4])
    }
    .listStyle(.sidebar)
    .frame(width: 340, height: 500)
}

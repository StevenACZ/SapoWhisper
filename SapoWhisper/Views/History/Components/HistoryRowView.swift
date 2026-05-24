//
//  HistoryRowView.swift
//  SapoWhisper

import SwiftUI

/// Compact row for the history sidebar list
struct HistoryRowView: View {
    let entry: HistoryEntry

    private var isFailed: Bool { entry.status == "failed" }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Top: engine indicator + relative time
            HStack(spacing: 6) {
                EngineIndicator(engine: entry.displayEngineName)

                Spacer(minLength: 4)

                Text(relativeTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }

            // Text preview or failed state
            if isFailed {
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

            // Bottom: duration + audio icon
            HStack(spacing: 6) {
                if entry.duration > 0 {
                    Label(entry.formattedDuration, systemImage: "clock")
                        .monospacedDigit()
                }

                if entry.audioFileExists {
                    Image(systemName: "waveform")
                        .foregroundStyle(Color.sapoGreen)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }

    // MARK: - Compact Relative Time

    private var relativeTime: String {
        let interval = Date().timeIntervalSince(entry.timestamp)
        let minutes = Int(interval) / 60
        let hours = minutes / 60
        let days = hours / 24

        if minutes < 1 { return "now" }
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
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)

            Text(shortName)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var color: Color {
        switch engine.lowercased() {
        case let e where e.contains("deepgram"): return .blue
        case let e where e.contains("gemini"): return .cyan
        case let e where e.contains("google"): return .orange
        case let e where e.contains("whisper"): return .purple
        case let e where e.contains("apple"): return .green
        default: return .secondary
        }
    }

    private var shortName: String {
        engine
    }
}

// MARK: - Engine Badge (used in detail view)

struct EngineBadge: View {
    let engine: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(badgeColor)
                .frame(width: 8, height: 8)

            Text(engine)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(badgeColor.opacity(0.12))
        .clipShape(Capsule())
    }

    private var badgeColor: Color {
        switch engine.lowercased() {
        case let e where e.contains("deepgram"): return .blue
        case let e where e.contains("gemini"): return .cyan
        case let e where e.contains("google"): return .orange
        case let e where e.contains("whisper"): return .purple
        case let e where e.contains("apple"): return .green
        default: return .secondary
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

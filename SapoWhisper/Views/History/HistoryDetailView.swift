//
//  HistoryDetailView.swift
//  SapoWhisper

import SwiftUI

/// Detail panel showing full transcription text and audio player
struct HistoryDetailView: View {
    let entry: HistoryEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                Divider()

                if entry.status == "failed" {
                    failedSection
                } else {
                    textSection
                }

                if entry.audioFileExists, let path = entry.audioPath {
                    AudioPlayerView(audioPath: path)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(entry.engine)
        .navigationSubtitle(entry.timestamp.formatted(.relative(presentation: .named)))
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            // Engine badge with colored dot
            HStack(spacing: 6) {
                Circle()
                    .fill(engineColor)
                    .frame(width: 10, height: 10)

                Text(entry.engine)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Text(entry.language.uppercased())
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            if entry.isFavorite {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Spacer()

            // Stats chips
            HStack(spacing: 12) {
                if entry.duration > 0 {
                    Label(entry.formattedDuration, systemImage: "clock")
                }
                if entry.wordCount > 0 {
                    Label("\(entry.wordCount) words", systemImage: "text.word.spacing")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Text

    private var textSection: some View {
        Text(entry.text)
            .font(.title3)
            .lineSpacing(10)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Failed

    private var failedSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)

            Text("history.failed".localized)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("history.failed_detail".localized)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var engineColor: Color {
        switch entry.engine.lowercased() {
        case let e where e.contains("deepgram"): return .blue
        case let e where e.contains("google"): return .orange
        case let e where e.contains("whisper"): return .purple
        case let e where e.contains("apple"): return .green
        default: return .secondary
        }
    }
}

// MARK: - Empty State

struct HistoryEmptyDetailView: View {
    var body: some View {
        ContentUnavailableView(
            "history.select_transcription".localized,
            systemImage: "text.quote",
            description: Text("history.select_transcription_sub".localized)
        )
    }
}

// MARK: - Previews

#Preview("Detail - Text") {
    HistoryDetailView(entry: HistoryEntry.mockData[0])
        .frame(width: 500, height: 400)
}

#Preview("Detail - Failed") {
    HistoryDetailView(entry: HistoryEntry.mockData[3])
        .frame(width: 500, height: 400)
}

#Preview("Detail - Empty") {
    HistoryEmptyDetailView()
        .frame(width: 500, height: 400)
}

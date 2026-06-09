//
//  HistoryRetranscribeSheet.swift
//  SapoWhisper
//

import AppKit
import SwiftUI

struct HistoryRetranscribeSheet: View {
    let entry: HistoryEntry
    let currentEngine: TranscriptionEngine
    @Binding var selectedEngine: TranscriptionEngine
    let isProcessing: Bool
    let isEngineReady: (TranscriptionEngine) -> Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var orderedEngines: [TranscriptionEngine] {
        [currentEngine] + TranscriptionEngine.allCases.filter { $0 != currentEngine }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            engineList
            footer
        }
        .padding(20)
        .frame(width: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("history.retranscribe_sheet_title".localized)
                .font(.title3.weight(.semibold))

            Text("history.retranscribe_sheet_subtitle".localized)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Label(entry.displayEngineName, systemImage: "waveform")
                Label(currentEngine.displayName, systemImage: "slider.horizontal.3")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var engineList: some View {
        VStack(spacing: 10) {
            ForEach(orderedEngines, id: \.id) { engine in
                let isReady = isEngineReady(engine)
                Button {
                    guard !isProcessing else { return }
                    selectedEngine = engine
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: engine.icon)
                            .font(.headline)
                            .foregroundStyle(isReady ? .primary : .secondary)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(engine.displayName)
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                if engine == currentEngine {
                                    StatusPill(
                                        title: "history.current_selection".localized,
                                        tint: Color.accentColor
                                    )
                                }

                                if !isReady {
                                    StatusPill(
                                        title: "history.engine_unavailable".localized,
                                        tint: .secondary
                                    )
                                }
                            }

                            Text(engine.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer(minLength: 12)

                        Image(systemName: selectedEngine == engine ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selectedEngine == engine ? Color.accentColor : Color.secondary.opacity(0.35))
                    }
                    .padding(14)
                    .background(cardBackground(for: engine, isReady: isReady))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(borderColor(for: engine, isReady: isReady), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isProcessing || !isReady)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("common.cancel".localized, action: onCancel)
                .keyboardShortcut(.cancelAction)
                .disabled(isProcessing)

            Spacer()

            Button(action: onConfirm) {
                HStack(spacing: 8) {
                    if isProcessing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isProcessing ? "history.retranscribing".localized : "history.retranscribe_create".localized)
                }
                .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isProcessing || !isEngineReady(selectedEngine))
        }
    }

    private func cardBackground(for engine: TranscriptionEngine, isReady: Bool) -> some ShapeStyle {
        if selectedEngine == engine && isReady {
            return AnyShapeStyle(Color.accentColor.opacity(0.12))
        }

        return AnyShapeStyle(Color(NSColor.controlBackgroundColor))
    }

    private func borderColor(for engine: TranscriptionEngine, isReady: Bool) -> Color {
        if selectedEngine == engine && isReady {
            return Color.accentColor.opacity(0.45)
        }

        return Color.primary.opacity(0.08)
    }
}

private struct StatusPill: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }
}

#Preview {
    HistoryRetranscribeSheet(
        entry: HistoryEntry.mockData[0],
        currentEngine: .deepgram,
        selectedEngine: .constant(.deepgram),
        isProcessing: false,
        isEngineReady: { $0 != .whisperLocal },
        onConfirm: {},
        onCancel: {}
    )
}

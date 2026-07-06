//
//  VocabularyMetricsHeader.swift
//  SapoWhisper
//

import SwiftUI

/// Compact three-tile summary at the top of the Vocabulary tab: dictation
/// pace, term capacity for the active engine, and the most used terms.
struct VocabularyMetricsHeader: View {
    let metrics: VocabularyUsageMetrics
    let termCount: Int

    @AppStorage(Constants.StorageKeys.transcriptionEngine) private var engineValue =
        TranscriptionEngine.mlxWhisper.rawValue
    @AppStorage(Constants.StorageKeys.elevenLabsTranscriptionMode) private var elevenLabsModeValue =
        ElevenLabsTranscriptionMode.defaultMode.rawValue

    private var engine: TranscriptionEngine {
        TranscriptionEngine(rawValue: engineValue) ?? .mlxWhisper
    }

    private var elevenLabsMode: ElevenLabsTranscriptionMode {
        ElevenLabsTranscriptionMode(rawValue: elevenLabsModeValue) ?? .defaultMode
    }

    /// Keyterm cap for the active engine configuration; nil when the engine
    /// has no documented vocabulary limit.
    private var termLimit: Int? {
        guard engine == .elevenLabsScribe else { return nil }
        switch elevenLabsMode {
        case .scribeV2Batch:
            return ElevenLabsKeytermLimits.batchMaxCount
        case .scribeV2Realtime:
            return ElevenLabsKeytermLimits.realtimeMaxCount
        }
    }

    private var capacityValue: String {
        if let termLimit {
            return "\(termCount)/\(termLimit)"
        }
        return "\(termCount)"
    }

    private var capacityDetail: String {
        if engine == .elevenLabsScribe {
            return "ElevenLabs · \(elevenLabsMode.displayName)"
        }
        return engine.displayName
    }

    private var isOverLimit: Bool {
        guard let termLimit else { return false }
        return termCount > termLimit
    }

    var body: some View {
        // fixedSize gives the row its ideal (tallest-tile) height, so the
        // maxHeight: .infinity tiles equalize and center their content.
        HStack(alignment: .top, spacing: 8) {
            metricTile(
                label: "vocab.metrics.terms".localized,
                detail: capacityDetail,
                help: "vocab.metrics.terms_help".localized
            ) {
                Text(capacityValue)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isOverLimit ? Color.orange : .primary)
                    .contentTransition(.numericText())
            }

            metricTile(
                label: "vocab.metrics.pace".localized,
                help: "vocab.metrics.pace_help".localized
            ) {
                Text(paceValue)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(metrics.averageWordsPerMinute == nil ? .secondary : .primary)
                    .contentTransition(.numericText())
            }

            metricTile(
                label: "vocab.metrics.top".localized,
                help: "vocab.metrics.top_help".localized
            ) {
                if metrics.topTerms.isEmpty {
                    Text("vocab.metrics.top_empty".localized)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    HStack(spacing: 5) {
                        ForEach(metrics.topTerms) { usage in
                            topTermPill(usage)
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(.smooth(duration: 0.3), value: metrics)
    }

    private var paceValue: String {
        guard let wordsPerMinute = metrics.averageWordsPerMinute else { return "—" }
        return "vocab.metrics.pace_unit".localized(String(wordsPerMinute))
    }

    private func metricTile(
        label: String,
        detail: String? = nil,
        help: String,
        @ViewBuilder value: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)

            value()

            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // .leading (not .topLeading) keeps the content vertically centered,
        // so tiles with two rows don't look top-heavy next to three-row ones.
        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .help(help)
    }

    private func topTermPill(_ usage: VocabularyUsageMetrics.TermUsage) -> some View {
        HStack(spacing: 3) {
            Text(usage.term)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Text("×\(usage.count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.sapoGreen)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.sapoGreen.opacity(0.10), in: Capsule())
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }
}

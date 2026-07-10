//
//  LocalModelRow.swift
//  SapoWhisper
//

import SwiftUI

/// One MLX model tier in the local-model manager: selection radio, size and
/// accuracy info, plus the full download lifecycle (progress ring, pause,
/// resume, cancel, retry-on-error, delete) with state-driven animations.
struct LocalModelRow: View {
    let model: MLXWhisperModel
    let isSelected: Bool
    /// The selected model is being loaded into memory right now.
    let isActiveLoading: Bool
    let isDownloaded: Bool
    let downloadedSize: Int64?
    let phase: MLXModelDownloadPhase

    let onSelect: () -> Void
    let onDownload: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var failureShake = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button(action: onSelect) {
                    HStack(spacing: 12) {
                        selectionRadio
                        modelInfo
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isActiveLoading)

                trailingControls
            }

            if case .failed(let message) = phase {
                failureCaption(message)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.sapoGreen.opacity(0.08) : Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .modifier(ShakeEffect(trigger: failureShake))
        .animation(Constants.Animation.reveal, value: isSelected)
        .animation(Constants.Animation.reveal, value: isDownloaded)
        .animation(Constants.Animation.reveal, value: phase)
        .onChange(of: phase) { _, newPhase in
            if case .failed = newPhase {
                withAnimation(Constants.Animation.shake) { failureShake += 1 }
            }
        }
    }

    // MARK: - Pieces

    private var borderColor: Color {
        if case .failed = phase { return .red.opacity(0.5) }
        return isSelected ? Color.sapoGreen.opacity(0.4) : Color.secondary.opacity(0.15)
    }

    private var selectionRadio: some View {
        ZStack {
            Circle()
                .stroke(isSelected ? Color.sapoGreenText : Color.secondary.opacity(0.3), lineWidth: 2)
                .frame(width: 20, height: 20)

            if isSelected {
                Circle()
                    .fill(Color.sapoGreenText)
                    .frame(width: 12, height: 12)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private var modelInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(model.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                if model.isRecommended {
                    Text(model.badgeText)
                        .font(.caption2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(model.badgeColor)
                        .cornerRadius(3)
                }

                if isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.sapoGreen)
                        .symbolEffect(.bounce, value: isDownloaded)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            HStack(spacing: 8) {
                // Real on-disk size once downloaded; catalog estimate before.
                if isDownloaded, let size = downloadedSize {
                    Text(size.byteCountLabel)
                        .font(.caption)
                        .foregroundColor(.sapoGreenText)
                        .contentTransition(.numericText())
                } else {
                    Text(model.fileSize)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text("•").foregroundColor(.secondary)

                Text(model.speed)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("•").foregroundColor(.secondary)

                HStack(spacing: 1) {
                    ForEach(0..<5) { index in
                        Image(systemName: index < model.accuracy ? "star.fill" : "star")
                            .font(.system(size: 8))
                            .foregroundColor(index < model.accuracy ? .yellow : .secondary.opacity(0.3))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        switch phase {
        case .downloading(let fraction):
            downloadProgress(fraction: fraction, paused: false)
            controlIcon("pause.circle.fill", tint: .secondary, help: "model.pause_tooltip", action: onPause)
            controlIcon("xmark.circle.fill", tint: .secondary, help: "model.cancel_tooltip", action: onCancel)

        case .paused(let fraction):
            downloadProgress(fraction: fraction, paused: true)
            controlIcon("play.circle.fill", tint: .sapoGreen, help: "model.resume_tooltip", action: onResume)
            controlIcon("xmark.circle.fill", tint: .secondary, help: "model.cancel_tooltip", action: onCancel)

        case .failed:
            controlIcon("arrow.clockwise.circle.fill", tint: .sapoGreen, help: "model.retry_tooltip", action: onDownload)

        case .idle:
            if isActiveLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .transition(.opacity)
            } else if isDownloaded {
                controlIcon("trash", tint: .red.opacity(0.7), help: "model.delete_tooltip", action: onDelete)
                    .font(.system(size: 12))
            } else {
                controlIcon(
                    "arrow.down.circle", tint: .secondary.opacity(0.6),
                    help: "model.download_tooltip", action: onDownload
                )
            }
        }
    }

    private func downloadProgress(fraction: Double, paused: Bool) -> some View {
        HStack(spacing: 6) {
            DownloadProgressRing(progress: fraction, dimmed: paused)
                .frame(width: 18, height: 18)
            Text(paused ? "model.paused_label".localized : "\(Int(fraction * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .contentTransition(.numericText())
        }
        .transition(.opacity)
    }

    private func controlIcon(
        _ systemName: String, tint: Color, help helpKey: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15))
                .foregroundColor(tint)
        }
        .buttonStyle(.plain)
        .help(helpKey.localized)
        .accessibilityLabel(helpKey.localized)
        .transition(.scale.combined(with: .opacity))
    }

    private func failureCaption(_ message: String) -> some View {
        Label {
            Text("model.download_failed".localized(message))
                .font(.caption2)
                .foregroundColor(.red)
                .lineLimit(2)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundColor(.red)
        }
        .padding(.leading, 32)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// Small determinate ring for per-row download progress.
struct DownloadProgressRing: View {
    let progress: Double
    var dimmed = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, min(progress, 1)))
                .stroke(
                    dimmed ? Color.secondary : Color.sapoGreen,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(Constants.Animation.reveal, value: progress)
        }
    }
}

#Preview("Local Model Rows") {
    VStack(spacing: 8) {
        LocalModelRow(
            model: .largeV3Turbo, isSelected: true, isActiveLoading: false,
            isDownloaded: true, downloadedSize: 1_650_000_000, phase: .idle,
            onSelect: {}, onDownload: {}, onPause: {}, onResume: {}, onCancel: {}, onDelete: {}
        )
        LocalModelRow(
            model: .small, isSelected: false, isActiveLoading: false,
            isDownloaded: false, downloadedSize: nil, phase: .downloading(0.42),
            onSelect: {}, onDownload: {}, onPause: {}, onResume: {}, onCancel: {}, onDelete: {}
        )
        LocalModelRow(
            model: .base, isSelected: false, isActiveLoading: false,
            isDownloaded: false, downloadedSize: nil, phase: .paused(0.67),
            onSelect: {}, onDownload: {}, onPause: {}, onResume: {}, onCancel: {}, onDelete: {}
        )
        LocalModelRow(
            model: .largeV3, isSelected: false, isActiveLoading: false,
            isDownloaded: false, downloadedSize: nil, phase: .failed("The network connection was lost."),
            onSelect: {}, onDownload: {}, onPause: {}, onResume: {}, onCancel: {}, onDelete: {}
        )
    }
    .padding()
    .frame(width: 460)
}

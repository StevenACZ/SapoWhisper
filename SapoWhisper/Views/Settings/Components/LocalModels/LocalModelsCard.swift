//
//  LocalModelsCard.swift
//  SapoWhisper
//

import SwiftUI
import os

/// Local MLX model manager: tier selection, per-model download lifecycle,
/// real disk usage, and the idle-unload policy.
struct LocalModelsCard: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    let isEmbedded: Bool

    @AppStorage(Constants.StorageKeys.mlxWhisperModel) private var selectedModel =
        MLXWhisperModel.largeV3Turbo.rawValue
    @AppStorage(Constants.StorageKeys.mlxWhisperUnloadAfterMinutes) private var unloadAfterMinutes = 0

    /// R4: 0 keeps the model in RAM; other values unload it after idle.
    private static let unloadOptionsMinutes = [0, 15, 30, 60]

    init(viewModel: SapoWhisperViewModel, isEmbedded: Bool = false) {
        self.viewModel = viewModel
        self.isEmbedded = isEmbedded
    }

    /// nil = nothing selected (after deleting the selected model); no row is
    /// highlighted until the user picks again.
    private var currentModel: MLXWhisperModel? {
        MLXWhisperModel(rawValue: selectedModel)
    }

    private var transcriber: MLXWhisperTranscriber {
        viewModel.mlxWhisperTranscriber
    }

    var body: some View {
        if isEmbedded {
            cardContent
        } else {
            SettingsCard(icon: "square.stack.3d.up", title: "config.mlx_model".localized) {
                cardContent
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            loadedModelStatus

            if transcriber.isLoading {
                loadingProgressView
            }

            modelsList
            Label("config.mlx_tiers_hint".localized, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            storageInfo
            idleUnloadRow

            Text("config.models_download_auto".localized)
                .font(.caption)
                .foregroundColor(.secondary)

            Label("config.mlx_vocabulary_hint".localized, systemImage: "info.circle")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(Constants.Animation.reveal, value: transcriber.isLoading)
        .animation(Constants.Animation.reveal, value: transcriber.downloadedModels)
    }

    @ViewBuilder
    private var loadedModelStatus: some View {
        if transcriber.isModelLoaded {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.sapoGreen)
                    .symbolEffect(.bounce, value: transcriber.isModelLoaded)
                Text(transcriber.loadedModelName ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()
            }
            .transition(.opacity)
        }
    }

    private var loadingProgressView: some View {
        VStack(spacing: 8) {
            ProgressView(value: transcriber.loadingProgress)
                .progressViewStyle(.linear)
                .tint(transcriber.loadingState == .downloading ? .blue : .sapoGreenText)

            HStack(spacing: 6) {
                loadingStateIcon

                Text(transcriber.loadingMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
        .transition(.opacity)
    }

    @ViewBuilder
    private var loadingStateIcon: some View {
        if transcriber.loadingState == .downloading {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(.blue)
                .font(.caption)
        } else if transcriber.loadingState == .loading {
            Image(systemName: "cpu.fill")
                .foregroundColor(.sapoGreen)
                .font(.caption)
        }
    }

    private var modelsList: some View {
        VStack(spacing: 8) {
            ForEach(MLXWhisperModel.allCases) { model in
                LocalModelRow(
                    model: model,
                    isSelected: currentModel == model,
                    isActiveLoading: transcriber.isLoading && currentModel == model,
                    isDownloaded: transcriber.isModelDownloaded(model),
                    downloadedSize: transcriber.downloadedModelSize(model),
                    phase: transcriber.downloadPhase(model),
                    isBusy: transcriber.isTranscribing,
                    onSelect: { selectModel(model) },
                    onDownload: { transcriber.startDownload(model) },
                    onPause: { transcriber.pauseDownload(model) },
                    onResume: { transcriber.startDownload(model) },
                    onCancel: { transcriber.cancelDownload(model) },
                    onDelete: { deleteModel(model) }
                )
            }
        }
    }

    /// Real bytes on disk, summed over complete snapshots.
    @ViewBuilder
    private var storageInfo: some View {
        let downloadedModels = transcriber.getDownloadedModelsInfo()
        if !downloadedModels.isEmpty {
            let totalSize = downloadedModels.reduce(0) { $0 + $1.size }
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundColor(.secondary)
                Text("config.space_used".localized(totalSize.byteCountLabel))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .contentTransition(.numericText())
                Spacer()
            }
            .padding(.top, 4)
            .transition(.opacity)
        }
    }

    /// R4: frees 1.5–3 GB of RAM after dictation pauses; the next dictation
    /// reloads on demand (recording starts immediately, transcription waits).
    private var idleUnloadRow: some View {
        HStack {
            Text("config.unload_after_idle".localized)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Picker("", selection: $unloadAfterMinutes) {
                ForEach(Self.unloadOptionsMinutes, id: \.self) { minutes in
                    Text(unloadOptionLabel(minutes)).tag(minutes)
                }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: unloadAfterMinutes) { _, _ in
                transcriber.noteActivityForIdleUnload()
            }
        }
    }

    private func unloadOptionLabel(_ minutes: Int) -> String {
        minutes == 0
            ? "config.unload_never".localized
            : "config.unload_minutes".localized(String(minutes))
    }

    private func selectModel(_ model: MLXWhisperModel) {
        selectedModel = model.rawValue
        viewModel.setMLXWhisperModel(model)
    }

    private func deleteModel(_ model: MLXWhisperModel) {
        // Through the ViewModel so deleting the selected model also clears
        // the selection (a stale selection would re-download it silently on
        // the next switch back to the local engine).
        viewModel.deleteMLXWhisperModel(model)
        SapoLog.settings.info(
            "MLX model deleted from settings=\(model.rawValue, privacy: .public)"
        )
    }
}

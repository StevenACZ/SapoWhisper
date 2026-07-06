import SwiftUI
import os

/// Model tiers, download state, and idle-unload policy for the MLX engine —
/// same layout as `WhisperKitSettingsCard`, driven by the MLX transcriber.
struct MLXWhisperSettingsCard: View {
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

    private var currentModel: MLXWhisperModel {
        MLXWhisperModel(rawValue: selectedModel) ?? .largeV3Turbo
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
            storageInfo
            idleUnloadRow

            Text("config.models_download_auto".localized)
                .font(.caption)
                .foregroundColor(.secondary)

            Label("config.whisper_vocabulary_hint".localized, systemImage: "info.circle")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var loadedModelStatus: some View {
        if transcriber.isModelLoaded {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.sapoGreen)
                Text(transcriber.loadedModelName ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()
            }
        }
    }

    private var loadingProgressView: some View {
        VStack(spacing: 8) {
            ProgressView(value: transcriber.loadingProgress)
                .progressViewStyle(.linear)
                .tint(transcriber.loadingState == .downloading ? .blue : .sapoGreen)

            HStack(spacing: 6) {
                loadingStateIcon

                Text(transcriber.loadingMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
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
                let isDownloaded = transcriber.isModelDownloaded(model)
                let downloadedSize = transcriber.downloadedModelSize(model)

                WhisperModelButton(
                    model: model,
                    isSelected: currentModel == model,
                    isLoading: transcriber.isLoading && currentModel == model,
                    isDownloaded: isDownloaded,
                    downloadedSize: downloadedSize,
                    action: {
                        selectedModel = model.rawValue
                        viewModel.setMLXWhisperModel(model)
                    },
                    onDelete: isDownloaded
                        ? {
                            deleteModel(model)
                        } : nil
                )
            }
        }
    }

    @ViewBuilder
    private var storageInfo: some View {
        let downloadedModels = transcriber.getDownloadedModelsInfo()
        if !downloadedModels.isEmpty {
            let totalSize = downloadedModels.reduce(0) { $0 + $1.size }
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundColor(.secondary)
                Text("config.space_used".localized(WhisperKitTranscriber.formatBytes(totalSize)))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.top, 4)
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

    private func deleteModel(_ model: MLXWhisperModel) {
        transcriber.deleteDownloadedModel(model)
        SapoLog.settings.info(
            "MLX model deleted from settings=\(model.rawValue, privacy: .public)"
        )
    }
}

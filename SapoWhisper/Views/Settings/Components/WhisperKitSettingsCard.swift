import SwiftUI
import os

struct WhisperKitSettingsCard: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    let isEmbedded: Bool

    @AppStorage(Constants.StorageKeys.whisperKitModel) private var selectedWhisperModel = WhisperKitModel.small.rawValue
    @AppStorage(Constants.StorageKeys.whisperKitUnloadAfterMinutes) private var unloadAfterMinutes = 0

    /// R4: 0 keeps the model in RAM; other values unload it after idle.
    private static let unloadOptionsMinutes = [0, 15, 30, 60]

    init(viewModel: SapoWhisperViewModel, isEmbedded: Bool = false) {
        self.viewModel = viewModel
        self.isEmbedded = isEmbedded
    }

    private var currentWhisperKitModel: WhisperKitModel {
        WhisperKitModel(rawValue: selectedWhisperModel) ?? .small
    }

    var body: some View {
        if isEmbedded {
            cardContent
        } else {
            SettingsCard(icon: "square.stack.3d.up", title: "config.whisper_model".localized) {
                cardContent
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            loadedModelStatus

            if viewModel.isLoadingWhisperKit {
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
        if viewModel.whisperKitTranscriber.isModelLoaded {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.sapoGreen)
                Text(viewModel.whisperKitTranscriber.loadedModelName ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()
            }
        }
    }

    private var loadingProgressView: some View {
        VStack(spacing: 8) {
            ProgressView(value: viewModel.whisperKitLoadingProgress)
                .progressViewStyle(.linear)
                .tint(viewModel.whisperKitTranscriber.loadingState == .downloading ? .blue : .sapoGreen)

            HStack(spacing: 6) {
                loadingStateIcon

                Text(viewModel.whisperKitLoadingMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var loadingStateIcon: some View {
        if viewModel.whisperKitTranscriber.loadingState == .downloading {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(.blue)
                .font(.caption)
        } else if viewModel.whisperKitTranscriber.loadingState == .prewarming {
            Image(systemName: "cpu.fill")
                .foregroundColor(.sapoGreen)
                .font(.caption)
        }
    }

    private var modelsList: some View {
        VStack(spacing: 8) {
            ForEach(WhisperKitModel.allCases) { model in
                let isDownloaded = viewModel.whisperKitTranscriber.isModelDownloaded(model)
                let downloadedSize = viewModel.whisperKitTranscriber.downloadedModelSize(model)

                WhisperModelButton(
                    model: model,
                    isSelected: currentWhisperKitModel == model,
                    isLoading: viewModel.isLoadingWhisperKit && currentWhisperKitModel == model,
                    isDownloaded: isDownloaded,
                    downloadedSize: downloadedSize,
                    action: {
                        selectedWhisperModel = model.rawValue
                        viewModel.setWhisperKitModel(model)
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
        let downloadedModels = viewModel.whisperKitTranscriber.getDownloadedModelsInfo()
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

    /// R4: frees 0.5–3 GB of RAM after dictation pauses; the next dictation
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
                viewModel.whisperKitTranscriber.noteActivityForIdleUnload()
            }
        }
    }

    private func unloadOptionLabel(_ minutes: Int) -> String {
        minutes == 0
            ? "config.unload_never".localized
            : "config.unload_minutes".localized(String(minutes))
    }

    private func deleteModel(_ model: WhisperKitModel) {
        if currentWhisperKitModel == model && viewModel.whisperKitTranscriber.isModelLoaded {
            viewModel.whisperKitTranscriber.unloadModel()
        }

        let success = viewModel.whisperKitTranscriber.deleteDownloadedModel(model)
        if success {
            SapoLog.settings.info(
                "WhisperKit model deleted=\(model.rawValue, privacy: .public)"
            )
        } else {
            SapoLog.settings.error(
                "WhisperKit model delete failed=\(model.rawValue, privacy: .public)"
            )
        }
    }
}

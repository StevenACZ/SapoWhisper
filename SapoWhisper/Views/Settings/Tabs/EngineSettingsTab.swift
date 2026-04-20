//
//  EngineSettingsTab.swift
//  SapoWhisper
//
//

import SwiftUI
import UniformTypeIdentifiers

/// Tab de configuración del motor de transcripción y modelos WhisperKit
struct EngineSettingsTab: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    
    @AppStorage(Constants.StorageKeys.transcriptionEngine) private var selectedEngine = TranscriptionEngine.appleOnline.rawValue
    @AppStorage(Constants.StorageKeys.whisperKitModel) private var selectedWhisperModel = WhisperKitModel.small.rawValue
    
    private var currentEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: selectedEngine) ?? .appleOnline
    }
    
    private var currentWhisperKitModel: WhisperKitModel {
        WhisperKitModel(rawValue: selectedWhisperModel) ?? .small
    }
    
    @AppStorage(Constants.StorageKeys.googleCloudAPIKey) private var googleCloudAPIKey = ""
    @State private var showAPIKeySection = false
    @State private var serviceAccountError: String?

    @AppStorage(Constants.StorageKeys.deepgramAPIKey) private var deepgramAPIKey = ""

    // Vocabulary state
    @ObservedObject private var vocabularyManager = VocabularyManager.shared
    @State private var newKeyterm = ""
    @State private var newReplaceFrom = ""
    @State private var newReplaceTo = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                transcriptionEngineCard

                if currentEngine == .whisperLocal {
                    whisperKitModelCard
                }

                if currentEngine == .googleCloud {
                    googleCloudSettingsCard
                }

                if currentEngine == .deepgram {
                    deepgramSettingsCard
                    vocabularyCard
                }
            }
            .padding()
        }
    }
    
    // MARK: - Transcription Engine Card
    
    private var transcriptionEngineCard: some View {
        SettingsCard(icon: "cpu", title: "config.engine".localized) {
            VStack(spacing: 8) {
                ForEach(TranscriptionEngine.allCases) { engine in
                    EngineButton(
                        engine: engine,
                        isSelected: currentEngine == engine,
                        isLoading: engine == .whisperLocal && viewModel.isLoadingWhisperKit,
                        loadingProgress: viewModel.whisperKitLoadingProgress,
                        loadingMessage: viewModel.whisperKitLoadingMessage
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedEngine = engine.rawValue
                            viewModel.setEngine(engine)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - WhisperKit Model Card
    
    private var whisperKitModelCard: some View {
        SettingsCard(icon: "square.stack.3d.up", title: "config.whisper_model".localized) {
            VStack(alignment: .leading, spacing: 12) {
                // Estado del modelo cargado
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
                
                // Progress de carga/descarga
                if viewModel.isLoadingWhisperKit {
                    loadingProgressView
                }
                
                // Lista de modelos
                modelsList
                
                // Espacio usado
                storageInfo
                
                Text("config.models_download_auto".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var loadingProgressView: some View {
        VStack(spacing: 8) {
            ProgressView(value: viewModel.whisperKitLoadingProgress)
                .progressViewStyle(.linear)
                .tint(viewModel.whisperKitTranscriber.loadingState == .downloading ? .blue : .sapoGreen)
            
            HStack(spacing: 6) {
                if viewModel.whisperKitTranscriber.loadingState == .downloading {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.blue)
                        .font(.caption)
                } else if viewModel.whisperKitTranscriber.loadingState == .prewarming {
                    Image(systemName: "cpu.fill")
                        .foregroundColor(.sapoGreen)
                        .font(.caption)
                }
                
                Text(viewModel.whisperKitLoadingMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
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
                    onDelete: isDownloaded ? {
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
    
    // MARK: - Google Cloud Settings Card

    private var googleCloudSettingsCard: some View {
        SettingsCard(icon: "cloud", title: "Google Cloud") {
            VStack(alignment: .leading, spacing: 12) {
                // 60s warning
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("config.google_60s_warning".localized)
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                serviceAccountSection
                Divider()
                apiKeyFallbackSection
            }
        }
    }

    @ViewBuilder
    private var serviceAccountSection: some View {
        if ServiceAccountManager.shared.isConfigured {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.sapoGreen)
                Text("config.service_account_configured".localized("Chirp 3"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                Button("config.service_account_change".localized) { importServiceAccount() }
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                    .font(.caption)

                Button("config.service_account_remove".localized) {
                    ServiceAccountManager.shared.remove()
                    viewModel.setEngine(.googleCloud)
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .font(.caption)
            }
        } else {
            Text("config.service_account_desc".localized)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Button(action: { importServiceAccount() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.badge.plus")
                        Text("config.service_account_import".localized)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Button(action: {
                    ServiceAccountManager.shared.reload()
                    viewModel.setEngine(.googleCloud)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("Detectar")
                    }
                }
                .buttonStyle(.bordered)
            }
        }

        if let error = serviceAccountError {
            Text(error)
                .font(.caption)
                .foregroundColor(.red)
        }
    }

    @ViewBuilder
    private var apiKeyFallbackSection: some View {
        DisclosureGroup(
            isExpanded: $showAPIKeySection,
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: googleCloudAPIKey.isEmpty ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundColor(googleCloudAPIKey.isEmpty ? .orange : .sapoGreen)
                        Text(googleCloudAPIKey.isEmpty ? "config.api_key_missing".localized : "config.api_key_configured".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    SecureField("config.api_key_placeholder".localized, text: $googleCloudAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    Text("config.api_key_desc".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            },
            label: {
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .foregroundColor(.secondary)
                    Text("config.api_key_fallback".localized)
                        .font(.subheadline)
                }
            }
        )
    }

    private func importServiceAccount() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "config.service_account_desc".localized

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try ServiceAccountManager.shared.importFile(from: url)
            serviceAccountError = nil
            viewModel.setEngine(.googleCloud)
        } catch {
            serviceAccountError = error.localizedDescription
        }
    }

    // MARK: - Deepgram Settings Card

    private var deepgramSettingsCard: some View {
        SettingsCard(icon: "waveform.badge.mic", title: "Deepgram") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: deepgramAPIKey.isEmpty ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundColor(deepgramAPIKey.isEmpty ? .orange : .sapoGreen)
                    Text(deepgramAPIKey.isEmpty ? "config.deepgram_key_missing".localized : "config.deepgram_key_configured".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                SecureField("config.deepgram_key_placeholder".localized, text: $deepgramAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                Text("config.deepgram_key_desc".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onChange(of: deepgramAPIKey) { _, _ in
            if currentEngine == .deepgram {
                viewModel.setEngine(.deepgram)
            }
        }
    }

    // MARK: - Vocabulary Card

    private var vocabularyCard: some View {
        SettingsCard(icon: "text.book.closed", title: "config.vocabulary".localized) {
            VStack(alignment: .leading, spacing: 16) {
                // Keyterms section
                VStack(alignment: .leading, spacing: 8) {
                    Text("config.keyterms".localized)
                        .font(.subheadline.weight(.medium))

                    ForEach(Array(vocabularyManager.keyterms.enumerated()), id: \.offset) { index, term in
                        HStack {
                            Text(term)
                                .font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Button(action: { vocabularyManager.removeKeyterm(at: index) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }

                    HStack(spacing: 8) {
                        TextField("config.keyterm_placeholder".localized, text: $newKeyterm)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .onSubmit { addKeyterm() }

                        Button("config.add".localized) { addKeyterm() }
                            .buttonStyle(.bordered)
                            .font(.caption)
                            .disabled(newKeyterm.isEmpty)
                    }

                    Text("config.keyterms_desc".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Replacements section
                VStack(alignment: .leading, spacing: 8) {
                    Text("config.replacements".localized)
                        .font(.subheadline.weight(.medium))

                    ForEach(Array(vocabularyManager.replacements.sorted(by: { $0.key < $1.key })), id: \.key) { key, value in
                        HStack {
                            Text("\(key)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(value)
                                .font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Button(action: { vocabularyManager.removeReplacement(forKey: key) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }

                    HStack(spacing: 8) {
                        TextField("config.replace_from".localized, text: $newReplaceFrom)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .frame(maxWidth: 120)

                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextField("config.replace_to".localized, text: $newReplaceTo)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))

                        Button("config.add".localized) { addReplacement() }
                            .buttonStyle(.bordered)
                            .font(.caption)
                            .disabled(newReplaceFrom.isEmpty || newReplaceTo.isEmpty)
                    }

                    Text("config.replacements_desc".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func addKeyterm() {
        vocabularyManager.addKeyterm(newKeyterm)
        newKeyterm = ""
    }

    private func addReplacement() {
        vocabularyManager.addReplacement(from: newReplaceFrom, to: newReplaceTo)
        newReplaceFrom = ""
        newReplaceTo = ""
    }

    // MARK: - Model Management

    private func deleteModel(_ model: WhisperKitModel) {
        if currentWhisperKitModel == model && viewModel.whisperKitTranscriber.isModelLoaded {
            viewModel.setEngine(.appleOnline)
        }
        
        let success = viewModel.whisperKitTranscriber.deleteDownloadedModel(model)
        if success {
            print("✅ Modelo \(model.displayName) borrado exitosamente")
        } else {
            print("❌ Error al borrar modelo \(model.displayName)")
        }
    }
}

#Preview("Engine Settings") {
    EngineSettingsTab(viewModel: SapoWhisperViewModel())
        .frame(width: 480, height: 600)
}

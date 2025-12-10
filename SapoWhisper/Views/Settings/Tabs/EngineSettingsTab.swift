//
//  EngineSettingsTab.swift
//  SapoWhisper
//
//  Created by Steven on 9/12/24.
//

import SwiftUI

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
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                transcriptionEngineCard
                
                if currentEngine == .whisperLocal {
                    whisperKitModelCard
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

#Preview {
    EngineSettingsTab(viewModel: SapoWhisperViewModel())
        .frame(width: 480, height: 500)
}

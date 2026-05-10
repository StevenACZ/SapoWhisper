import SwiftUI

/// Transcription engine settings coordinator.
struct EngineSettingsTab: View {
    @ObservedObject var viewModel: SapoWhisperViewModel

    @AppStorage(Constants.StorageKeys.transcriptionEngine) private var selectedEngine = TranscriptionEngine.appleOnline.rawValue

    private var currentEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: selectedEngine) ?? .appleOnline
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                transcriptionEngineCard

                if currentEngine == .whisperLocal {
                    WhisperKitSettingsCard(viewModel: viewModel)
                }

                if currentEngine == .googleCloud {
                    GoogleCloudSettingsCard(viewModel: viewModel)
                }

                if currentEngine == .deepgram {
                    DeepgramSettingsCard(viewModel: viewModel)
                }

                AIPolishSettingsCard()

                if currentEngine == .deepgram {
                    VocabularySettingsCard()
                }
            }
            .padding()
        }
    }

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
}

#Preview("Engine Settings") {
    EngineSettingsTab(viewModel: SapoWhisperViewModel())
        .frame(width: 480, height: 600)
}

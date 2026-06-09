import SwiftUI

/// Transcription engine settings coordinator.
struct EngineSettingsTab: View {
    @ObservedObject var viewModel: SapoWhisperViewModel

    @AppStorage(Constants.StorageKeys.transcriptionEngine) private var selectedEngine = TranscriptionEngine.whisperLocal.rawValue
    @State private var isSelectedEngineSettingsExpanded = false

    private var currentEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: selectedEngine) ?? .whisperLocal
    }

    var body: some View {
        ScrollView {
            transcriptionEngineCard
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(16)
        }
    }

    private var transcriptionEngineCard: some View {
        SettingsCard(icon: "cpu", title: "config.engine".localized) {
            VStack(spacing: 8) {
                ForEach(TranscriptionEngine.allCases) { engine in
                    EngineOptionRow(
                        engine: engine,
                        isSelected: currentEngine == engine,
                        isLoading: engine == .whisperLocal && viewModel.isLoadingWhisperKit,
                        loadingProgress: viewModel.whisperKitLoadingProgress,
                        loadingMessage: viewModel.whisperKitLoadingMessage,
                        hasDetails: engine.hasInlineSettings,
                        isExpanded: $isSelectedEngineSettingsExpanded
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if currentEngine == engine, engine.hasInlineSettings {
                                isSelectedEngineSettingsExpanded.toggle()
                            } else {
                                selectedEngine = engine.rawValue
                                isSelectedEngineSettingsExpanded = false
                                viewModel.setEngine(engine)
                            }
                        }
                    } details: {
                        selectedEngineSettings(for: engine)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func selectedEngineSettings(for engine: TranscriptionEngine) -> some View {
        switch engine {
        case .whisperLocal:
            WhisperKitSettingsCard(viewModel: viewModel, isEmbedded: true)
        case .deepgram:
            DeepgramSettingsCard(viewModel: viewModel, isEmbedded: true)
        case .elevenLabsScribe:
            ElevenLabsSettingsCard(viewModel: viewModel, isEmbedded: true)
        }
    }
}

extension TranscriptionEngine {
    fileprivate var hasInlineSettings: Bool {
        true
    }
}

#Preview("Engine Settings") {
    EngineSettingsTab(viewModel: SapoWhisperViewModel())
        .frame(width: 860, height: 620)
}

#Preview("Permissions States") {
    HStack(alignment: .top, spacing: 20) {
        PermissionStatePreviewColumn(
            title: "Needs Permissions",
            grantedPermissions: []
        )

        PermissionStatePreviewColumn(
            title: "All Granted",
            grantedPermissions: Set(AppPermission.allCases)
        )
    }
    .padding(20)
    .frame(width: 1120, height: 720)
    .background(Color(nsColor: .windowBackgroundColor))
    .preferredColorScheme(.dark)
}

private struct PermissionStatePreviewColumn: View {
    let title: String
    let grantedPermissions: Set<AppPermission>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            PermissionRequirementsView(
                previewGrantedPermissions: grantedPermissions,
                onActivate: { _ in },
                onClose: {}
            )
            .frame(
                width: PermissionRequirementsView.windowSize.width,
                height: PermissionRequirementsView.windowSize.height
            )
        }
    }
}

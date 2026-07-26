import SwiftUI

/// Transcription engine settings coordinator.
struct EngineSettingsTab: View {
    @ObservedObject var viewModel: SapoWhisperViewModel

    @AppStorage(Constants.StorageKeys.transcriptionEngine) private var selectedEngine = TranscriptionEngine.mlxWhisper.rawValue
    @AppStorage(Constants.StorageKeys.fallbackTranscriptionEngine) private var fallbackEngineRawValue = ""
    @AppStorage(Constants.StorageKeys.language) private var selectedLanguage = "auto"
    @AppStorage(Constants.StorageKeys.mlxWhisperModel) private var selectedMLXModel = MLXWhisperModel.largeV3Turbo.rawValue
    @AppStorage(Constants.StorageKeys.deepgramTranscriptionMode) private var selectedDeepgramMode =
        DeepgramTranscriptionMode.nova3.rawValue
    @AppStorage(Constants.StorageKeys.elevenLabsTranscriptionMode) private var selectedElevenLabsMode =
        ElevenLabsTranscriptionMode.defaultMode.rawValue
    @AppStorage(Constants.StorageKeys.localAIServerModel) private var selectedLocalAIServerModel =
        LocalAIServerConfiguration.defaultModel
    @AppStorage(Constants.StorageKeys.aiPolishEnabled) private var aiPolishEnabled = false
    @AppStorage(Constants.StorageKeys.aiPolishOutputLanguage) private var aiPolishOutputLanguage =
        TranscriptPolishOutputLanguage.sameAsInput.rawValue
    @State private var isSelectedEngineSettingsExpanded = false

    private var currentEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: selectedEngine) ?? .mlxWhisper
    }

    private var currentVariant: TranscriptionEngineVariant {
        .primary(
            engine: currentEngine,
            deepgramMode: DeepgramTranscriptionMode(rawValue: selectedDeepgramMode) ?? .nova3,
            elevenLabsMode: ElevenLabsTranscriptionMode(rawValue: selectedElevenLabsMode) ?? .defaultMode
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    transcriptionEngineCard
                    fallbackEngineCard
                    currentSetupCard
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(16)
                .frame(minHeight: proxy.size.height)
            }
        }
    }

    private var transcriptionEngineCard: some View {
        SettingsCard(icon: "cpu", title: "config.engine".localized) {
            VStack(spacing: 8) {
                ForEach(TranscriptionEngine.allCases) { engine in
                    EngineOptionRow(
                        engine: engine,
                        isSelected: currentEngine == engine,
                        isLoading: engine == .mlxWhisper && viewModel.mlxWhisperTranscriber.isLoading,
                        loadingProgress: viewModel.mlxWhisperTranscriber.loadingProgress,
                        loadingMessage: viewModel.mlxWhisperTranscriber.loadingMessage,
                        hasDetails: engine.hasInlineSettings,
                        isExpanded: $isSelectedEngineSettingsExpanded
                    ) {
                        withAnimation(Constants.Animation.reveal) {
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

    // MARK: - Backup engine

    /// Variants on a DIFFERENT engine than the primary. A sibling mode shares
    /// its provider's key, host and reachability, so it is down exactly when
    /// the primary is; offering it would promise a rescue that can never run.
    /// The stored value falls back to "none" at runtime if the user later
    /// selects its engine as the primary.
    private var fallbackCandidates: [TranscriptionEngineVariant] {
        TranscriptionEngineVariant.allCases.filter { $0.engine != currentVariant.engine }
    }

    private var selectedFallbackEngine: TranscriptionEngineVariant? {
        guard let variant = TranscriptionEngineVariant.stored(fallbackEngineRawValue),
            variant.engine != currentVariant.engine
        else { return nil }
        return variant
    }

    /// Reads through the same normalization the engine does, so a selection
    /// stored before the picker listed live modes still shows its row.
    private var fallbackSelection: Binding<String> {
        Binding(
            get: { TranscriptionEngineVariant.stored(fallbackEngineRawValue)?.rawValue ?? "" },
            set: { fallbackEngineRawValue = $0 }
        )
    }

    private var fallbackEngineCard: some View {
        SettingsCard(icon: "arrow.triangle.2.circlepath", title: "config.fallback_engine".localized) {
            VStack(alignment: .leading, spacing: 8) {
                Text("config.fallback_engine_description".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("", selection: fallbackSelection) {
                    Text("config.fallback_engine_none".localized).tag("")
                    ForEach(fallbackCandidates) { variant in
                        Label(variant.displayName, systemImage: variant.icon).tag(variant.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)

                if let backup = selectedFallbackEngine {
                    if !viewModel.isBackupEngineUsable(backup) {
                        Label(
                            "config.fallback_engine_not_configured".localized(backup.displayName),
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundColor(.orange)
                    } else if backup.isStreaming {
                        Text("config.fallback_engine_live_note".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func selectedEngineSettings(for engine: TranscriptionEngine) -> some View {
        switch engine {
        case .mlxWhisper:
            LocalModelsCard(viewModel: viewModel, isEmbedded: true)
        case .localAIServer:
            LocalAIServerSettingsCard(viewModel: viewModel, isEmbedded: true)
        case .deepgram:
            DeepgramSettingsCard(viewModel: viewModel, isEmbedded: true)
        case .elevenLabsScribe:
            ElevenLabsSettingsCard(viewModel: viewModel, isEmbedded: true)
        }
    }

    // MARK: - Current setup summary

    /// At-a-glance summary of the active dictation setup: engine, processing
    /// mode (or local model), and recognition language.
    private var currentSetupCard: some View {
        SettingsCard(icon: "checkmark.seal", title: "config.engine_summary".localized) {
            HStack(spacing: 16) {
                summaryItem(
                    icon: currentEngine.icon,
                    label: "config.engine_summary_engine".localized,
                    value: currentEngine.displayName
                )
                summaryDivider
                summaryItem(icon: modeSummary.icon, label: modeSummary.label, value: modeSummary.value)
                summaryDivider
                summaryItem(
                    icon: "globe",
                    label: "config.engine_summary_language".localized,
                    value: languageSummaryValue
                )
                if aiPolishEnabled {
                    summaryDivider
                    summaryItem(
                        icon: "sparkles",
                        label: "config.engine_summary_ai".localized,
                        value: aiSummaryValue
                    )
                }
            }
        }
    }

    /// What the AI polish step does to the language of the final text:
    /// translates to an explicit target, or keeps the spoken language.
    private var aiSummaryValue: String {
        let outputLanguage = TranscriptPolishOutputLanguage(rawValue: aiPolishOutputLanguage) ?? .sameAsInput
        guard outputLanguage.requiresTranslation else {
            return "config.engine_summary_ai_active".localized
        }
        return "config.engine_summary_ai_translate".localized(outputLanguage.shortDisplayName)
    }

    private var summaryDivider: some View {
        Divider().frame(height: 30)
    }

    private func summaryItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.sapoGreen.opacity(0.12))
                    .frame(width: 32, height: 32)

                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(.sapoGreen)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(value)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modeSummary: (icon: String, label: String, value: String) {
        switch currentEngine {
        case .mlxWhisper:
            // No fallback tier: after deleting the selected model there is
            // genuinely no selection until the user picks again.
            let model = MLXWhisperModel(rawValue: selectedMLXModel)
            return ("memorychip", "config.engine_summary_model".localized, model?.displayName ?? "—")
        case .localAIServer:
            let model = selectedLocalAIServerModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                "server.rack",
                "config.engine_summary_model".localized,
                model.isEmpty ? LocalAIServerConfiguration.defaultModel : model
            )
        case .deepgram:
            let mode = DeepgramTranscriptionMode(rawValue: selectedDeepgramMode) ?? .nova3
            return (mode.icon, "config.engine_summary_mode".localized, mode.displayName)
        case .elevenLabsScribe:
            let mode = ElevenLabsTranscriptionMode(rawValue: selectedElevenLabsMode) ?? .defaultMode
            return (mode.icon, "config.engine_summary_mode".localized, mode.displayName)
        }
    }

    private var languageSummaryValue: String {
        TranscriptionLanguageCatalog.language(for: selectedLanguage)?.displayName
            ?? TranscriptionLanguageCatalog.languages[0].displayName
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

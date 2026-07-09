//
//  WelcomeView.swift
//  SapoWhisper
//
//  Multi-step welcome flow: greet → permissions → choose engine →
//  optional AI polish → ready. Every step is skippable except that
//  "Continue" on the engine step requires one usable engine.
//

import Combine
import SwiftUI

enum WelcomeStep: Int, CaseIterable {
    case welcome
    case permissions
    case engine
    case aiPolish
    case ready
}

struct WelcomeView: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    let onFinish: () -> Void
    let onDismiss: () -> Void

    @State private var step: WelcomeStep =
        UIPreviewMode.welcomeStep
        .flatMap(WelcomeStep.init(rawValue:)) ?? .welcome
    @Namespace private var engineSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let windowSize = CGSize(width: 660, height: 600)

    var body: some View {
        VStack(spacing: 0) {
            header

            ZStack {
                stepContent
                    .id(step)
                    // Reduce Motion swaps steps with a plain crossfade.
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth(duration: 0.35), value: step)

            navigationBar
        }
        // Fixed width, flexible height: the titled + fullSizeContentView
        // window ends up taller than the content rect it was created with,
        // and a fixed-height view would float centered with dead bands.
        .frame(width: Self.windowSize.width)
        .frame(maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        // The transparent titlebar (fullSizeContentView) otherwise pushes the
        // whole flow down by the titlebar height, leaving a dead band on top.
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: - Header (step indicator)

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(WelcomeStep.allCases, id: \.rawValue) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? Color.sapoGreen : Color.secondary.opacity(0.2))
                    .frame(width: item == step ? 26 : 14, height: 5)
                    .animation(Constants.Animation.transition, value: step)
            }

            Spacer()

            Button("welcome.close".localized) {
                onDismiss()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            WelcomeIntroStep(
                hotkeyDescription: viewModel.hotkeyManager.hotkeyDescription,
                trigger: .current(from: viewModel.hotkeyManager)
            )
        case .permissions:
            WelcomePermissionsStep()
        case .engine:
            WelcomeEngineStep(viewModel: viewModel, selectionNamespace: engineSelection)
        case .aiPolish:
            WelcomeAIPolishStep()
        case .ready:
            WelcomeReadyStep(viewModel: viewModel, onFinish: onFinish)
        }
    }

    // MARK: - Navigation

    private var canContinue: Bool {
        switch step {
        case .engine:
            return viewModel.isEngineReady(viewModel.currentEngine)
        default:
            return true
        }
    }

    private var continueTitle: String {
        switch step {
        case .welcome:
            return "welcome.start".localized
        case .aiPolish:
            return aiPolishConfigured ? "welcome.continue".localized : "welcome.skip_step".localized
        case .ready:
            return "welcome.finish".localized
        default:
            return "welcome.continue".localized
        }
    }

    private var aiPolishConfigured: Bool {
        // Hint-based: this renders on every welcome step, so it must never be
        // the reason the keychain consent dialog appears.
        UserDefaults.standard.bool(forKey: Constants.StorageKeys.aiPolishEnabled)
            && PolishProviderConfiguration.hasUsableConfiguration()
    }

    private var navigationBar: some View {
        HStack {
            if step != .welcome && step != .ready {
                Button("welcome.back".localized) {
                    withAnimation(.smooth(duration: 0.35)) {
                        step = WelcomeStep(rawValue: step.rawValue - 1) ?? .welcome
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if step == .engine && !canContinue {
                Text("welcome.engine_required".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
            }

            Button(continueTitle) {
                advance()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.sapoGreen)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.bar)
    }

    private func advance() {
        if step == .ready {
            onFinish()
            return
        }
        withAnimation(.smooth(duration: 0.35)) {
            step = WelcomeStep(rawValue: step.rawValue + 1) ?? .ready
        }
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeIntroStep: View {
    let hotkeyDescription: String
    let trigger: HotkeyKeycapsDemo.Trigger
    @State private var bouncing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(nsImage: NSImage(named: "DockIconIdle") ?? NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: Color.sapoGreen.opacity(0.3), radius: 18, y: 6)
                .scaleEffect(bouncing && !reduceMotion ? 1.04 : 1.0)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                    value: bouncing
                )
                .onAppear { bouncing = true }

            VStack(spacing: 8) {
                Text("welcome.title".localized)
                    .font(.system(size: 26, weight: .bold))
                Text("welcome.subtitle".localized)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            HotkeyKeycapsDemo(trigger: trigger)
                .padding(.top, 6)

            Text("welcome.hotkey_caption".localized(hotkeyDescription))
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

/// The configured trigger rendered as physical keycaps that press themselves
/// in a loop — a tap-tap rhythm for double-modifier triggers.
private struct HotkeyKeycapsDemo: View {
    enum Trigger {
        case combo([String])
        case doubleTap(String)

        static func current(from manager: HotkeyManager) -> Trigger {
            if manager.currentTriggerKind == .doubleModifier {
                let modifier = HotkeyDoubleTapModifier.option(for: manager.currentDoubleTapModifier)
                return .doubleTap(modifier.symbol)
            }
            return .combo(manager.hotkeyDescription.components(separatedBy: " + "))
        }
    }

    let trigger: Trigger

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch trigger {
        case .combo(let tokens):
            HStack(spacing: 12) {
                ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                    if index > 0 {
                        Text("+")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    KeycapView(label: token, width: keycapWidth(for: token))
                }
            }
            // Reduce Motion pins the loop to its resting phase.
            .phaseAnimator(reduceMotion ? [false] : [false, true]) { content, pressed in
                content
                    .scaleEffect(pressed ? 0.94 : 1.0)
            } animation: { pressed in
                pressed ? .spring(duration: 0.18) : .easeOut(duration: 1.1)
            }
        case .doubleTap(let symbol):
            // Phases 1 and 3 are the two quick presses; the slow return to 0
            // is the pause before the rhythm repeats. Reduce Motion pins the
            // loop to its resting phase.
            KeycapView(label: symbol, width: 64)
                .phaseAnimator(reduceMotion ? [0] : [0, 1, 2, 3]) { content, phase in
                    content
                        .scaleEffect(phase == 1 || phase == 3 ? 0.90 : 1.0)
                } animation: { phase in
                    phase == 0 ? .easeOut(duration: 1.2) : .spring(duration: 0.14)
                }
        }
    }

    private func keycapWidth(for token: String) -> CGFloat {
        token.count <= 1 ? 56 : min(140, 44 + CGFloat(token.count) * 13)
    }
}

// MARK: - Step 2: Permissions

private struct WelcomePermissionsStep: View {
    @State private var granted: Set<AppPermission> = []
    private let refreshTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WelcomeStepTitle(
                title: "welcome.permissions_title".localized,
                subtitle: "welcome.permissions_subtitle".localized
            )

            VStack(spacing: 12) {
                ForEach(AppPermission.required) { permission in
                    WelcomePermissionRow(permission: permission, isGranted: granted.contains(permission))
                }
            }

            Label("welcome.permissions_footnote".localized, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.top, 18)
        .onAppear { refreshGranted() }
        .onReceive(refreshTimer) { _ in refreshGranted() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshGranted()
        }
    }

    private func refreshGranted() {
        let updated = Set(AppPermission.required.filter { $0.isGranted() })
        guard updated != granted else { return }
        withAnimation(Constants.Animation.transition) {
            granted = updated
        }
    }
}

private struct WelcomePermissionRow: View {
    let permission: AppPermission
    let isGranted: Bool

    @State private var grantFlash = 0

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: permission.accentColor).opacity(0.16))
                    .frame(width: 42, height: 42)
                Image(systemName: permission.iconName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(nsColor: permission.accentColor))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                    .font(.subheadline.weight(.semibold))
                Text(permission.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.sapoGreen)
                    .symbolEffect(.bounce, value: isGranted)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("welcome.grant".localized) {
                    PermissionService.shared.requestInteractively(permission)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isGranted ? Color.sapoGreen.opacity(0.4) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        )
        .permissionGrantCelebration(trigger: grantFlash, cornerRadius: 12)
        .onChange(of: isGranted) { wasGranted, nowGranted in
            if !wasGranted && nowGranted {
                grantFlash += 1
            }
        }
    }
}

// MARK: - Step 3: Engine

private struct WelcomeEngineStep: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    let selectionNamespace: Namespace.ID

    @State private var selectedCard: TranscriptionEngine?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WelcomeStepTitle(
                title: "welcome.engine_title".localized,
                subtitle: "welcome.engine_subtitle".localized
            )

            ScrollView {
                VStack(spacing: 10) {
                    WelcomeWhisperCard(
                        viewModel: viewModel,
                        isSelected: selectedCard == .mlxWhisper,
                        selectionNamespace: selectionNamespace
                    ) {
                        select(.mlxWhisper)
                    }

                    WelcomeLocalAIServerCard(
                        viewModel: viewModel,
                        isSelected: selectedCard == .localAIServer,
                        selectionNamespace: selectionNamespace
                    ) {
                        select(.localAIServer)
                    }

                    WelcomeCloudEngineCard(
                        viewModel: viewModel,
                        engine: .deepgram,
                        tagline: "welcome.deepgram_tagline".localized,
                        isSelected: selectedCard == .deepgram,
                        selectionNamespace: selectionNamespace
                    ) {
                        select(.deepgram)
                    }

                    WelcomeCloudEngineCard(
                        viewModel: viewModel,
                        engine: .elevenLabsScribe,
                        tagline: "welcome.elevenlabs_tagline".localized,
                        isSelected: selectedCard == .elevenLabsScribe,
                        selectionNamespace: selectionNamespace
                    ) {
                        select(.elevenLabsScribe)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 18)
        .onAppear {
            if viewModel.isEngineReady(viewModel.currentEngine) {
                selectedCard = viewModel.currentEngine
            }
        }
    }

    private func select(_ engine: TranscriptionEngine) {
        withAnimation(Constants.Animation.transition) {
            selectedCard = engine
        }
        if viewModel.isEngineReady(engine) {
            viewModel.setEngine(engine)
        }
    }
}

private struct WelcomeEngineCardChrome: ViewModifier {
    let isSelected: Bool
    let selectionNamespace: Namespace.ID

    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.sapoGreen.opacity(0.08) : Color.primary.opacity(0.04))
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.sapoGreen, lineWidth: 2)
                        .matchedGeometryEffect(id: "welcome-engine-selection", in: selectionNamespace)
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
            }
    }
}

private struct WelcomeEngineCardHeader: View {
    let engine: TranscriptionEngine
    let tagline: String
    let isReady: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: engine.icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.sapoGreen)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(engine.displayName)
                    .font(.subheadline.weight(.semibold))
                Text(tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isReady {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.sapoGreen)
                    .symbolEffect(.bounce, value: isReady)
            }
        }
    }
}

private struct WelcomeWhisperCard: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    let isSelected: Bool
    let selectionNamespace: Namespace.ID
    let onSelect: () -> Void

    /// Onboarding shortlist: the balanced tier and the recommended turbo.
    /// The full four-tier catalog lives in Settings.
    private let offeredModels: [MLXWhisperModel] = [.small, .largeV3Turbo]

    private var isReady: Bool {
        viewModel.isEngineReady(.mlxWhisper)
    }

    private var isLoading: Bool {
        viewModel.mlxWhisperTranscriber.isLoading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onSelect) {
                WelcomeEngineCardHeader(
                    engine: .mlxWhisper,
                    tagline: "welcome.whisper_tagline".localized,
                    isReady: isReady
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected && !isReady {
                if isLoading {
                    HStack(spacing: 12) {
                        ProgressRing(progress: viewModel.mlxWhisperTranscriber.loadingProgress)
                            .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("welcome.whisper_downloading".localized)
                                .font(.caption.weight(.semibold))
                            Text(viewModel.mlxWhisperTranscriber.loadingMessage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("welcome.whisper_pick_model".localized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            ForEach(offeredModels) { model in
                                Button {
                                    startDownload(model)
                                } label: {
                                    VStack(spacing: 2) {
                                        HStack(spacing: 4) {
                                            Text(model.displayName)
                                                .font(.caption.weight(.semibold))
                                            if model.isRecommended {
                                                Image(systemName: "star.fill")
                                                    .font(.system(size: 8))
                                                    .foregroundStyle(Color.sapoGreenText)
                                            }
                                        }
                                        Text(model.fileSize)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .modifier(WelcomeEngineCardChrome(isSelected: isSelected, selectionNamespace: selectionNamespace))
        .animation(Constants.Animation.reveal, value: isLoading)
    }

    private func startDownload(_ model: MLXWhisperModel) {
        // setEngine no longer auto-downloads; the explicit model pick does
        // (setMLXWhisperModel downloads + loads when the engine is local).
        viewModel.setEngine(.mlxWhisper)
        viewModel.setMLXWhisperModel(model)
    }
}

private struct WelcomeLocalAIServerCard: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    let isSelected: Bool
    let selectionNamespace: Namespace.ID
    let onSelect: () -> Void

    @AppStorage(Constants.StorageKeys.localAIServerBaseURL) private var baseURL = ""
    @AppStorage(Constants.StorageKeys.localAIServerModel) private var model = LocalAIServerConfiguration.defaultModel
    @State private var apiKey = ""
    @State private var shakeTrigger = 0

    private var isReady: Bool {
        viewModel.isEngineReady(.localAIServer)
    }

    private var canSave: Bool {
        LocalAIServerConfiguration.normalizedBaseURL(from: baseURL) != nil
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onSelect) {
                WelcomeEngineCardHeader(
                    engine: .localAIServer,
                    tagline: "welcome.local_ai_tagline".localized,
                    isReady: isReady
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("config.local_ai_base_url_placeholder".localized, text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    HStack(spacing: 8) {
                        TextField("config.local_ai_model_placeholder".localized, text: $model)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))

                        Menu("config.local_ai_model_suggestions".localized) {
                            ForEach(LocalAIServerConfiguration.suggestedModels, id: \.self) { suggestedModel in
                                Button(suggestedModel) {
                                    model = suggestedModel
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                    }

                    SecureField("config.local_ai_api_key_placeholder".localized, text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    HStack(spacing: 8) {
                        Button("welcome.local_ai_use_server".localized, action: save)
                            .buttonStyle(.bordered)
                            .disabled(!canSave)

                        Text("welcome.local_ai_key_optional".localized)
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Spacer()
                    }
                }
                .modifier(ShakeEffect(trigger: shakeTrigger))
                .transition(.opacity)
            }
        }
        .modifier(WelcomeEngineCardChrome(isSelected: isSelected, selectionNamespace: selectionNamespace))
        .onAppear {
            if KeychainStore.hasValue(for: .localAIServerAPIKey) {
                apiKey = KeychainStore.string(for: .localAIServerAPIKey) ?? ""
            }
        }
    }

    private func save() {
        guard canSave else {
            withAnimation(Constants.Animation.shake) {
                shakeTrigger += 1
            }
            return
        }
        KeychainStore.setString(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: .localAIServerAPIKey)
        viewModel.setEngine(.localAIServer)
    }
}

private struct WelcomeCloudEngineCard: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    let engine: TranscriptionEngine
    let tagline: String
    let isSelected: Bool
    let selectionNamespace: Namespace.ID
    let onSelect: () -> Void

    @State private var apiKey = ""
    @State private var validation: ValidationState = .idle
    @State private var shakeTrigger = 0

    private enum ValidationState: Equatable {
        case idle
        case validating
        case valid
        case invalid(String)
    }

    private var keychainKey: KeychainStore.Key {
        engine == .deepgram ? .deepgramAPIKey : .elevenLabsAPIKey
    }

    private var isReady: Bool {
        viewModel.isEngineReady(engine)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onSelect) {
                WelcomeEngineCardHeader(engine: engine, tagline: tagline, isReady: isReady)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected && !isReady {
                HStack(spacing: 8) {
                    SecureField("welcome.key_placeholder".localized, text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { validate() }

                    Button(action: validate) {
                        switch validation {
                        case .validating:
                            ProgressView()
                                .controlSize(.small)
                        default:
                            Text("welcome.key_validate".localized)
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || validation == .validating)
                }
                .modifier(ShakeEffect(trigger: shakeTrigger))
                .transition(.opacity)

                if case .invalid(let message) = validation {
                    Label(message, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.sapoError)
                        .lineLimit(2)
                }
            }
        }
        .modifier(WelcomeEngineCardChrome(isSelected: isSelected, selectionNamespace: selectionNamespace))
    }

    private func validate() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        validation = .validating

        Task { @MainActor in
            do {
                try await EngineKeyValidator.validate(engine: engine, key: key)
                KeychainStore.setString(key, for: keychainKey)
                viewModel.setEngine(engine)
                withAnimation(Constants.Animation.transition) {
                    validation = .valid
                }
            } catch {
                withAnimation(Constants.Animation.transition) {
                    validation = .invalid(error.localizedDescription)
                }
                withAnimation(Constants.Animation.shake) {
                    shakeTrigger += 1
                }
            }
        }
    }
}

// MARK: - Step 4: AI polish (optional)

private struct WelcomeAIPolishStep: View {
    @AppStorage(Constants.StorageKeys.aiPolishEnabled) private var aiPolishEnabled = false
    @AppStorage(Constants.StorageKeys.aiPolishEndpoint) private var endpointValue = PolishEndpoint.default.rawValue

    @State private var model = PolishEndpoint.default.defaultModel
    @State private var baseURL = PolishEndpoint.default.defaultBaseURL
    @State private var apiKey = ""
    @State private var testState: ProviderTestState = .idle
    @State private var showsOptionalAPIKey = false
    @State private var isLoadingProviderFields = false

    private var endpoint: PolishEndpoint {
        PolishEndpoint(rawValue: endpointValue) ?? .default
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WelcomeStepTitle(
                title: "welcome.ai_title".localized,
                subtitle: "welcome.ai_subtitle".localized
            )

            VStack(alignment: .leading, spacing: 12) {
                Picker("ai.provider.endpoint".localized, selection: $endpointValue) {
                    ForEach(PolishEndpoint.allCases) { endpoint in
                        Text(endpoint.displayName).tag(endpoint.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                if endpoint.usesEditableBaseURL {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ai.provider.base_url".localized)
                            .font(.subheadline)
                        TextField("ai.provider.custom_url_placeholder".localized, text: $baseURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ai.provider.model".localized)
                            .font(.subheadline)
                        PolishModelPicker(endpoint: endpoint, model: $model)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if shouldShowAPIKeyRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                endpoint.requiresAPIKey
                                    ? "ai.provider.api_key".localized : "ai.provider.api_key_optional".localized
                            )
                            .font(.subheadline)
                            SecureField("ai.provider.api_key_placeholder".localized, text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if endpoint == .localServer, !shouldShowAPIKeyRow {
                    Button {
                        loadAPIKeyForEditing()
                        showsOptionalAPIKey = true
                    } label: {
                        Label("ai.provider.optional_key_show".localized, systemImage: "key")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button(action: runTest) {
                        Label("ai.provider.test".localized, systemImage: "bolt.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isUsable || testState == .running)

                    switch testState {
                    case .idle:
                        EmptyView()
                    case .running:
                        ProgressView()
                            .controlSize(.small)
                    case .success(let identifier):
                        Label("ai.provider.test_success".localized(identifier), systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.sapoGreenText)
                            .symbolEffect(.bounce, value: testState)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    case .failure(let message):
                        Label {
                            Text(message)
                                .lineLimit(3)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .font(.caption)
                        .foregroundStyle(Color.sapoError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(message)
                    }

                    Spacer()
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )

            Label("welcome.ai_footnote".localized, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.top, 18)
        .onAppear {
            loadProviderFields(allowLegacyFallback: true, readAPIKey: endpoint.showsAPIKeyByDefault)
        }
        .onChange(of: apiKey) { _, newValue in
            guard !isLoadingProviderFields else { return }
            guard endpoint.showsAPIKeyByDefault || showsOptionalAPIKey else { return }
            KeychainStore.setString(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: endpoint.apiKeychainKey)
            testState = .idle
        }
        .onChange(of: endpointValue) { _, _ in
            loadProviderFields(allowLegacyFallback: false, readAPIKey: endpoint.showsAPIKeyByDefault)
            showsOptionalAPIKey = false
            testState = .idle
        }
        .onChange(of: model) { _, newValue in
            PolishProviderConfiguration.setStoredModel(newValue, for: endpoint)
            testState = .idle
        }
        .onChange(of: baseURL) { _, newValue in
            PolishProviderConfiguration.setStoredBaseURLInput(newValue, for: endpoint)
            testState = .idle
        }
        .animation(Constants.Animation.reveal, value: endpoint)
    }

    private var shouldShowAPIKeyRow: Bool {
        endpoint.showsAPIKeyByDefault || showsOptionalAPIKey
    }

    private var isUsable: Bool {
        let effectiveAPIKey =
            endpoint.showsAPIKeyByDefault || showsOptionalAPIKey
            ? apiKey
            : (PolishProviderConfiguration.hasAPIKeyHint(for: endpoint) ? "stored" : "")
        return PolishProviderConfiguration.isUsable(
            endpoint: endpoint,
            model: model,
            customBaseURL: baseURL,
            apiKey: effectiveAPIKey
        )
    }

    private func runTest() {
        testState = .running
        Task { @MainActor in
            do {
                let response = try await OpenAICompatiblePolisher().runConnectionTest()
                testState = .success(response.modelIdentifier)
                aiPolishEnabled = true
            } catch {
                testState = .failure(PolishProviderError.connectionTestMessage(for: error, endpoint: endpoint))
            }
        }
    }

    private func loadProviderFields(allowLegacyFallback: Bool, readAPIKey: Bool) {
        isLoadingProviderFields = true
        model = PolishProviderConfiguration.storedModel(
            for: endpoint,
            allowLegacyFallback: allowLegacyFallback
        )
        baseURL = PolishProviderConfiguration.storedBaseURLInput(
            for: endpoint,
            allowLegacyFallback: allowLegacyFallback
        )
        apiKey = ""
        if readAPIKey {
            loadAPIKeyForEditing()
        }
        DispatchQueue.main.async {
            isLoadingProviderFields = false
        }
    }

    private func loadAPIKeyForEditing() {
        apiKey = PolishProviderConfiguration.apiKey(for: endpoint, allowLegacyFallback: true)
        if !apiKey.isEmpty, !KeychainStore.hasValue(for: endpoint.apiKeychainKey) {
            KeychainStore.setString(apiKey, for: endpoint.apiKeychainKey)
        }
    }
}

// MARK: - Step 5: Ready

/// Final step doubles as a live test bench: when the user fires their
/// configured trigger and recording starts, it celebrates and closes the
/// flow on its own, handing over to the recording overlay.
private struct WelcomeReadyStep: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    let onFinish: () -> Void

    @State private var appeared = false
    @State private var celebrating = false

    var body: some View {
        ZStack {
            if celebrating {
                celebration
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            } else {
                summary
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(duration: 0.45), value: celebrating)
        .onChange(of: viewModel.appState) { _, state in
            guard state == .recording, !celebrating else { return }
            celebrating = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                onFinish()
            }
        }
    }

    private var subtitle: String {
        let manager = viewModel.hotkeyManager
        if manager.currentTriggerKind == .doubleModifier {
            let modifier = HotkeyDoubleTapModifier.option(for: manager.currentDoubleTapModifier)
            return "welcome.ready_subtitle_double".localized(modifier.symbol)
        }
        return "welcome.ready_subtitle".localized(manager.hotkeyDescription)
    }

    private var summary: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.sapoGreen)
                .symbolEffect(.bounce, value: appeared)
                .onAppear { appeared = true }

            Text("welcome.ready_title".localized)
                .font(.system(size: 26, weight: .bold))

            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            HotkeyKeycapsDemo(trigger: .current(from: viewModel.hotkeyManager))
                .padding(.top, 4)

            tryItCard
                .padding(.top, 10)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
    }

    private var tryItCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.sapoGreen.opacity(0.14))
                    .frame(width: 46, height: 46)
                Image(systemName: "waveform")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.sapoGreen)
                    .symbolEffect(.variableColor.iterative.reversing)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("welcome.ready_try_title".localized)
                    .font(.subheadline.weight(.semibold))
                Text("welcome.ready_try_hint".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: 440)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.sapoGreen.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.sapoGreen.opacity(0.25), lineWidth: 1)
        )
    }

    private var celebration: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(Color.sapoGreen)
                .symbolEffect(.bounce, value: celebrating)

            Text("welcome.ready_perfect".localized)
                .font(.system(size: 30, weight: .bold))

            Text("welcome.ready_perfect_caption".localized)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Shared pieces

private struct WelcomeStepTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.bold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 3.5)
            Circle()
                .trim(from: 0, to: max(0.02, min(progress, 1)))
                .stroke(Color.sapoGreen, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Constants.Animation.transition, value: progress)
        }
    }
}

#Preview("Welcome") {
    WelcomeView(viewModel: SapoWhisperViewModel(), onFinish: {}, onDismiss: {})
}

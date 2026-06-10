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

    static let windowSize = CGSize(width: 660, height: 600)

    var body: some View {
        VStack(spacing: 0) {
            header

            ZStack {
                stepContent
                    .id(step)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        )
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth(duration: 0.35), value: step)

            navigationBar
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
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
                    .animation(.smooth(duration: 0.3), value: step)
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
            WelcomeIntroStep(hotkeyDescription: viewModel.hotkeyManager.hotkeyDescription)
        case .permissions:
            WelcomePermissionsStep()
        case .engine:
            WelcomeEngineStep(viewModel: viewModel, selectionNamespace: engineSelection)
        case .aiPolish:
            WelcomeAIPolishStep()
        case .ready:
            WelcomeReadyStep(hotkeyDescription: viewModel.hotkeyManager.hotkeyDescription)
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
        UserDefaults.standard.bool(forKey: Constants.StorageKeys.aiPolishEnabled)
            && PolishProviderConfiguration.current() != nil
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
    @State private var bouncing = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(nsImage: NSImage(named: "DockIconIdle") ?? NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: Color.sapoGreen.opacity(0.3), radius: 18, y: 6)
                .scaleEffect(bouncing ? 1.04 : 1.0)
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: bouncing)
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

            HotkeyKeycapsDemo()
                .padding(.top, 6)

            Text("welcome.hotkey_caption".localized(hotkeyDescription))
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

/// ⌥ + Space rendered as physical keycaps that press themselves in a loop.
private struct HotkeyKeycapsDemo: View {
    var body: some View {
        HStack(spacing: 12) {
            KeycapView(label: "⌥", width: 56)
            Text("+")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            KeycapView(label: "Space", width: 120)
        }
        .phaseAnimator([false, true]) { content, pressed in
            content
                .scaleEffect(pressed ? 0.94 : 1.0)
        } animation: { pressed in
            pressed ? .spring(duration: 0.18) : .easeOut(duration: 1.1)
        }
    }
}

struct KeycapView: View {
    let label: String
    var width: CGFloat = 52

    var body: some View {
        Text(label)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .frame(width: width, height: 46)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(color: .black.opacity(0.28), radius: 0, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            )
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
                ForEach(AppPermission.allCases) { permission in
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
        let updated = Set(AppPermission.allCases.filter { $0.isGranted() })
        guard updated != granted else { return }
        withAnimation(.smooth(duration: 0.3)) {
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
                        isSelected: selectedCard == .whisperLocal,
                        selectionNamespace: selectionNamespace
                    ) {
                        select(.whisperLocal)
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
        withAnimation(.smooth(duration: 0.3)) {
            selectedCard = engine
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

    private let offeredModels: [WhisperKitModel] = [.base, .small]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onSelect) {
                WelcomeEngineCardHeader(
                    engine: .whisperLocal,
                    tagline: "welcome.whisper_tagline".localized,
                    isReady: viewModel.isWhisperKitReady
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected && !viewModel.isWhisperKitReady {
                if viewModel.isLoadingWhisperKit {
                    HStack(spacing: 12) {
                        ProgressRing(progress: viewModel.whisperKitLoadingProgress)
                            .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("welcome.whisper_downloading".localized)
                                .font(.caption.weight(.semibold))
                            Text(viewModel.whisperKitLoadingMessage)
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
                                        Text(model.displayName)
                                            .font(.caption.weight(.semibold))
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
        .animation(.smooth(duration: 0.25), value: viewModel.isLoadingWhisperKit)
    }

    private func startDownload(_ model: WhisperKitModel) {
        viewModel.selectedWhisperModel = model.rawValue
        viewModel.setEngine(.whisperLocal)
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
                withAnimation(.smooth(duration: 0.3)) {
                    validation = .valid
                }
            } catch {
                withAnimation(.smooth(duration: 0.3)) {
                    validation = .invalid(error.localizedDescription)
                }
                withAnimation(.spring(duration: 0.4)) {
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
    @AppStorage(Constants.StorageKeys.aiPolishModel) private var model = PolishEndpoint.default.defaultModel
    @AppStorage(Constants.StorageKeys.aiPolishCustomBaseURL) private var customBaseURL = ""

    @State private var apiKey = ""
    @State private var testState: ProviderTestState = .idle

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

                if endpoint == .custom {
                    TextField("ai.provider.custom_url_placeholder".localized, text: $customBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ai.provider.model".localized)
                            .font(.subheadline)
                        PolishModelPicker(endpoint: endpoint, model: $model)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("ai.provider.api_key".localized)
                            .font(.subheadline)
                        SecureField("ai.provider.api_key_placeholder".localized, text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                            .foregroundStyle(Color.sapoGreen)
                            .symbolEffect(.bounce, value: testState)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    case .failure(let message):
                        Label(message, systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.sapoError)
                            .lineLimit(2)
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
            apiKey = KeychainStore.string(for: .aiPolishAPIKey) ?? ""
            // The curated-catalog picker needs a valid selection to render
            if endpoint.suggestedModels.isEmpty == false,
                model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                model = endpoint.defaultModel
            }
        }
        .onChange(of: apiKey) { _, newValue in
            KeychainStore.setString(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: .aiPolishAPIKey)
            testState = .idle
        }
        .onChange(of: endpointValue) { oldValue, _ in
            let previous = PolishEndpoint(rawValue: oldValue) ?? .default
            if model.isEmpty || model == previous.defaultModel {
                model = endpoint.defaultModel
            }
            testState = .idle
        }
        .animation(.smooth(duration: 0.25), value: endpoint)
    }

    private var isUsable: Bool {
        PolishProviderConfiguration.isUsable(
            endpoint: endpoint,
            model: model,
            customBaseURL: customBaseURL,
            apiKey: apiKey
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
                testState = .failure(error.localizedDescription)
            }
        }
    }
}

// MARK: - Step 5: Ready

private struct WelcomeReadyStep: View {
    let hotkeyDescription: String
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.sapoGreen)
                .symbolEffect(.bounce, value: appeared)
                .onAppear { appeared = true }

            Text("welcome.ready_title".localized)
                .font(.system(size: 26, weight: .bold))

            Text("welcome.ready_subtitle".localized(hotkeyDescription))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            HotkeyKeycapsDemo()
                .padding(.top, 4)

            Spacer()
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
                .animation(.smooth(duration: 0.3), value: progress)
        }
    }
}

/// Horizontal shake used for failed key validation.
struct ShakeEffect: GeometryEffect {
    var trigger: Int
    var animatableData: CGFloat

    init(trigger: Int) {
        self.trigger = trigger
        self.animatableData = CGFloat(trigger)
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = 7 * sin(animatableData * .pi * 4)
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}

#Preview("Welcome") {
    WelcomeView(viewModel: SapoWhisperViewModel(), onFinish: {}, onDismiss: {})
}

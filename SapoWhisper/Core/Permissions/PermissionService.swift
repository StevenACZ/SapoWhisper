//
//  PermissionService.swift
//  SapoWhisper
//
//  Centralizes permission checks and the guided onboarding flow.
//

import AVFoundation
import AppKit

@MainActor
final class PermissionService {
    static let shared = PermissionService()

    weak var menuBarButton: NSStatusBarButton?
    private var builtFlow: PermissionFlow?

    private init() {}

    var flow: PermissionFlow {
        let kinds = Set(AppPermission.required.map(\.flowKind))
        if let builtFlow, builtFlow.isPresented || Set(builtFlow.model.items.map(\.kind)) == kinds {
            return builtFlow
        }
        let flow = PermissionFlow(configuration: makeFlowConfiguration())
        flow.model.onGranted = { kind in
            guard kind == .microphone else { return }
            MicrophonePermission.noteAudioInputGranted()
            AudioInputPreflightManager.shared.preflightSoon(reason: "mic-granted")
        }
        builtFlow = flow
        return flow
    }

    func isGranted(_ permission: AppPermission) -> Bool {
        permission.isGranted()
    }

    func missingPermissions() -> [AppPermission] {
        AppPermission.required.filter { !isGranted($0) }
    }

    func recordingBlockingPermissions() -> [AppPermission] {
        [.microphone]
    }

    func missingRecordingPermissions() -> [AppPermission] {
        recordingBlockingPermissions().filter { !isGranted($0) }
    }

    private func makeFlowConfiguration() -> PermissionFlowConfiguration {
        PermissionFlowConfiguration(
            appName: "SapoWhisper",
            icon: NSApp.applicationIconImage,
            accent: .sapoGreen,
            items: AppPermission.required.map(\.flowItem),
            defaults: AppPreferences.defaults,
            language: { LocalizationManager.shared.language == "es" ? .spanish : .english },
            legacyCompletionKeys: [Constants.StorageKeys.onboardingComplete],
            menuBarAnchor: { [weak self] in
                guard let button = self?.menuBarButton, let window = button.window else { return nil }
                return window.convertToScreen(button.convert(button.bounds, to: nil))
            }
        )
    }
}

extension AppPermission {
    fileprivate var flowKind: PermissionFlowKind {
        switch self {
        case .microphone:
            return .microphone
        case .accessibility:
            return .accessibility
        case .inputMonitoring:
            return .inputMonitoring
        }
    }

    fileprivate var flowItem: PermissionFlowItem {
        switch self {
        case .microphone:
            return PermissionFlowItem(
                .microphone,
                reason: PermissionFlowText(
                    "Hear your voice so SapoWhisper can turn it into text.",
                    "Escuchar tu voz para que SapoWhisper la convierta en texto."),
                status: {
                    if MicrophonePermission.isGranted { return .granted }
                    return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined ? .notDetermined : .denied
                }
            )
        case .accessibility:
            return PermissionFlowItem(
                .accessibility,
                reason: PermissionFlowText(
                    "Paste your dictation right where you are typing.",
                    "Pegar tu dictado justo donde estás escribiendo.")
            )
        case .inputMonitoring:
            return PermissionFlowItem(
                .inputMonitoring,
                reason: PermissionFlowText(
                    "Start dictating with a double tap of your modifier key.",
                    "Empezar a dictar con un doble toque de tu tecla modificadora.")
            )
        }
    }
}

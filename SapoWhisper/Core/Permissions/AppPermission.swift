//
//  AppPermission.swift
//  SapoWhisper
//
//  Describes the system permissions that SapoWhisper can guide the user through.
//

import AppKit
import ApplicationServices
import AVFoundation
import Speech

enum PermissionPrimingResult {
    case granted
    case needsSystemSettings
    case skipped
}

enum AppPermission: CaseIterable, Hashable, Identifiable {
    case microphone
    case speechRecognition
    case accessibility

    var id: Self { self }

    var title: String {
        switch self {
        case .microphone:
            return "permissions.microphone.title".localized
        case .speechRecognition:
            return "permissions.speech.title".localized
        case .accessibility:
            return "permissions.accessibility.title".localized
        }
    }

    var summary: String {
        switch self {
        case .microphone:
            return "permissions.microphone.summary".localized
        case .speechRecognition:
            return "permissions.speech.summary".localized
        case .accessibility:
            return "permissions.accessibility.summary".localized
        }
    }

    var iconName: String {
        switch self {
        case .microphone:
            return "mic.fill"
        case .speechRecognition:
            return "waveform.and.mic"
        case .accessibility:
            return "accessibility"
        }
    }

    var accentColor: NSColor {
        switch self {
        case .microphone:
            return .systemBlue
        case .speechRecognition:
            return .systemGreen
        case .accessibility:
            return .systemOrange
        }
    }

    var overlayTitle: String {
        switch self {
        case .microphone:
            return "permissions.microphone.overlay_title".localized
        case .speechRecognition:
            return "permissions.speech.overlay_title".localized
        case .accessibility:
            return "permissions.accessibility.overlay_title".localized
        }
    }

    var overlayMessage: String {
        switch self {
        case .microphone:
            return "permissions.microphone.overlay_message".localized
        case .speechRecognition:
            return "permissions.speech.overlay_message".localized
        case .accessibility:
            return "permissions.accessibility.overlay_message".localized
        }
    }

    var overlayFootnote: String {
        "permissions.overlay.footnote".localized
    }

    var helperTitle: String {
        switch self {
        case .microphone:
            return "permissions.microphone.helper_title".localized
        case .speechRecognition:
            return "permissions.speech.helper_title".localized
        case .accessibility:
            return "permissions.accessibility.helper_title".localized
        }
    }

    var helperMessage: String {
        switch self {
        case .microphone:
            return "permissions.microphone.helper_message".localized
        case .speechRecognition:
            return "permissions.speech.helper_message".localized
        case .accessibility:
            return "permissions.accessibility.helper_message".localized
        }
    }

    var supportsAppDragInSettings: Bool {
        self == .accessibility
    }

    var settingsURLs: [URL] {
        [
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(settingsAnchor)"),
            URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)")
        ]
        .compactMap { $0 }
    }

    func isGranted() -> Bool {
        switch self {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .speechRecognition:
            return SFSpeechRecognizer.authorizationStatus() == .authorized
        case .accessibility:
            return AXIsProcessTrusted()
        }
    }

    func detailText(isGranted: Bool) -> String {
        switch self {
        case .microphone:
            return isGranted
                ? "permissions.microphone.active_detail".localized
                : "permissions.microphone.pending_detail".localized
        case .speechRecognition:
            return isGranted
                ? "permissions.speech.active_detail".localized
                : "permissions.speech.pending_detail".localized
        case .accessibility:
            return isGranted
                ? "permissions.accessibility.active_detail".localized
                : "permissions.accessibility.pending_detail".localized
        }
    }

    @MainActor
    func primeSystemAccessIfNeeded() async -> PermissionPrimingResult {
        switch self {
        case .microphone:
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            guard status == .notDetermined else { return .skipped }
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            return granted ? .granted : .needsSystemSettings
        case .speechRecognition:
            let status = SFSpeechRecognizer.authorizationStatus()
            guard status == .notDetermined else { return .skipped }
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                    continuation.resume(returning: authorizationStatus == .authorized)
                }
            }
            return granted ? .granted : .needsSystemSettings
        case .accessibility:
            return .skipped
        }
    }

    private var settingsAnchor: String {
        switch self {
        case .microphone:
            return "Privacy_Microphone"
        case .speechRecognition:
            return "Privacy_SpeechRecognition"
        case .accessibility:
            return "Privacy_Accessibility"
        }
    }
}

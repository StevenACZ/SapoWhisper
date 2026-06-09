//
//  AppPermission.swift
//  SapoWhisper
//
//  Describes the system permissions that SapoWhisper can guide the user through.
//

import AppKit
import ApplicationServices

enum PermissionPrimingResult {
    case granted
    case needsSystemSettings
    case skipped
}

enum AppPermission: CaseIterable, Hashable, Identifiable {
    case microphone
    case accessibility

    var id: Self { self }

    var title: String {
        switch self {
        case .microphone:
            return "permissions.microphone.title".localized
        case .accessibility:
            return "permissions.accessibility.title".localized
        }
    }

    var summary: String {
        switch self {
        case .microphone:
            return "permissions.microphone.summary".localized
        case .accessibility:
            return "permissions.accessibility.summary".localized
        }
    }

    var iconName: String {
        switch self {
        case .microphone:
            return "mic.fill"
        case .accessibility:
            return "accessibility"
        }
    }

    var accentColor: NSColor {
        switch self {
        case .microphone:
            return .systemBlue
        case .accessibility:
            return .systemOrange
        }
    }

    var overlayTitle: String {
        switch self {
        case .microphone:
            return "permissions.microphone.overlay_title".localized
        case .accessibility:
            return "permissions.accessibility.overlay_title".localized
        }
    }

    var overlayMessage: String {
        switch self {
        case .microphone:
            return "permissions.microphone.overlay_message".localized
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
        case .accessibility:
            return "permissions.accessibility.helper_title".localized
        }
    }

    var helperMessage: String {
        switch self {
        case .microphone:
            return "permissions.microphone.helper_message".localized
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
            URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)"),
        ]
        .compactMap { $0 }
    }

    func isGranted() -> Bool {
        switch self {
        case .microphone:
            return MicrophonePermission.isGranted
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
            return await MicrophonePermission.primeIfNeeded()
        case .accessibility:
            return .skipped
        }
    }

    private var settingsAnchor: String {
        switch self {
        case .microphone:
            return "Privacy_Microphone"
        case .accessibility:
            return "Privacy_Accessibility"
        }
    }
}

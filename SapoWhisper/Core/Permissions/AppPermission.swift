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
    case inputMonitoring

    /// Permissions the current configuration actually needs. Input Monitoring
    /// only powers the double-tap trigger's listen-only event tap, so it joins
    /// the guided flow only while that trigger kind is selected.
    static var required: [AppPermission] {
        let triggerKind =
            AppPreferences.defaults.string(forKey: Constants.StorageKeys.hotkeyTriggerKind)
            ?? Constants.Hotkey.defaultTriggerKind
        if triggerKind == HotkeyTriggerKind.doubleModifier.rawValue {
            return [.microphone, .accessibility, .inputMonitoring]
        }
        return [.microphone, .accessibility]
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .microphone:
            return "permissions.microphone.title".localized
        case .accessibility:
            return "permissions.accessibility.title".localized
        case .inputMonitoring:
            return "permissions.input_monitoring.title".localized
        }
    }

    var summary: String {
        switch self {
        case .microphone:
            return "permissions.microphone.summary".localized
        case .accessibility:
            return "permissions.accessibility.summary".localized
        case .inputMonitoring:
            return "permissions.input_monitoring.summary".localized
        }
    }

    var iconName: String {
        switch self {
        case .microphone:
            return "mic.fill"
        case .accessibility:
            return "accessibility"
        case .inputMonitoring:
            return "keyboard.fill"
        }
    }

    var accentColor: NSColor {
        switch self {
        case .microphone:
            return .systemBlue
        case .accessibility:
            return .systemOrange
        case .inputMonitoring:
            return .systemPurple
        }
    }

    var overlayTitle: String {
        switch self {
        case .microphone:
            return "permissions.microphone.overlay_title".localized
        case .accessibility:
            return "permissions.accessibility.overlay_title".localized
        case .inputMonitoring:
            return "permissions.input_monitoring.overlay_title".localized
        }
    }

    var overlayMessage: String {
        switch self {
        case .microphone:
            return "permissions.microphone.overlay_message".localized
        case .accessibility:
            return "permissions.accessibility.overlay_message".localized
        case .inputMonitoring:
            return "permissions.input_monitoring.overlay_message".localized
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
        case .inputMonitoring:
            return "permissions.input_monitoring.helper_title".localized
        }
    }

    var helperMessage: String {
        switch self {
        case .microphone:
            return "permissions.microphone.helper_message".localized
        case .accessibility:
            return "permissions.accessibility.helper_message".localized
        case .inputMonitoring:
            return "permissions.input_monitoring.helper_message".localized
        }
    }

    var supportsAppDragInSettings: Bool {
        // Both panes hold an app list the user can drop SapoWhisper into.
        self == .accessibility || self == .inputMonitoring
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
        case .inputMonitoring:
            return CGPreflightListenEventAccess()
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
        case .inputMonitoring:
            return isGranted
                ? "permissions.input_monitoring.active_detail".localized
                : "permissions.input_monitoring.pending_detail".localized
        }
    }

    @MainActor
    func primeSystemAccessIfNeeded() async -> PermissionPrimingResult {
        switch self {
        case .microphone:
            return await MicrophonePermission.primeIfNeeded()
        case .accessibility:
            return .skipped
        case .inputMonitoring:
            // Shows the system "Keystroke Receiving" dialog once; afterwards
            // the toggle lives in System Settings, so guide the user there.
            return CGRequestListenEventAccess() ? .granted : .needsSystemSettings
        }
    }

    private var settingsAnchor: String {
        switch self {
        case .microphone:
            return "Privacy_Microphone"
        case .accessibility:
            return "Privacy_Accessibility"
        case .inputMonitoring:
            return "Privacy_ListenEvent"
        }
    }
}

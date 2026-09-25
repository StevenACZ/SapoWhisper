//
//  AppPermission.swift
//  SapoWhisper
//
//  Describes the system permissions that SapoWhisper can guide the user through.
//

import AppKit
import ApplicationServices

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
            return .systemOrange
        case .accessibility:
            return .systemBlue
        case .inputMonitoring:
            return .systemPurple
        }
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
}

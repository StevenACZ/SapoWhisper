//
//  PolishMode.swift
//  SapoWhisper
//

import Foundation

/// How the AI polish rewrites the dictation. `normal` cleans fillers and keeps
/// every sentence; `compact` extracts the ideas and instructions and rewrites
/// them as the shortest faithful text (for pasting into AI chats without
/// burning tokens). Benched against real history on OpenRouter, 2026-07-05.
enum PolishMode: String, CaseIterable, Identifiable {
    case normal
    case compact

    static let `default`: PolishMode = .normal

    var id: String { rawValue }

    nonisolated var displayName: String {
        "ai.polish.mode_\(rawValue)".localized
    }

    /// Hover/help copy for the Settings picker.
    nonisolated var helpText: String {
        "ai.polish.mode_\(rawValue)_help".localized
    }

    /// Value persisted in history metadata (`ai_mode`). Normal keeps the
    /// legacy "automatic" so old rows and new rows read the same.
    var historyModeIdentifier: String {
        switch self {
        case .normal:
            return "automatic"
        case .compact:
            return "compact"
        }
    }

    static func current(defaults: UserDefaults = .standard) -> PolishMode {
        let stored = defaults.string(forKey: Constants.StorageKeys.aiPolishMode)
        return stored.flatMap(PolishMode.init(rawValue:)) ?? .default
    }

    /// True when dictations will actually compact right now: compact selected,
    /// polish enabled, and a usable provider configured (key-presence hints
    /// only — never triggers a keychain prompt). Drives the recording accent.
    static func compactIsActive(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Constants.StorageKeys.aiPolishEnabled)
            && current(defaults: defaults) == .compact
            && PolishProviderConfiguration.hasUsableConfiguration(defaults: defaults)
    }
}

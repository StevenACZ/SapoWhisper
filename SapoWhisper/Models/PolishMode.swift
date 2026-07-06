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

/// User-selected minimum LIVE dictation length before AI polish runs (both
/// modes): a 5-second snippet gains nothing from a polish round-trip. This is
/// the one sanctioned duration gate because the USER chooses it explicitly
/// (default Always keeps the historic behavior); silent gates stay forbidden.
/// Manual re-polish from History ignores it — pressing the button is intent.
enum PolishMinimumDuration: Int, CaseIterable, Identifiable {
    case always = 0
    case seconds10 = 10
    case seconds30 = 30
    case seconds45 = 45
    case seconds60 = 60

    var id: Int { rawValue }

    nonisolated var displayName: String {
        self == .always
            ? "ai.polish.min_duration_always".localized
            : "ai.polish.min_duration_from".localized("\(rawValue)")
    }

    static func current(defaults: UserDefaults = .standard) -> PolishMinimumDuration {
        PolishMinimumDuration(rawValue: defaults.integer(forKey: Constants.StorageKeys.aiPolishMinDuration))
            ?? .always
    }

    /// True when a live dictation of `duration` seconds should be polished.
    /// Unknown durations polish (never silently withhold on missing data).
    static func allowsPolish(duration: TimeInterval?, defaults: UserDefaults = .standard) -> Bool {
        guard let duration else { return true }
        return duration >= TimeInterval(current(defaults: defaults).rawValue)
    }
}

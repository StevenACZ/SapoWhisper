//
//  UIPreviewMode.swift
//  SapoWhisper
//

import Foundation

/// Developer-only escape hatch for UI iteration. Launching the app with
/// `SAPO_UI_PREVIEW=1` skips everything that re-triggers macOS consent
/// prompts on ad-hoc rebuilds (keychain reads, the global hotkey event tap,
/// launch permission/onboarding windows). `SAPO_UI_PREVIEW_SCREEN` can name
/// a window ("history" or "welcome") to open right after launch.
/// Normal launches are unaffected: the variable is never set by the app.
nonisolated enum UIPreviewMode {
    static let isActive = ProcessInfo.processInfo.environment["SAPO_UI_PREVIEW"] == "1"

    /// True inside the unit-test host, which launches the full app.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["SAPO_TEST_HOST"] == "1"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// Consent-sensitive launch paths (keychain access, hotkey event tap,
    /// permission windows) are skipped for preview launches and tests; both
    /// run from ad-hoc rebuilds that would re-trigger macOS consent dialogs.
    static var skipsConsentPrompts: Bool { isActive || isRunningTests }

    static var screen: String? {
        guard isActive else { return nil }
        return ProcessInfo.processInfo.environment["SAPO_UI_PREVIEW_SCREEN"]
    }

    /// Raw `WelcomeStep` value to open the welcome flow at, for screenshots
    /// of inner steps (`SAPO_UI_PREVIEW_WELCOME_STEP=3` → AI polish).
    static var welcomeStep: Int? {
        guard isActive,
            let raw = ProcessInfo.processInfo.environment["SAPO_UI_PREVIEW_WELCOME_STEP"]
        else { return nil }
        return Int(raw)
    }
}

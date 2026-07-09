//
//  SapoWhisperApp.swift
//  SapoWhisper
//
//

import SwiftUI

/// Cmd+, arrives at the SwiftUI command layer, but the real settings window
/// is AppKit-managed by MenuBarStatusController — the replaced app-settings
/// command requests it through this notification (same cross-scene pattern
/// as HistoryFocusRequest).
enum SettingsOpenRequest {
    static let notification = Notification.Name("SapoWhisperSettingsOpenRequest")
}

@main
struct SapoWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        PreferredMicrophoneCoordinator.shared.start()
        AudioInputPreflightManager.shared.start()
    }

    var body: some Scene {
        // Placeholder scene only (an App must declare one). Replacing the
        // app-settings command keeps Cmd+, and the Settings menu item away
        // from this empty window and routes them to the real AppKit-managed
        // settings window instead.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("menu.settings".localized) {
                    NotificationCenter.default.post(
                        name: SettingsOpenRequest.notification, object: nil
                    )
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

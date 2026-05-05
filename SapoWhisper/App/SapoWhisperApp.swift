//
//  SapoWhisperApp.swift
//  SapoWhisper
//
//

import SwiftUI

@main
struct SapoWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        PreferredMicrophoneCoordinator.shared.start()
        AudioInputPreflightManager.shared.start()
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

//
//  SapoWhisperApp.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import SwiftUI

@main
struct SapoWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // Menu Bar App principal
        MenuBarExtra {
            MenuBarView()
        } label: {
            Image(systemName: "waveform.circle.fill")
        }
        .menuBarExtraStyle(.window)
        
        // Ventana de configuración (⌘,)
        Settings {
            SettingsView()
        }
    }
}

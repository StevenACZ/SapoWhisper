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
    @StateObject private var viewModel = SapoWhisperViewModel()
    
    var body: some Scene {
        // Menu Bar App principal
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            Image(systemName: "waveform.circle.fill")
        }
        .menuBarExtraStyle(.window)
        
        // Ventana de Configuración (se abre desde el menu)
        Window("", id: "settings") {
            ModelDownloadView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultPosition(.center)
        
        // Preferencias del sistema (⌘,)
        Settings {
            SettingsView()
        }
    }
}

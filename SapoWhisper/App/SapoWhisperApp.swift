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
    @StateObject private var localizationManager = LocalizationManager.shared
    
    var body: some Scene {
        // Menu Bar App principal
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
                .environment(\.locale, localizationManager.locale)
                .id(localizationManager.language) // Force refresh when language changes
        } label: {
            MenuBarIcon(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
        
        // Ventana de Configuración (se abre desde el menu con botón "Configuración")
        Window("", id: "settings") {
            SettingsView(viewModel: viewModel)
                .environment(\.locale, localizationManager.locale)
                .id(localizationManager.language)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultPosition(.center)
    }
}

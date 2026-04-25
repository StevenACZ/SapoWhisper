//
//  AppDelegate.swift
//  SapoWhisper
//
//

import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var menuBarStatusController = MenuBarStatusController(
        viewModel: SapoWhisperAppEnvironment.shared.viewModel
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configurar la app para que no aparezca en el Dock
        NSApp.setActivationPolicy(.accessory)
        menuBarStatusController.start()
        scheduleInitialPermissionCheck()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Safety net: restaurar volumen del sistema si la app se cierra durante grabación
        AutoDuckingManager.shared.forceRestore()
    }

    private func scheduleInitialPermissionCheck() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            PermissionService.shared.showRequirementsWindow()
        }
    }
}

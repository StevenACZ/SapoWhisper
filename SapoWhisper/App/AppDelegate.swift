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
    private var screenChangeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configurar la app para que no aparezca en el Dock
        NSApp.setActivationPolicy(.accessory)
        menuBarStatusController.start()
        observeScreenChanges()
        scheduleInitialPermissionCheck()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AudioInputPreflightManager.shared.preflightSoon(reason: "app-active")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Safety net: restaurar volumen del sistema si la app se cierra durante grabación
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
        AutoDuckingManager.shared.forceRestore()
    }

    private func observeScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            AudioInputPreflightManager.shared.preflightSoon(reason: "screen-change")
        }
    }

    private func scheduleInitialPermissionCheck() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            PermissionService.shared.showRequirementsWindow()
        }
    }
}

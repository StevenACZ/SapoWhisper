//
//  AppDelegate.swift
//  SapoWhisper
//
//

import SwiftUI
import os

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var menuBarStatusController = MenuBarStatusController(
        viewModel: SapoWhisperAppEnvironment.shared.viewModel
    )
    private var screenChangeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configurar la app para que no aparezca en el Dock
        NSApp.setActivationPolicy(.accessory)
        APIKeyKeychainMigration.run()
        EnginePortfolioMigration.run()
        menuBarStatusController.start()
        observeScreenChanges()
        scheduleInitialOnboardingCheck()
        Task.detached(priority: .utility) {
            TemporaryAudioStorage.sweepStaleFiles()
        }
        PerformanceDiagnostics.logDiagnosticsFileLocation()
        PerformanceDiagnostics.logRuntimeSnapshot(reason: "launch", force: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        SapoLog.performance.info("Application became active")
        PerformanceDiagnostics.logRuntimeSnapshot(reason: "app-active")
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
            SapoLog.performance.info("Screen parameters changed")
            PerformanceDiagnostics.logRuntimeSnapshot(reason: "screen-change", force: true)
            AudioInputPreflightManager.shared.preflightSoon(reason: "screen-change")
        }
    }

    private func scheduleInitialOnboardingCheck() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            if WelcomeWindowController.isOnboardingNeeded {
                WelcomeWindowController.shared.show()
            } else {
                PermissionService.shared.showRequirementsWindow()
            }
        }
    }
}

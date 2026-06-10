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
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configurar la app para que no aparezca en el Dock
        NSApp.setActivationPolicy(.accessory)
        APIKeyKeychainMigration.run()
        EnginePortfolioMigration.run()
        menuBarStatusController.start()
        observeScreenChanges()
        observeSleepWake()
        scheduleInitialOnboardingCheck()
        Task.detached(priority: .utility) {
            TemporaryAudioStorage.sweepStaleFiles()
        }
        TemporaryAudioStorage.startDailySweep()
        runHistoryAutoDeleteIfConfigured()
        _ = NetworkReachability.shared
        PerformanceDiagnostics.startDailyResidencyLog()
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
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let sleepObserver {
            workspaceCenter.removeObserver(sleepObserver)
        }
        if let wakeObserver {
            workspaceCenter.removeObserver(wakeObserver)
        }
        AutoDuckingManager.shared.forceRestore()
    }

    /// R1: the app is resident for days — recording must stop cleanly before
    /// sleep, and the hotkey tap / device caches re-validate on wake.
    private func observeSleepWake() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        sleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                SapoWhisperAppEnvironment.shared.viewModel.handleSystemWillSleep()
            }
        }

        wakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                SapoWhisperAppEnvironment.shared.viewModel.handleSystemDidWake()
            }
        }
    }

    private func observeScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                SapoLog.performance.info("Screen parameters changed")
                PerformanceDiagnostics.logRuntimeSnapshot(reason: "screen-change", force: true)
                AudioInputPreflightManager.shared.preflightSoon(reason: "screen-change")
            }
        }
    }

    /// H6: optional age-based retention. 0 (default) means never delete.
    private func runHistoryAutoDeleteIfConfigured() {
        let days = UserDefaults.standard.integer(forKey: Constants.StorageKeys.historyAutoDeleteDays)
        guard days > 0 else { return }
        Task.detached(priority: .utility) {
            let deleted = TranscriptionHistoryManager.shared.deleteEntries(olderThanDays: days)
            if deleted > 0 {
                SapoLog.lifecycle.info(
                    "History auto-delete removed rows=\(deleted, privacy: .public) olderThanDays=\(days, privacy: .public)"
                )
            }
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

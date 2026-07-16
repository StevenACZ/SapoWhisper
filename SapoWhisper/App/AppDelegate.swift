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
        UpdateManager.shared.start()
        menuBarStatusController.start()
        observeScreenChanges()
        observeSleepWake()
        scheduleInitialOnboardingCheck()
        Task.detached(priority: .utility) {
            // Rows stuck in "transcribing" (the app died mid-transcription)
            // resolve to failed first; their audio already lives in History.
            let interrupted = TranscriptionHistoryManager.shared.recoverInterruptedTranscriptions()
            // Recovery first: orphaned dictation WAVs become retranscribable
            // History rows before the stale sweep can consider deleting them.
            let recovery = OrphanAudioRecovery.recoverAbandonedRecordings()
            TemporaryAudioStorage.sweepStaleFiles()
            // The freshest preserved take (crashed WAV or interrupted
            // transcription) becomes the "continue previous dictation" offer.
            var offer: ResumableDictation?
            if let latest = recovery.latest {
                offer = ResumableDictation(
                    historyId: latest.historyId,
                    audioURL: latest.audioURL,
                    duration: latest.duration,
                    capturedAt: latest.modifiedAt
                )
            }
            if let interrupted, let audioPath = interrupted.audioPath,
                interrupted.timestamp > (offer?.capturedAt ?? .distantPast)
            {
                offer = ResumableDictation(
                    historyId: interrupted.id,
                    audioURL: URL(fileURLWithPath: audioPath),
                    duration: interrupted.duration,
                    capturedAt: interrupted.timestamp
                )
            }
            if let offer, Date().timeIntervalSince(offer.capturedAt) < 30 * 60 {
                await MainActor.run {
                    SapoWhisperAppEnvironment.shared.viewModel.offerResumableDictation(offer)
                }
            }
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
        SapoWhisperAppEnvironment.shared.viewModel.handleApplicationWillTerminate()
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
            guard !UIPreviewMode.isRunningTests else { return }
            if UIPreviewMode.isActive {
                presentPreviewScreen()
            } else if WelcomeWindowController.isOnboardingNeeded {
                WelcomeWindowController.shared.show()
            } else {
                PermissionService.shared.showRequirementsWindow()
            }
        }
    }

    /// UI preview launches open the requested window directly, with no
    /// permission or onboarding windows competing for focus.
    private func presentPreviewScreen() {
        switch UIPreviewMode.screen {
        case "history":
            menuBarStatusController.openHistoryWindow()
        case "welcome":
            WelcomeWindowController.shared.show()
        case "settings":
            menuBarStatusController.openSettingsWindow()
        default:
            break
        }
    }
}

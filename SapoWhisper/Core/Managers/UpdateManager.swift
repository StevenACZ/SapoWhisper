//
//  UpdateManager.swift
//  SapoWhisper
//
//  In-app updates via Sparkle. The scheduled daily check only surfaces a
//  pending update (update card + About capsule); downloading, installing, and
//  relaunching happen when the user clicks Install, with progress mirrored
//  in `phase`. Scheduled-check failures stay silent, like the old passive
//  checker; only a user-requested install surfaces errors.
//

import AppKit
import Foundation
import Sparkle
import os

@MainActor
@Observable
final class UpdateManager {

    static let shared = UpdateManager()

    enum Phase: Equatable {
        case idle
        case available(version: String)
        /// nil fraction = size unknown yet (indeterminate spinner).
        case downloading(fraction: Double?)
        case readyToInstall(version: String)
        case installing
        case failed(version: String)
    }

    struct UpdaterSession {
        let isInProgress: @MainActor () -> Bool
        let checkForUpdates: @MainActor () -> Void
    }

    enum ManualCheckStatus: Equatable {
        case idle
        case checking
        case upToDate
    }

    private(set) var phase: Phase = .idle
    /// GitHub release page of the pending update (the appcast item's <link>).
    private(set) var releasePageURL: URL?
    /// Ephemeral "you're up to date" feedback for the About window.
    private(set) var manualCheckStatus: ManualCheckStatus = .idle
    /// Resume seam invocations ("Instalar ahora" with no reply held).
    private(set) var resumeRequestCount = 0
    /// True only while Sparkle's install reply is still held.
    private(set) var canPostpone = false

    var updaterSession: UpdaterSession?

    private var updater: SPUUpdater?
    private var driver: Driver?
    private var updaterDelegate: UpdaterDelegate?

    private var installRequested = false
    private var installNowRequested = false
    private var retryRequested = false
    private var pendingInstallReply: ((SPUUserUpdateChoice) -> Void)?
    private(set) var pendingVersion: String?
    private var pendingIsInformationOnly = false
    private var expectedDownloadBytes: UInt64 = 0
    private var receivedDownloadBytes: UInt64 = 0
    private var manualCheckPending = false
    private var manualCheckResetTask: Task<Void, Never>?
    private var resumeCheckTask: Task<Void, Never>?
    private(set) var resumeCheckPending = false

    private static let resumeCheckMaxAttempts = 40

    // MARK: - Lifecycle

    func start() {
        guard !AppRuntimePaths.isIsolated, updater == nil else { return }

        // The passive pre-Sparkle checker stored these; clean them up once.
        let defaults = AppPreferences.defaults
        defaults.removeObject(forKey: "updateCheckETag")
        defaults.removeObject(forKey: "lastUpdateCheckAt")

        let driver = Driver(manager: self)
        let updaterDelegate = UpdaterDelegate()
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: updaterDelegate
        )
        updater.automaticallyDownloadsUpdates = false
        updater.automaticallyChecksForUpdates = isAutoCheckEnabled

        do {
            try updater.start()
        } catch {
            let detail = Self.startFailureLogDetail(for: error)
            SapoLog.lifecycle.error(
                "Updater failed to start \(detail, privacy: .public)")
            return
        }

        self.driver = driver
        self.updaterDelegate = updaterDelegate
        self.updater = updater
        updaterSession = UpdaterSession(
            isInProgress: { updater.sessionInProgress },
            checkForUpdates: { updater.checkForUpdates() }
        )
    }

    /// Defaults to enabled until the Settings toggle writes the key.
    private var isAutoCheckEnabled: Bool {
        let defaults = AppPreferences.defaults
        guard defaults.object(forKey: Constants.StorageKeys.autoUpdateCheckEnabled) != nil else {
            return true
        }
        return defaults.bool(forKey: Constants.StorageKeys.autoUpdateCheckEnabled)
    }

    /// Settings toggle changed; the @AppStorage binding already wrote the key.
    func autoCheckDidChange(enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
    }

    // MARK: - User actions

    /// Update card / About capsule click: download + install + relaunch, or
    /// retry after a failure. Information-only updates open the release page.
    func installPendingUpdate() {
        guard let updaterSession else { return }
        if pendingIsInformationOnly {
            openReleasePage()
            return
        }
        guard updaterSession.isInProgress() == false else {
            beginRequestedResume(autoInstall: false)
            return
        }
        beginRequestedInstall()
        updaterSession.checkForUpdates()
    }

    func beginRequestedInstall() {
        installRequested = true
        phase = .downloading(fraction: nil)
    }

    func installNow() {
        guard phase != .installing else { return }
        if let pendingInstallReply {
            self.pendingInstallReply = nil
            canPostpone = false
            installRequested = true
            retryRequested = false
            phase = .installing
            pendingInstallReply(.install)
            return
        }
        guard updaterSession != nil else { return }
        if case .failed = phase {
            beginRequestedResume(autoInstall: false, retry: true)
            return
        }
        beginRequestedResume()
    }

    func beginRequestedResume(autoInstall: Bool = true, retry: Bool = false) {
        installRequested = true
        installNowRequested = autoInstall
        retryRequested = retry
        resumeCheckPending = true
        phase = retry ? .downloading(fraction: nil) : .installing
        resumeRequestCount += 1
        resumeCheckTask?.cancel()
        requestResumeCheck(attempt: 0)
    }

    /// Sparkle refuses a check while the aborting session is still tearing
    /// down; retry briefly instead of leaving the card stuck on "installing".
    private func requestResumeCheck(attempt: Int) {
        guard resumeCheckPending else { return }
        guard let updaterSession else { return }
        guard updaterSession.isInProgress() else {
            resumeCheckPending = false
            updaterSession.checkForUpdates()
            return
        }
        guard attempt < Self.resumeCheckMaxAttempts else {
            handleResumeCheckExhausted()
            return
        }
        resumeCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.requestResumeCheck(attempt: attempt + 1)
        }
    }

    /// The prepared update never became resumable; drop the install consent
    /// so no later scheduled check installs unattended.
    func handleResumeCheckExhausted() {
        guard resumeCheckPending else { return }
        installRequested = false
        installNowRequested = false
        retryRequested = false
        resumeCheckPending = false
        phase = .failed(version: pendingVersion ?? "")
    }

    func installLater() {
        guard let pendingInstallReply else { return }
        self.pendingInstallReply = nil
        canPostpone = false
        installRequested = false
        retryRequested = false
        pendingInstallReply(.dismiss)
    }

    /// About window: explicit re-check with visible "up to date" feedback.
    func checkForUpdatesManually() {
        guard let updater, updater.sessionInProgress == false else { return }
        manualCheckResetTask?.cancel()
        manualCheckPending = true
        manualCheckStatus = .checking
        updater.checkForUpdates()
    }

    func openReleasePage() {
        guard let releasePageURL else { return }
        NSWorkspace.shared.open(releasePageURL)
    }

    // MARK: - Driver events (pure state transitions, unit-testable)

    func handleUpdateFound(
        version: String,
        stage: SPUUserUpdateStage,
        releasePage: URL?,
        informationOnly: Bool
    ) -> SPUUserUpdateChoice {
        resumeCheckPending = false
        pendingVersion = version
        pendingIsInformationOnly = informationOnly
        releasePageURL = releasePage
        finishManualCheck(status: .idle)

        guard stage == .notDownloaded else {
            if (installRequested || installNowRequested) && !retryRequested && !informationOnly {
                phase = .installing
                return .install
            }
            installRequested = false
            installNowRequested = false
            retryRequested = false
            phase = .readyToInstall(version: version)
            return .dismiss
        }

        if installRequested && !informationOnly {
            phase = .downloading(fraction: nil)
            return .install
        }
        installRequested = false
        installNowRequested = false
        retryRequested = false
        phase = .available(version: version)
        return .dismiss
    }

    func handleDownloadInitiated() {
        expectedDownloadBytes = 0
        receivedDownloadBytes = 0
        phase = .downloading(fraction: nil)
    }

    func handleDownloadExpectedLength(_ length: UInt64) {
        expectedDownloadBytes = length
    }

    func handleDownloadReceived(bytes: UInt64) {
        receivedDownloadBytes += bytes
        guard expectedDownloadBytes > 0 else { return }
        let fraction = min(1.0, Double(receivedDownloadBytes) / Double(expectedDownloadBytes))
        phase = .downloading(fraction: fraction)
    }

    func handleExtractionStarted() {
        phase = .installing
    }

    func handleReadyToInstall(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if installNowRequested {
            installNowRequested = false
            retryRequested = false
            phase = .installing
            reply(.install)
            return
        }
        retryRequested = false
        pendingInstallReply = reply
        canPostpone = true
        phase = .readyToInstall(version: pendingVersion ?? "")
    }

    func handleInstalling() {
        phase = .installing
    }

    func handleNotFound() {
        guard !resumeCheckPending else {
            pendingInstallReply = nil
            canPostpone = false
            return
        }
        installRequested = false
        installNowRequested = false
        retryRequested = false
        pendingInstallReply = nil
        canPostpone = false
        pendingVersion = nil
        pendingIsInformationOnly = false
        releasePageURL = nil
        phase = .idle
        finishManualCheck(status: .upToDate)
    }

    /// Scheduled-check errors stay silent; a user-requested install shows
    /// a retryable failure row instead.
    func handleError(_ error: Error) {
        guard !resumeCheckPending else {
            pendingInstallReply = nil
            canPostpone = false
            return
        }
        finishManualCheck(status: .idle)
        installNowRequested = false
        retryRequested = false
        pendingInstallReply = nil
        canPostpone = false
        if installRequested, let pendingVersion {
            let detail = LogSanitizer.errorDiagnostic(error, state: "install")
            SapoLog.lifecycle.error("Update failed \(detail, privacy: .public)")
            phase = .failed(version: pendingVersion)
        } else {
            let detail = LogSanitizer.errorDiagnostic(error, state: "check")
            SapoLog.lifecycle.debug("Update failed silently \(detail, privacy: .public)")
            switch phase {
            case .readyToInstall, .installing:
                phase = .readyToInstall(version: pendingVersion ?? "")
            case .idle, .available, .downloading, .failed:
                phase = pendingVersion.map { .available(version: $0) } ?? .idle
            }
        }
        installRequested = false
    }

    static func startFailureLogDetail(for error: Error) -> String {
        LogSanitizer.errorDiagnostic(error, state: "start")
    }

    /// Sparkle tears the session down (abort or completion). Keep the
    /// pending row alive; only roll back an unfinished download, a prepared
    /// update stays offered as ready to install. The
    /// install consent dies with the session — a later scheduled check must
    /// never download and relaunch on its own.
    func handleDismissInstallation() {
        guard !resumeCheckPending else {
            pendingInstallReply = nil
            canPostpone = false
            return
        }
        switch phase {
        case .downloading:
            phase = pendingVersion.map { .available(version: $0) } ?? .idle
        case .installing, .readyToInstall:
            phase = .readyToInstall(version: pendingVersion ?? "")
        case .idle, .available, .failed:
            break
        }
        pendingInstallReply = nil
        canPostpone = false
        installNowRequested = false
        retryRequested = false
        installRequested = false
    }

    private func finishManualCheck(status: ManualCheckStatus) {
        guard manualCheckPending else { return }
        manualCheckPending = false
        manualCheckStatus = status
        guard status != .idle else { return }
        manualCheckResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.manualCheckStatus = .idle
        }
    }
}

// MARK: - Sparkle user driver

/// Bridges Sparkle's user-interaction callbacks onto the manager's phase.
/// Every callback arrives on the main actor (the protocol is NS_SWIFT_UI_ACTOR).
@MainActor
private final class Driver: NSObject, SPUUserDriver {

    private unowned let manager: UpdateManager

    init(manager: UpdateManager) {
        self.manager = manager
    }

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        // Unreached: SUEnableAutomaticChecks in Info.plist suppresses the prompt.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let choice = manager.handleUpdateFound(
            version: appcastItem.displayVersionString,
            stage: state.stage,
            releasePage: appcastItem.infoURL,
            informationOnly: appcastItem.isInformationOnlyUpdate
        )
        reply(choice)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        manager.handleNotFound()
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        manager.handleError(error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        manager.handleDownloadInitiated()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        manager.handleDownloadExpectedLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        manager.handleDownloadReceived(bytes: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        manager.handleExtractionStarted()
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        manager.handleReadyToInstall(reply: reply)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        manager.handleInstalling()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        manager.handleDismissInstallation()
    }
}

// MARK: - Sparkle updater delegate

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
            AppPreferences.defaults.string(forKey: Constants.StorageKeys.updateFeedURLOverride)
        #else
            nil
        #endif
    }
}

//
//  UpdateManagerTests.swift
//  SapoWhisperTests
//
//  Phase-machine coverage for the Sparkle-backed update manager: the driver
//  event handlers are exercised directly, no Sparkle session involved.
//

import AppKit
import Sparkle
import XCTest

@testable import SapoWhisper

/// Stands in for the live `SPUUpdater` session so the resume loop, its guards,
/// and the install intents can be exercised without Sparkle.
@MainActor
private final class UpdaterSessionSpy {
    var isInProgress = false
    var checkCount = 0
    var backgroundCheckCount = 0

    var session: UpdateManager.UpdaterSession {
        UpdateManager.UpdaterSession(
            isInProgress: { self.isInProgress },
            checkForUpdates: { self.checkCount += 1 },
            checkForUpdatesInBackground: { self.backgroundCheckCount += 1 }
        )
    }
}

@MainActor
final class UpdateManagerTests: XCTestCase {

    private var manager: UpdateManager!
    private var savedAutoCheckPreference: Any?
    private var discoveryNow: TimeInterval = 0

    override func setUp() async throws {
        try await super.setUp()
        savedAutoCheckPreference = AppPreferences.defaults.object(
            forKey: Constants.StorageKeys.autoUpdateCheckEnabled)
        discoveryNow = 0
        manager = UpdateManager()
    }

    override func tearDown() async throws {
        manager.stopBackgroundDiscovery()
        manager = nil
        if let savedAutoCheckPreference {
            AppPreferences.defaults.set(
                savedAutoCheckPreference, forKey: Constants.StorageKeys.autoUpdateCheckEnabled)
        } else {
            AppPreferences.defaults.removeObject(
                forKey: Constants.StorageKeys.autoUpdateCheckEnabled)
        }
        savedAutoCheckPreference = nil
        try await super.tearDown()
    }

    // MARK: - Scheduled check surfaces a pending row

    func testScheduledFoundUpdateIsDismissedAndSurfaced() {
        let choice = manager.handleUpdateFound(
            version: "9.9.9",
            stage: .notDownloaded,
            releasePage: URL(string: "https://example.com/release"),
            informationOnly: false
        )

        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(manager.phase, .available(version: "9.9.9"))
        XCTAssertEqual(manager.releasePageURL?.absoluteString, "https://example.com/release")
    }

    func testInformationOnlyUpdateNeverInstalls() {
        manager.installPendingUpdate()  // no updater started: must be a no-op

        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: true)

        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(manager.phase, .available(version: "9.9.9"))
    }

    // MARK: - Download progress

    func testDownloadProgressIsFractionOfExpectedLength() {
        manager.handleDownloadInitiated()
        XCTAssertEqual(manager.phase, .downloading(fraction: nil))

        manager.handleDownloadExpectedLength(1_000)
        manager.handleDownloadReceived(bytes: 250)
        XCTAssertEqual(manager.phase, .downloading(fraction: 0.25))

        manager.handleDownloadReceived(bytes: 750)
        XCTAssertEqual(manager.phase, .downloading(fraction: 1.0))
    }

    func testUnknownContentLengthStaysIndeterminate() {
        manager.handleDownloadInitiated()
        manager.handleDownloadReceived(bytes: 4_096)

        XCTAssertEqual(manager.phase, .downloading(fraction: nil))
    }

    func testDownloadFractionIsCappedAtOne() {
        manager.handleDownloadInitiated()
        manager.handleDownloadExpectedLength(100)
        manager.handleDownloadReceived(bytes: 250)

        XCTAssertEqual(manager.phase, .downloading(fraction: 1.0))
    }

    // MARK: - Install stages

    func testExtractionShowsInstalling() {
        manager.handleExtractionStarted()

        XCTAssertEqual(manager.phase, .installing)
    }

    func testReadyToInstallHoldsTheReplyAndOffersTheChoice() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.beginRequestedInstall()

        var choices: [SPUUserUpdateChoice] = []
        manager.handleReadyToInstall { choices.append($0) }

        XCTAssertTrue(choices.isEmpty)
        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
    }

    func testInstallNowRepliesInstall() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        var choices: [SPUUserUpdateChoice] = []
        manager.handleReadyToInstall { choices.append($0) }

        manager.installNow()

        XCTAssertEqual(choices, [.install])
        XCTAssertEqual(manager.phase, .installing)
    }

    func testInstallLaterRepliesDismissAndKeepsReadyToInstall() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        var choices: [SPUUserUpdateChoice] = []
        manager.handleReadyToInstall { choices.append($0) }

        manager.installLater()

        XCTAssertEqual(choices, [.dismiss])
        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
    }

    func testInstallNowFailureAfterAScheduledReadyUpdateSurfacesTheRetry() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.handleReadyToInstall { _ in }

        manager.installNow()
        manager.handleError(NSError(domain: "SUSparkleErrorDomain", code: 4001))

        XCTAssertEqual(manager.phase, .failed(version: "9.9.9"))
    }

    func testInstallNowTwiceRepliesExactlyOnce() {
        let spy = UpdaterSessionSpy()
        spy.isInProgress = true
        manager.updaterSession = spy.session
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        var choices: [SPUUserUpdateChoice] = []
        manager.handleReadyToInstall { choices.append($0) }

        manager.installNow()
        manager.installNow()

        XCTAssertEqual(choices, [.install])
        XCTAssertEqual(manager.resumeRequestCount, 0)
    }

    func testDismissAfterInstallLaterKeepsTheReadyCardWithoutInstallConsent() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.beginRequestedInstall()
        manager.handleReadyToInstall { _ in }
        manager.installLater()

        manager.handleDismissInstallation()

        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        XCTAssertEqual(choice, .dismiss)
    }

    // MARK: - Resumable update (already downloaded)

    func testScheduledCheckOnADownloadedUpdateOffersTheInstallChoice() {
        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)

        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
    }

    func testResumedCheckAfterInstallNowInstallsWithoutAskingAgain() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.handleReadyToInstall { _ in }
        manager.installLater()
        manager.beginRequestedResume()

        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)

        XCTAssertEqual(choice, .install)
        XCTAssertEqual(manager.phase, .installing)
    }

    func testInstallLaterThenScheduledCheckKeepsTheReadyCard() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.handleReadyToInstall { _ in }
        manager.installLater()

        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)

        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
    }

    func testResumeRequestArmsTheInstallAndRunsOnce() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)

        manager.beginRequestedResume()

        XCTAssertEqual(manager.phase, .installing)
        XCTAssertEqual(manager.resumeRequestCount, 1)

        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)
        XCTAssertEqual(choice, .install)
    }

    func testResumedDownloadedStageInstallsAndKeepsTheInstallNowRequest() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)
        manager.beginRequestedResume()

        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .downloaded, releasePage: nil, informationOnly: false)

        XCTAssertEqual(choice, .install)
        XCTAssertEqual(manager.phase, .installing)

        var choices: [SPUUserUpdateChoice] = []
        manager.handleReadyToInstall { choices.append($0) }
        XCTAssertEqual(choices, [.install])
        XCTAssertEqual(manager.phase, .installing)
    }

    func testReadyAfterAResumeClearsTheInstallNowRequest() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)
        manager.beginRequestedResume()
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .downloaded, releasePage: nil, informationOnly: false)
        manager.handleReadyToInstall { _ in }

        var choices: [SPUUserUpdateChoice] = []
        manager.handleReadyToInstall { choices.append($0) }

        XCTAssertTrue(choices.isEmpty)
        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
    }

    func testInstallLaterTwiceRepliesDismissExactlyOnce() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        var choices: [SPUUserUpdateChoice] = []
        manager.handleReadyToInstall { choices.append($0) }

        manager.installLater()
        manager.installLater()

        XCTAssertEqual(choices, [.dismiss])
        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
    }

    func testDismissOfTheOldSessionKeepsTheArmedResume() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)
        manager.beginRequestedResume()

        manager.handleDismissInstallation()

        XCTAssertEqual(manager.phase, .installing)
        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)
        XCTAssertEqual(choice, .install)
        XCTAssertEqual(manager.phase, .installing)
    }

    func testExhaustedResumeFailsAndDropsTheInstallConsent() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)
        manager.beginRequestedResume()

        manager.handleResumeCheckExhausted()

        XCTAssertEqual(manager.phase, .failed(version: "9.9.9"))
        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)
        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(manager.phase, .failed(version: "9.9.9"))
    }

    func testTheResumePollOutlastsASlowAppcastFetch() {
        let window =
            Double(UpdateManager.resumeCheckMaxAttempts) * UpdateManager.resumeCheckRetryDelay

        XCTAssertGreaterThanOrEqual(window, 70)
    }

    func testReachingTheNewSessionEndsTheResumeLoop() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)
        manager.beginRequestedResume()

        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .downloaded, releasePage: nil, informationOnly: false)

        XCTAssertEqual(choice, .install)
        XCTAssertFalse(manager.resumeCheckPending)

        manager.handleResumeCheckExhausted()

        XCTAssertEqual(manager.phase, .installing)
        var choices: [SPUUserUpdateChoice] = []
        manager.handleReadyToInstall { choices.append($0) }
        XCTAssertEqual(choices, [.install])
    }

    func testExhaustionAfterTheGoalIsReachedKeepsTheInstallRunning() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)
        manager.beginRequestedResume()
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .downloaded, releasePage: nil, informationOnly: false)

        manager.handleResumeCheckExhausted()

        XCTAssertEqual(manager.phase, .installing)
        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)
        XCTAssertEqual(choice, .install)
        XCTAssertEqual(manager.phase, .installing)
    }

    func testUpdateWhileTheSessionIsTearingDownArmsTheResume() {
        let spy = UpdaterSessionSpy()
        spy.isInProgress = true
        manager.updaterSession = spy.session
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)

        manager.installPendingUpdate()

        XCTAssertEqual(manager.phase, .downloading(fraction: nil))
        XCTAssertEqual(manager.resumeRequestCount, 1)
        XCTAssertTrue(manager.resumeCheckPending)
        XCTAssertEqual(spy.checkCount, 0)

        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        XCTAssertEqual(choice, .install)
        XCTAssertEqual(manager.phase, .downloading(fraction: nil))

        var choices: [SPUUserUpdateChoice] = []
        manager.handleReadyToInstall { choices.append($0) }

        XCTAssertTrue(choices.isEmpty)
        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
        XCTAssertTrue(manager.canPostpone)
    }

    func testPostponeIsOfferedOnlyWhileTheReplyIsHeld() {
        XCTAssertFalse(manager.canPostpone)

        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.handleReadyToInstall { _ in }
        XCTAssertTrue(manager.canPostpone)

        manager.installLater()
        XCTAssertFalse(manager.canPostpone)

        manager.handleReadyToInstall { _ in }
        manager.installNow()
        XCTAssertFalse(manager.canPostpone)

        manager.handleReadyToInstall { _ in }
        XCTAssertTrue(manager.canPostpone)

        manager.handleDismissInstallation()
        XCTAssertFalse(manager.canPostpone)
    }

    func testErrorDuringAnArmedResumeKeepsTheInstallRunning() {
        let spy = UpdaterSessionSpy()
        spy.isInProgress = true
        manager.updaterSession = spy.session
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.handleReadyToInstall { _ in }
        manager.installLater()
        manager.installNow()

        manager.handleError(NSError(domain: "SUSparkleErrorDomain", code: 4001))

        XCTAssertEqual(manager.phase, .installing)
        XCTAssertTrue(manager.resumeCheckPending)
        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)
        XCTAssertEqual(choice, .install)
        XCTAssertEqual(manager.phase, .installing)
    }

    func testNotFoundDuringAnArmedResumeKeepsTheInstallRunning() {
        let spy = UpdaterSessionSpy()
        spy.isInProgress = true
        manager.updaterSession = spy.session
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.handleReadyToInstall { _ in }
        manager.installLater()
        manager.installNow()

        manager.handleNotFound()

        XCTAssertEqual(manager.phase, .installing)
        XCTAssertTrue(manager.resumeCheckPending)
        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)
        XCTAssertEqual(choice, .install)
        XCTAssertEqual(manager.phase, .installing)
    }

    func testResumeLoopStopsOnceTheNewSessionWasReached() async {
        let spy = UpdaterSessionSpy()
        spy.isInProgress = true
        manager.updaterSession = spy.session
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)
        manager.beginRequestedResume()
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .downloaded, releasePage: nil, informationOnly: false)
        spy.isInProgress = false

        try? await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(spy.checkCount, 0)
        XCTAssertEqual(manager.phase, .installing)
    }

    func testInstallNowWithoutAnUpdaterLeavesTheCardUntouched() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)

        manager.installNow()

        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
        XCTAssertEqual(manager.resumeRequestCount, 0)
    }

    // MARK: - Retry after a failure

    private func driveToFailedCard(_ spy: UpdaterSessionSpy) {
        manager.updaterSession = spy.session
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.handleReadyToInstall { _ in }
        manager.installNow()
        manager.handleError(NSError(domain: "SUSparkleErrorDomain", code: 4001))
    }

    func testRetryOnANotDownloadedStageStopsAtTheReadyCard() {
        let spy = UpdaterSessionSpy()
        driveToFailedCard(spy)
        XCTAssertEqual(manager.phase, .failed(version: "9.9.9"))

        manager.installNow()

        XCTAssertEqual(manager.phase, .downloading(fraction: nil))
        XCTAssertEqual(spy.checkCount, 1)

        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        XCTAssertEqual(choice, .install)
        XCTAssertEqual(manager.phase, .downloading(fraction: nil))

        var choices: [SPUUserUpdateChoice] = []
        manager.handleReadyToInstall { choices.append($0) }

        XCTAssertTrue(choices.isEmpty)
        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
        XCTAssertTrue(manager.canPostpone)
    }

    func testRetryOnADownloadedStageStopsAtTheReadyCard() {
        let spy = UpdaterSessionSpy()
        driveToFailedCard(spy)

        manager.installNow()
        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .downloaded, releasePage: nil, informationOnly: false)

        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
    }

    func testRetryOnAnInstallingStageStopsAtTheReadyCard() {
        let spy = UpdaterSessionSpy()
        driveToFailedCard(spy)

        manager.installNow()
        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)

        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
    }

    func testRetryThenInstallNowStillInstalls() {
        let spy = UpdaterSessionSpy()
        driveToFailedCard(spy)

        manager.installNow()
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        var choices: [SPUUserUpdateChoice] = []
        manager.handleReadyToInstall { choices.append($0) }
        XCTAssertTrue(choices.isEmpty)

        manager.installNow()

        XCTAssertEqual(choices, [.install])
        XCTAssertEqual(manager.phase, .installing)
    }

    func testUpdateButtonResumeOnAPreparedStageStopsAtTheReadyCard() {
        let spy = UpdaterSessionSpy()
        spy.isInProgress = true
        manager.updaterSession = spy.session
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)

        manager.installPendingUpdate()
        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)

        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
    }

    func testReadyDuringAnArmedRetryEndsThePollAndKeepsTheReadyCard() {
        let spy = UpdaterSessionSpy()
        spy.isInProgress = true
        driveToFailedCard(spy)

        manager.installNow()
        XCTAssertTrue(manager.resumeCheckPending)

        var choices: [SPUUserUpdateChoice] = []
        manager.handleReadyToInstall { choices.append($0) }

        XCTAssertTrue(choices.isEmpty)
        XCTAssertFalse(manager.resumeCheckPending)
        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))

        manager.handleResumeCheckExhausted()
        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))

        manager.installNow()

        XCTAssertEqual(choices, [.install])
        XCTAssertEqual(manager.phase, .installing)
    }

    // MARK: - Errors

    func testScheduledCheckErrorStaysSilent() {
        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        XCTAssertEqual(choice, .dismiss)

        manager.handleError(NSError(domain: "SUSparkleErrorDomain", code: 4001))

        XCTAssertEqual(manager.phase, .available(version: "9.9.9"))
    }

    func testScheduledCheckErrorWithNothingPendingIsIdle() {
        manager.handleError(NSError(domain: "SUSparkleErrorDomain", code: 4001))

        XCTAssertEqual(manager.phase, .idle)
    }

    func testStartFailureDiagnosticOmitsDescriptionPathURLAndSecrets() {
        let error = NSError(
            domain: "SUSparkleErrorDomain",
            code: 4002,
            userInfo: [
                NSLocalizedDescriptionKey: "Failed with api_key=json-secret-123456",
                NSFilePathErrorKey: "/Users/example/private/update.zip",
                NSURLErrorKey: URL(
                    string: "https://updates.example.test/feed?token=url-secret-654321")!,
            ]
        )

        let diagnostic = UpdateManager.startFailureLogDetail(for: error)

        XCTAssertEqual(diagnostic, "state=start domain=SUSparkleErrorDomain code=4002")
        XCTAssertFalse(diagnostic.contains("json-secret"))
        XCTAssertFalse(diagnostic.contains("/Users/example"))
        XCTAssertFalse(diagnostic.contains("updates.example.test"))
        XCTAssertFalse(diagnostic.contains("url-secret"))
    }

    func testErrorWhileReadyToInstallKeepsTheReadyCard() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)

        manager.handleError(NSError(domain: "SUSparkleErrorDomain", code: 4001))

        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
    }

    // MARK: - Session teardown

    func testDismissDuringDownloadRollsBackToAvailable() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.handleDownloadInitiated()

        manager.handleDismissInstallation()

        XCTAssertEqual(manager.phase, .available(version: "9.9.9"))
    }

    /// SECURITY.md promises nothing downloads until the user presses Install.
    /// The install consent must not survive the session teardown, or the next
    /// scheduled check installs and relaunches unattended.
    func testDismissClearsInstallConsentSoTheNextCheckOnlySurfaces() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.beginRequestedInstall()

        manager.handleDismissInstallation()

        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(manager.phase, .available(version: "9.9.9"))
    }

    func testDismissWhileInstallingKeepsTheReadyCard() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.beginRequestedInstall()
        manager.handleExtractionStarted()

        manager.handleDismissInstallation()

        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
    }

    func testDismissKeepsPendingRowAlive() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)

        manager.handleDismissInstallation()

        XCTAssertEqual(manager.phase, .available(version: "9.9.9"))
    }

    // MARK: - Up to date

    func testNotFoundClearsPendingState() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)

        manager.handleNotFound()

        XCTAssertEqual(manager.phase, .idle)
        XCTAssertNil(manager.releasePageURL)
    }

    // MARK: - Silent discovery

    private func armDiscovery(_ spy: UpdaterSessionSpy) {
        AppPreferences.defaults.set(true, forKey: Constants.StorageKeys.autoUpdateCheckEnabled)
        manager.updaterSession = spy.session
        manager.monotonicClock = { [unowned self] in self.discoveryNow }
    }

    func testPopoverOpenAsksForASilentCheck() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)

        manager.requestBackgroundCheck()

        XCTAssertEqual(spy.backgroundCheckCount, 1)
        XCTAssertEqual(spy.checkCount, 0)
        XCTAssertEqual(manager.phase, .idle)
        XCTAssertEqual(manager.manualCheckStatus, .idle)
    }

    func testThePopoverOpenPathAsksForABackgroundCheck() throws {
        let controller = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SapoWhisper/App/MenuBarStatusController.swift")
        let source = try String(contentsOf: controller, encoding: .utf8)
        let openBranch = try XCTUnwrap(source.range(of: "popoverOpenCount += 1"))
        let popoverShown = try XCTUnwrap(
            source.range(of: "popover.show(relativeTo:", range: openBranch.upperBound..<source.endIndex))
        XCTAssertNotNil(
            source.range(
                of: "UpdateManager.shared.requestBackgroundCheck()",
                range: openBranch.upperBound..<popoverShown.lowerBound))
    }

    func testTheAboutWindowOpenPathAsksForABackgroundCheck() throws {
        let controller = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SapoWhisper/App/MenuBarStatusController.swift")
        let source = try String(contentsOf: controller, encoding: .utf8)
        let openFunction = try XCTUnwrap(source.range(of: "func openAboutWindow() {"))
        let windowShown = try XCTUnwrap(
            source.range(of: "show(controller)", range: openFunction.upperBound..<source.endIndex))
        XCTAssertNotNil(
            source.range(
                of: "UpdateManager.shared.requestBackgroundCheck()",
                range: openFunction.upperBound..<windowShown.lowerBound))
    }

    func testTheDiscoveryTimerRunsOnTheRunLoopAndAsksForACheck() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        let fired = expectation(description: "the discovery timer asked for a silent check")
        fired.assertForOverFulfill = false
        manager.backgroundCheckIntervalProvider = { 0.05 }
        manager.updaterSession = UpdateManager.UpdaterSession(
            isInProgress: { spy.isInProgress },
            checkForUpdates: { spy.checkCount += 1 },
            checkForUpdatesInBackground: {
                spy.backgroundCheckCount += 1
                fired.fulfill()
            }
        )

        manager.startBackgroundDiscovery()

        XCTAssertTrue(manager.backgroundDiscoveryArmed)
        wait(for: [fired], timeout: 5)
        manager.stopBackgroundDiscovery()
        XCTAssertEqual(spy.backgroundCheckCount, 1)
    }

    func testWakeNotificationAsksForASilentCheck() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        manager.startBackgroundDiscovery()

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        XCTAssertEqual(spy.backgroundCheckCount, 1)
    }

    func testAllTriggersShareTheFiveMinuteThrottle() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)

        manager.requestBackgroundCheck()
        discoveryNow = UpdateManager.backgroundCheckThrottle - 1
        manager.requestBackgroundCheck()

        XCTAssertEqual(spy.backgroundCheckCount, 1)

        discoveryNow = UpdateManager.backgroundCheckThrottle
        manager.requestBackgroundCheck()

        XCTAssertEqual(spy.backgroundCheckCount, 2)
    }

    func testSilentCheckIsSkippedWhileASessionIsInProgress() {
        let spy = UpdaterSessionSpy()
        spy.isInProgress = true
        armDiscovery(spy)

        manager.requestBackgroundCheck()

        XCTAssertEqual(spy.backgroundCheckCount, 0)
    }

    func testSilentCheckIsSkippedWhileADownloadRuns() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.installPendingUpdate()
        manager.handleDownloadInitiated()

        manager.requestBackgroundCheck()

        XCTAssertEqual(spy.backgroundCheckCount, 0)
        XCTAssertEqual(manager.phase, .downloading(fraction: nil))
    }

    func testDisabledAutoCheckFiresNoTriggerAndDisarmsTheTimer() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        manager.startBackgroundDiscovery()
        XCTAssertTrue(manager.backgroundDiscoveryArmed)

        AppPreferences.defaults.set(false, forKey: Constants.StorageKeys.autoUpdateCheckEnabled)
        manager.autoCheckDidChange(enabled: false)
        manager.requestBackgroundCheck()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        XCTAssertEqual(spy.backgroundCheckCount, 0)
        XCTAssertFalse(manager.backgroundDiscoveryArmed)

        AppPreferences.defaults.set(true, forKey: Constants.StorageKeys.autoUpdateCheckEnabled)
        manager.autoCheckDidChange(enabled: true)

        XCTAssertTrue(manager.backgroundDiscoveryArmed)
    }

    func testSilentCheckThatFindsNothingChangesNoVisibleState() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        manager.requestBackgroundCheck()

        manager.handleNotFound()

        XCTAssertEqual(manager.phase, .idle)
        XCTAssertEqual(manager.manualCheckStatus, .idle)
        XCTAssertNil(manager.pendingVersion)
    }

    func testSilentCheckThatFailsChangesNoVisibleState() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        manager.requestBackgroundCheck()

        manager.handleError(NSError(domain: "SUSparkleErrorDomain", code: 4001))

        XCTAssertEqual(manager.phase, .idle)
        XCTAssertEqual(manager.manualCheckStatus, .idle)
    }

    func testSilentCheckThatFindsAnUpdateShowsTheAvailableCard() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        manager.requestBackgroundCheck()

        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)

        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(manager.phase, .available(version: "9.9.9"))
    }

    func testSilentCheckOnAPreparedStageStillWaitsForInstallNow() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        manager.requestBackgroundCheck()

        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .downloaded, releasePage: nil, informationOnly: false)

        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
    }

    func testManualCheckIsNeverThrottled() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        manager.requestBackgroundCheck()

        manager.checkForUpdatesManually()
        manager.checkForUpdatesManually()

        XCTAssertEqual(spy.checkCount, 2)
        XCTAssertEqual(manager.manualCheckStatus, .checking)
    }

    func testManualCheckDuringASilentSessionRunsWhenTheSessionEnds() {
        let spy = UpdaterSessionSpy()
        spy.isInProgress = true
        armDiscovery(spy)

        manager.checkForUpdatesManually()

        XCTAssertEqual(manager.manualCheckStatus, .checking)
        XCTAssertEqual(spy.checkCount, 0)

        spy.isInProgress = false
        manager.requestManualCheck(attempt: 1)

        XCTAssertEqual(spy.checkCount, 1)
        XCTAssertEqual(manager.manualCheckStatus, .checking)

        manager.handleNotFound()

        XCTAssertEqual(manager.manualCheckStatus, .upToDate)
    }

    func testManualCheckGivesUpQuietlyWhenTheSessionNeverEnds() {
        let spy = UpdaterSessionSpy()
        spy.isInProgress = true
        armDiscovery(spy)

        manager.checkForUpdatesManually()
        XCTAssertEqual(manager.manualCheckStatus, .checking)

        manager.requestManualCheck(attempt: UpdateManager.resumeCheckMaxAttempts)

        XCTAssertEqual(spy.checkCount, 0)
        XCTAssertEqual(manager.manualCheckStatus, .idle)
        XCTAssertEqual(manager.phase, .idle)
    }

    func testUpdateClickDuringTheSilentSessionTeardownEndsAtTheReadyCard() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        manager.requestBackgroundCheck()
        spy.isInProgress = true
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)

        manager.installPendingUpdate()

        XCTAssertEqual(manager.phase, .downloading(fraction: nil))
        XCTAssertTrue(manager.resumeCheckPending)

        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .downloaded, releasePage: nil, informationOnly: false)
        var choices: [SPUUserUpdateChoice] = []
        manager.handleReadyToInstall { choices.append($0) }

        XCTAssertEqual(choice, .dismiss)
        XCTAssertTrue(choices.isEmpty)
        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
    }

    func testUpdateClickDuringAnArmedInstallNowResumeEndsAtTheReadyCard() {
        let spy = UpdaterSessionSpy()
        spy.isInProgress = true
        armDiscovery(spy)
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.handleReadyToInstall { _ in }
        manager.installLater()
        manager.installNow()
        XCTAssertTrue(manager.resumeCheckPending)
        spy.isInProgress = false

        manager.installPendingUpdate()

        XCTAssertEqual(manager.phase, .downloading(fraction: nil))
        XCTAssertTrue(manager.resumeCheckPending)
        XCTAssertEqual(manager.resumeRequestCount, 1)
        XCTAssertEqual(spy.checkCount, 0)

        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .downloaded, releasePage: nil, informationOnly: false)
        var choices: [SPUUserUpdateChoice] = []
        manager.handleReadyToInstall { choices.append($0) }

        XCTAssertEqual(choice, .dismiss)
        XCTAssertTrue(choices.isEmpty)
        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
    }

    func testUpdateClickDuringARunningDownloadIsIgnored() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.installPendingUpdate()
        spy.isInProgress = true
        manager.handleDownloadInitiated()
        manager.handleDownloadExpectedLength(1_000)
        manager.handleDownloadReceived(bytes: 400)
        XCTAssertEqual(manager.phase, .downloading(fraction: 0.4))

        manager.installPendingUpdate()

        XCTAssertEqual(manager.phase, .downloading(fraction: 0.4))
        XCTAssertFalse(manager.resumeCheckPending)
        XCTAssertEqual(manager.resumeRequestCount, 0)
        XCTAssertEqual(spy.checkCount, 1)
    }

    func testUpdateClickWhileInstallingIsIgnored() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.installPendingUpdate()
        spy.isInProgress = true
        manager.handleExtractionStarted()

        manager.installPendingUpdate()

        XCTAssertEqual(manager.phase, .installing)
        XCTAssertFalse(manager.resumeCheckPending)
        XCTAssertEqual(manager.resumeRequestCount, 0)
        XCTAssertEqual(spy.checkCount, 1)
    }

    func testUpdateClickOnAFailedCardStillResumes() {
        let spy = UpdaterSessionSpy()
        spy.isInProgress = true
        armDiscovery(spy)
        driveToFailedCard(spy)
        XCTAssertEqual(manager.phase, .failed(version: "9.9.9"))

        manager.installPendingUpdate()

        XCTAssertEqual(manager.phase, .downloading(fraction: nil))
        XCTAssertTrue(manager.resumeCheckPending)
    }

    // MARK: - Quiet checks from a resting card

    private func armFailedCard() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.installPendingUpdate()
        manager.handleError(NSError(domain: "SUSparkleErrorDomain", code: 4001))
    }

    private func armLaterCard(_ spy: UpdaterSessionSpy) {
        manager.updaterSession = spy.session
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.installPendingUpdate()
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.handleDownloadInitiated()
        manager.handleDownloadExpectedLength(1_000)
        manager.handleDownloadReceived(bytes: 1_000)
        manager.handleReadyToInstall { _ in }
        manager.installLater()
    }

    func testIdleAllowsAQuietCheck() {
        XCTAssertTrue(manager.phaseAllowsQuietCheck)
    }

    func testAnAvailableCardAllowsAQuietCheck() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)

        XCTAssertEqual(manager.phase, .available(version: "9.9.9"))
        XCTAssertTrue(manager.phaseAllowsQuietCheck)
    }

    func testAFailedCardAllowsAQuietCheck() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        armFailedCard()

        XCTAssertEqual(manager.phase, .failed(version: "9.9.9"))
        XCTAssertTrue(manager.phaseAllowsQuietCheck)
    }

    func testDownloadingAndInstallingBlockAQuietCheck() {
        manager.handleDownloadInitiated()
        XCTAssertFalse(manager.phaseAllowsQuietCheck)

        manager.handleExtractionStarted()
        XCTAssertFalse(manager.phaseAllowsQuietCheck)
    }

    func testAHeldReadyReplyBlocksAQuietCheck() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.handleReadyToInstall { _ in }

        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
        XCTAssertFalse(manager.phaseAllowsQuietCheck)
    }

    func testThePostLaterReadyCardBlocksAQuietCheck() {
        armLaterCard(UpdaterSessionSpy())

        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
        XCTAssertFalse(manager.phaseAllowsQuietCheck)
    }

    func testAUserCheckInFlightBlocksAQuietCheck() {
        let spy = UpdaterSessionSpy()
        spy.isInProgress = true
        armDiscovery(spy)

        manager.checkForUpdatesManually()

        XCTAssertEqual(manager.phase, .idle)
        XCTAssertFalse(manager.phaseAllowsQuietCheck)
    }

    func testAResumeInFlightBlocksAQuietCheck() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        armLaterCard(spy)
        spy.isInProgress = true

        manager.installNow()

        XCTAssertTrue(manager.resumeCheckPending)
        XCTAssertFalse(manager.phaseAllowsQuietCheck)
    }

    func testABackgroundCheckWithoutALiveUpdaterKeepsTheThrottleFree() {
        AppPreferences.defaults.set(true, forKey: Constants.StorageKeys.autoUpdateCheckEnabled)
        manager.monotonicClock = { [unowned self] in self.discoveryNow }

        manager.requestBackgroundCheck()

        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        manager.requestBackgroundCheck()

        XCTAssertEqual(spy.backgroundCheckCount, 1)
    }

    func testAQuietCheckRunsFromAFailedCard() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        armFailedCard()

        manager.requestBackgroundCheck()

        XCTAssertEqual(spy.backgroundCheckCount, 1)
        XCTAssertEqual(manager.phase, .failed(version: "9.9.9"))
    }

    func testAnUnattendedSameVersionKeepsTheFailedCard() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        armFailedCard()

        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)

        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(manager.phase, .failed(version: "9.9.9"))
        XCTAssertEqual(manager.pendingVersion, "9.9.9")
    }

    func testAnUnattendedSameVersionKeepsTheAvailableCard() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil,
            informationOnly: false)

        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)

        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(manager.phase, .available(version: "9.9.9"))
    }

    func testAnUnattendedSameVersionKeepsThePostLaterReadyCard() {
        armLaterCard(UpdaterSessionSpy())

        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)

        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
        XCTAssertFalse(manager.canPostpone)
    }

    func testAnUnattendedOlderVersionKeepsTheCard() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil,
            informationOnly: false)

        let choice = manager.handleUpdateFound(
            version: "9.9.8", stage: .notDownloaded, releasePage: nil, informationOnly: false)

        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(manager.phase, .available(version: "9.9.9"))
        XCTAssertEqual(manager.pendingVersion, "9.9.9")
    }

    func testAnUnattendedNewerVersionReplacesTheAvailableCard() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil,
            informationOnly: false)

        let choice = manager.handleUpdateFound(
            version: "9.9.10", stage: .notDownloaded, releasePage: nil, informationOnly: false)

        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(manager.phase, .available(version: "9.9.10"))
    }

    func testAnUnattendedNewerVersionReplacesTheFailedCard() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        armFailedCard()

        let choice = manager.handleUpdateFound(
            version: "9.9.10", stage: .notDownloaded, releasePage: nil, informationOnly: false)

        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(manager.phase, .available(version: "9.9.10"))
    }

    func testAQuietCheckWithoutACallbackLeavesTheManualCheckWorking() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        manager.requestBackgroundCheck()
        XCTAssertEqual(spy.backgroundCheckCount, 1)

        manager.checkForUpdatesManually()
        XCTAssertEqual(spy.checkCount, 1)
        XCTAssertEqual(manager.manualCheckStatus, .checking)

        manager.handleNotFound()

        XCTAssertEqual(manager.manualCheckStatus, .upToDate)
    }

    func testAQuietCheckWithoutACallbackLeavesTheUpdateClickWorking() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.requestBackgroundCheck()
        XCTAssertEqual(spy.backgroundCheckCount, 1)

        manager.installPendingUpdate()

        XCTAssertEqual(manager.phase, .downloading(fraction: nil))
        XCTAssertEqual(spy.checkCount, 1)
    }

    func testAManualCheckQueuedBehindAQuietSessionKeepsItsSpinner() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        _ = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)
        manager.requestBackgroundCheck()
        spy.isInProgress = true

        manager.checkForUpdatesManually()
        let quietChoice = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)

        XCTAssertEqual(quietChoice, .dismiss)
        XCTAssertEqual(manager.manualCheckStatus, .checking)
        XCTAssertEqual(spy.checkCount, 0)

        spy.isInProgress = false
        manager.requestManualCheck(attempt: 1)
        let manualChoice = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)

        XCTAssertEqual(manualChoice, .dismiss)
        XCTAssertEqual(spy.checkCount, 1)
        XCTAssertEqual(manager.manualCheckStatus, .idle)
        XCTAssertEqual(manager.phase, .available(version: "9.9.9"))
    }

    func testAManualCheckFromAFailedCardShowsTheAvailableCardAgain() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        armFailedCard()

        manager.checkForUpdatesManually()
        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .notDownloaded, releasePage: nil, informationOnly: false)

        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(manager.phase, .available(version: "9.9.9"))
        XCTAssertEqual(manager.manualCheckStatus, .idle)
    }

    func testNoUnattendedStageEverInstalls() {
        for stage in [SPUUserUpdateStage.notDownloaded, .downloaded, .installing] {
            manager = UpdateManager()
            armLaterCard(UpdaterSessionSpy())

            let choice = manager.handleUpdateFound(
                version: "9.9.9", stage: stage, releasePage: nil, informationOnly: false)

            XCTAssertEqual(choice, .dismiss)
            XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
        }
    }

    func testInstallNowStillWorksFromThePostLaterCard() {
        let spy = UpdaterSessionSpy()
        armDiscovery(spy)
        armLaterCard(spy)

        manager.installNow()
        let choice = manager.handleUpdateFound(
            version: "9.9.9", stage: .installing, releasePage: nil, informationOnly: false)

        XCTAssertEqual(choice, .install)
        XCTAssertEqual(manager.phase, .installing)
    }
}

//
//  UpdateManagerTests.swift
//  SapoWhisperTests
//
//  Phase-machine coverage for the Sparkle-backed update manager: the driver
//  event handlers are exercised directly, no Sparkle session involved.
//

import Sparkle
import XCTest

@testable import SapoWhisper

/// Stands in for the live `SPUUpdater` session so the resume loop, its guards,
/// and the install intents can be exercised without Sparkle.
@MainActor
private final class UpdaterSessionSpy {
    var isInProgress = false
    var checkCount = 0

    var session: UpdateManager.UpdaterSession {
        UpdateManager.UpdaterSession(
            isInProgress: { self.isInProgress },
            checkForUpdates: { self.checkCount += 1 }
        )
    }
}

@MainActor
final class UpdateManagerTests: XCTestCase {

    private var manager: UpdateManager!

    override func setUp() async throws {
        try await super.setUp()
        manager = UpdateManager()
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
        XCTAssertEqual(manager.phase, .readyToInstall(version: "9.9.9"))
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

        XCTAssertEqual(manager.phase, .installing)
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
}

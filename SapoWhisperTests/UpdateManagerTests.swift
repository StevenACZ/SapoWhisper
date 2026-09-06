//
//  UpdateManagerTests.swift
//  SapoWhisperTests
//
//  Phase-machine coverage for the Sparkle-backed update manager: the driver
//  event handlers are exercised directly, no Sparkle session involved.
//

import XCTest

@testable import SapoWhisper

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
            version: "9.9.9", releasePage: nil, informationOnly: true)

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

    func testExtractionAndReadyToInstallShowInstalling() {
        manager.handleExtractionStarted()
        XCTAssertEqual(manager.phase, .installing)

        XCTAssertEqual(manager.handleReadyToInstall(), .install)
        XCTAssertEqual(manager.phase, .installing)
    }

    // MARK: - Errors

    func testScheduledCheckErrorStaysSilent() {
        let choice = manager.handleUpdateFound(
            version: "9.9.9", releasePage: nil, informationOnly: false)
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

    // MARK: - Session teardown

    func testDismissDuringDownloadRollsBackToAvailable() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", releasePage: nil, informationOnly: false)
        manager.handleDownloadInitiated()

        manager.handleDismissInstallation()

        XCTAssertEqual(manager.phase, .available(version: "9.9.9"))
    }

    /// SECURITY.md promises nothing downloads until the user presses Install.
    /// The install consent must not survive the session teardown, or the next
    /// scheduled check installs and relaunches unattended.
    func testDismissClearsInstallConsentSoTheNextCheckOnlySurfaces() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", releasePage: nil, informationOnly: false)
        manager.beginRequestedInstall()

        manager.handleDismissInstallation()

        let choice = manager.handleUpdateFound(
            version: "9.9.9", releasePage: nil, informationOnly: false)
        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(manager.phase, .available(version: "9.9.9"))
    }

    func testDismissKeepsPendingRowAlive() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", releasePage: nil, informationOnly: false)

        manager.handleDismissInstallation()

        XCTAssertEqual(manager.phase, .available(version: "9.9.9"))
    }

    // MARK: - Up to date

    func testNotFoundClearsPendingState() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", releasePage: nil, informationOnly: false)

        manager.handleNotFound()

        XCTAssertEqual(manager.phase, .idle)
        XCTAssertNil(manager.releasePageURL)
    }
}

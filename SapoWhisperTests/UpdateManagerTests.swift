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

    override func setUp() {
        super.setUp()
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

        manager.handleError("network down")

        XCTAssertEqual(manager.phase, .available(version: "9.9.9"))
    }

    func testScheduledCheckErrorWithNothingPendingIsIdle() {
        manager.handleError("network down")

        XCTAssertEqual(manager.phase, .idle)
    }

    // MARK: - Session teardown

    func testDismissDuringDownloadRollsBackToAvailable() {
        _ = manager.handleUpdateFound(
            version: "9.9.9", releasePage: nil, informationOnly: false)
        manager.handleDownloadInitiated()

        manager.handleDismissInstallation()

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

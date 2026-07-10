//
//  UpdateCheckerTests.swift
//  SapoWhisperTests
//
//  Pure-logic coverage for the update checker: version comparison, release
//  JSON decode, and the 20 h throttle. No network.
//

import XCTest

@testable import SapoWhisper

final class UpdateCheckerTests: XCTestCase {

    // MARK: - isVersion

    func testTwoDigitMinorBeatsSingleDigit() {
        XCTAssertTrue(UpdateChecker.isVersion("2.10.0", newerThan: "2.9.0"))
    }

    func testLeadingVPrefixIsStripped() {
        XCTAssertTrue(UpdateChecker.isVersion("v3.0.0", newerThan: "2.9.0"))
    }

    func testEqualVersionsAreNotNewer() {
        XCTAssertFalse(UpdateChecker.isVersion("2.9.0", newerThan: "2.9.0"))
        XCTAssertFalse(UpdateChecker.isVersion("v2.9.0", newerThan: "2.9.0"))
    }

    func testMalformedVersionsAreNeverNewer() {
        XCTAssertFalse(UpdateChecker.isVersion("banana", newerThan: "2.9.0"))
        XCTAssertFalse(UpdateChecker.isVersion("3.0.0", newerThan: "not-a-version"))
        XCTAssertFalse(UpdateChecker.isVersion("", newerThan: "2.9.0"))
        XCTAssertFalse(UpdateChecker.isVersion("2.9.beta", newerThan: "2.9.0"))
    }

    func testPatchBumpIsNewer() {
        XCTAssertTrue(UpdateChecker.isVersion("2.9.1", newerThan: "2.9.0"))
    }

    func testOlderVersionIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isVersion("2.8.9", newerThan: "2.9.0"))
    }

    func testMissingComponentsPadWithZeros() {
        XCTAssertTrue(UpdateChecker.isVersion("3", newerThan: "2.9.0"))
        XCTAssertFalse(UpdateChecker.isVersion("2.9", newerThan: "2.9.0"))
        XCTAssertTrue(UpdateChecker.isVersion("2.9.0.1", newerThan: "2.9.0"))
    }

    // MARK: - Release decode

    func testLatestReleaseDecodesTagAndURL() throws {
        let json = Data(
            """
            {
              "tag_name": "v2.10.0",
              "html_url": "https://github.com/StevenACZ/SapoWhisper/releases/tag/v2.10.0",
              "name": "SapoWhisper 2.10.0",
              "draft": false
            }
            """.utf8)

        let release = try JSONDecoder().decode(UpdateChecker.LatestRelease.self, from: json)

        XCTAssertEqual(release.tagName, "v2.10.0")
        XCTAssertEqual(release.htmlURL, "https://github.com/StevenACZ/SapoWhisper/releases/tag/v2.10.0")
    }

    func testNormalizedVersionTextStripsPrefixOnly() {
        XCTAssertEqual(UpdateChecker.normalizedVersionText("v2.10.0"), "2.10.0")
        XCTAssertEqual(UpdateChecker.normalizedVersionText("2.10.0"), "2.10.0")
    }

    // MARK: - Throttle

    func testThrottleBlocksWithinTwentyHours() {
        let base: TimeInterval = 1_750_000_000
        XCTAssertTrue(UpdateChecker.isThrottled(lastCheckAt: base, now: base + 19 * 3_600))
        XCTAssertFalse(UpdateChecker.isThrottled(lastCheckAt: base, now: base + 21 * 3_600))
    }

    func testThrottleNeverBlocksTheFirstCheck() {
        XCTAssertFalse(UpdateChecker.isThrottled(lastCheckAt: 0, now: 1_750_000_000))
    }
}

//
//  PolishActivationAndBudgetTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

final class PolishActivationAndBudgetTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "PolishActivationAndBudgetTests")!
        defaults.removePersistentDomain(forName: "PolishActivationAndBudgetTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "PolishActivationAndBudgetTests")
        defaults = nil
        super.tearDown()
    }

    // MARK: - PolishMinimumDuration

    func testDefaultThresholdIsAlways() {
        XCTAssertEqual(PolishMinimumDuration.current(defaults: defaults), .always)
        XCTAssertTrue(PolishMinimumDuration.allowsPolish(duration: 2, defaults: defaults))
    }

    func testStoredThresholdGates() {
        defaults.set(30, forKey: Constants.StorageKeys.aiPolishMinDuration)
        XCTAssertFalse(PolishMinimumDuration.allowsPolish(duration: 12, defaults: defaults))
        XCTAssertTrue(PolishMinimumDuration.allowsPolish(duration: 30, defaults: defaults))
        XCTAssertTrue(PolishMinimumDuration.allowsPolish(duration: 95, defaults: defaults))
    }

    /// Unknown durations must polish — never silently withhold on missing data.
    func testNilDurationAlwaysPolishes() {
        defaults.set(60, forKey: Constants.StorageKeys.aiPolishMinDuration)
        XCTAssertTrue(PolishMinimumDuration.allowsPolish(duration: nil, defaults: defaults))
    }

    /// A stored value outside the menu (stale/manual edit) falls back to
    /// Always instead of inventing a gate the user never picked.
    func testUnknownStoredValueFallsBackToAlways() {
        defaults.set(25, forKey: Constants.StorageKeys.aiPolishMinDuration)
        XCTAssertEqual(PolishMinimumDuration.current(defaults: defaults), .always)
    }

    // MARK: - Compact timeout budget

    /// Compact rewrites the whole transcript in one call with a requirements
    /// scan — the normal per-chunk curve timed out real dictations at 10s
    /// (262 words, 2026-07-05).
    func testCompactHostedBudgetOutgrowsNormalCurve() {
        let chars = 1_500
        let normal = TranscriptPostProcessor.polishTimeout(
            forCharacterCount: chars, duration: 86, usesLocalBudget: false, mode: .normal
        )
        let compact = TranscriptPostProcessor.polishTimeout(
            forCharacterCount: chars, duration: 86, usesLocalBudget: false, mode: .compact
        )
        XCTAssertEqual(normal, 10)
        XCTAssertGreaterThanOrEqual(compact, 20)
        XCTAssertGreaterThan(compact, normal)
    }

    func testCompactHostedBudgetIsCapped() {
        let budget = TranscriptPostProcessor.polishTimeout(
            forCharacterCount: 50_000, duration: 1_800, usesLocalBudget: false, mode: .compact
        )
        XCTAssertEqual(budget, 60)
    }

    /// The overlay countdown must match the single global call compact makes,
    /// not a sum of chunk budgets it will never run.
    func testTotalBudgetCompactUsesSingleCall() {
        let text = String(repeating: "una frase con contenido real. ", count: 300)
        let compactTotal = TranscriptPostProcessor.totalPolishBudget(
            forText: text, duration: 300, usesLocalBudget: false, mode: .compact
        )
        let singleCall = TranscriptPostProcessor.polishTimeout(
            forCharacterCount: text.count, duration: 300, usesLocalBudget: false, mode: .compact
        )
        XCTAssertEqual(compactTotal, singleCall)
    }

    /// Local budgets already scale generously; compact must not shrink them.
    func testLocalBudgetUnchangedByMode() {
        let normal = TranscriptPostProcessor.polishTimeout(
            forCharacterCount: 3_000, duration: 200, usesLocalBudget: true, mode: .normal
        )
        let compact = TranscriptPostProcessor.polishTimeout(
            forCharacterCount: 3_000, duration: 200, usesLocalBudget: true, mode: .compact
        )
        XCTAssertEqual(normal, compact)
    }
}

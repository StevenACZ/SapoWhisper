//
//  TranscriptPolishOutputLanguageTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

final class TranscriptPolishOutputLanguageTests: XCTestCase {

    /// Raw values are persisted in UserDefaults and in exported settings
    /// JSON, so the pre-expansion values must keep decoding forever.
    func testLegacyRawValuesStillDecode() {
        XCTAssertEqual(TranscriptPolishOutputLanguage(rawValue: "same_as_input"), .sameAsInput)
        XCTAssertEqual(TranscriptPolishOutputLanguage(rawValue: "spanish"), .spanish)
        XCTAssertEqual(TranscriptPolishOutputLanguage(rawValue: "english"), .english)
    }

    func testOnlySameAsInputSkipsTranslation() {
        XCTAssertFalse(TranscriptPolishOutputLanguage.sameAsInput.requiresTranslation)
        for language in TranscriptPolishOutputLanguage.allCases where language != .sameAsInput {
            XCTAssertTrue(language.requiresTranslation, "\(language.rawValue) should require translation")
        }
    }

    /// Every explicit target must inject its English name into the prompt so
    /// the polisher actually translates, and must mark the override explicit.
    func testExplicitTargetsBuildTranslationInstruction() {
        for language in TranscriptPolishOutputLanguage.allCases where language != .sameAsInput {
            guard let englishName = language.englishName else {
                XCTFail("\(language.rawValue) is missing an English name")
                continue
            }
            XCTAssertTrue(
                language.promptInstruction.contains("Write the final text in \(englishName)"),
                "\(language.rawValue) prompt should target \(englishName)"
            )
            XCTAssertTrue(language.promptInstruction.contains("translate ALL of it"))
        }
        XCTAssertNil(TranscriptPolishOutputLanguage.sameAsInput.englishName)
    }
}

//
//  WhisperKitModelMatchingTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

/// The on-disk model folder match must be per exact variant: "large-v3" is a
/// substring of "large-v3-v20240930" and "large-v3_turbo", and the old
/// `contains` match cross-deleted sibling variants and reported models as
/// downloaded when only a sibling was.
@MainActor
final class WhisperKitModelMatchingTests: XCTestCase {

    func testEachModelFolderMatchesOnlyItsOwnVariant() {
        for owner in WhisperKitModel.allCases {
            let folder = owner.rawValue
            for candidate in WhisperKitModel.allCases {
                XCTAssertEqual(
                    WhisperKitTranscriber.directoryName(folder, matches: candidate),
                    candidate == owner,
                    "folder \(folder) vs model \(candidate.rawValue)"
                )
            }
        }
    }

    func testLargeV3DoesNotMatchTurboOrDatedFolders() {
        XCTAssertFalse(WhisperKitTranscriber.directoryName("openai_whisper-large-v3_turbo", matches: .largev3))
        XCTAssertFalse(WhisperKitTranscriber.directoryName("openai_whisper-large-v3-v20240930", matches: .largev3))
        XCTAssertFalse(
            WhisperKitTranscriber.directoryName("openai_whisper-large-v3-v20240930_626MB", matches: .largev3V20240930)
        )
        XCTAssertTrue(WhisperKitTranscriber.directoryName("openai_whisper-large-v3", matches: .largev3))
    }

    func testNonModelFoldersNeverMatch() {
        XCTAssertFalse(WhisperKitTranscriber.directoryName("models--argmaxinc--whisperkit-coreml", matches: .small))
        XCTAssertFalse(WhisperKitTranscriber.directoryName("some-random-folder", matches: .small))
    }
}

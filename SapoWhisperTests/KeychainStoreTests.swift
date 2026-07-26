//
//  KeychainStoreTests.swift
//  SapoWhisperTests
//
//  Write safety around the consolidated keychain item: a denied read leaves
//  the in-process payload empty, so a write rebuilt from it would delete every
//  other stored API key.
//

import XCTest

@testable import SapoWhisper

final class KeychainStoreTests: XCTestCase {

    private let storedPayload = [
        KeychainStore.Key.deepgramAPIKey.rawValue: "stored-deepgram",
        KeychainStore.Key.elevenLabsAPIKey.rawValue: "stored-elevenlabs",
    ]

    override func setUp() {
        super.setUp()
        KeychainStore.simulateRead(payload: nil)
    }

    override func tearDown() {
        KeychainStore.simulateRead(payload: nil)
        super.tearDown()
    }

    func testWriteIsRejectedWhileTheReadIsDenied() {
        KeychainStore.simulateRead(payload: [:], isReliable: false)

        XCTAssertFalse(KeychainStore.setString("rotated-deepgram", for: .deepgramAPIKey))
        XCTAssertTrue(KeychainStore.isReadDenied)

        KeychainStore.simulateRead(payload: storedPayload, isReliable: true)

        XCTAssertTrue(KeychainStore.retryDeniedRead())
        XCTAssertEqual(KeychainStore.string(for: .deepgramAPIKey), "stored-deepgram")
        XCTAssertEqual(KeychainStore.string(for: .elevenLabsAPIKey), "stored-elevenlabs")
    }

    func testDeleteIsRejectedWhileTheReadIsDenied() {
        KeychainStore.simulateRead(payload: [:], isReliable: false)

        XCTAssertFalse(KeychainStore.delete(.elevenLabsAPIKey))
        XCTAssertTrue(KeychainStore.isReadDenied)
    }

    func testReliableReadStillWritesAndKeepsTheOtherKeys() {
        KeychainStore.simulateRead(payload: storedPayload, isReliable: true)

        XCTAssertTrue(KeychainStore.setString("rotated-deepgram", for: .deepgramAPIKey))
        XCTAssertFalse(KeychainStore.isReadDenied)
        XCTAssertEqual(KeychainStore.string(for: .deepgramAPIKey), "rotated-deepgram")
        XCTAssertEqual(KeychainStore.string(for: .elevenLabsAPIKey), "stored-elevenlabs")
    }

    func testClearingOneKeyKeepsTheOtherKeysOnAReliableRead() {
        KeychainStore.simulateRead(payload: storedPayload, isReliable: true)

        XCTAssertTrue(KeychainStore.delete(.deepgramAPIKey))
        XCTAssertNil(KeychainStore.string(for: .deepgramAPIKey))
        XCTAssertEqual(KeychainStore.string(for: .elevenLabsAPIKey), "stored-elevenlabs")
    }
}

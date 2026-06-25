//
//  LocalAIServerTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

final class LocalAIServerTests: XCTestCase {

    func testLocalAIServerEndpointNormalizationAcceptsRootBaseURL() throws {
        let baseURL = try XCTUnwrap(LocalAIServerConfiguration.normalizedBaseURL(from: "http://127.0.0.1:8000"))

        XCTAssertEqual(
            LocalAIServerConfiguration.healthURL(from: baseURL).absoluteString,
            "http://127.0.0.1:8000/health"
        )
        XCTAssertEqual(
            LocalAIServerConfiguration.modelsURL(from: baseURL).absoluteString,
            "http://127.0.0.1:8000/v1/models"
        )
        XCTAssertEqual(
            LocalAIServerConfiguration.transcriptionsURL(from: baseURL).absoluteString,
            "http://127.0.0.1:8000/v1/audio/transcriptions"
        )
    }

    func testLocalAIServerEndpointNormalizationAcceptsVersionedBaseURL() throws {
        let baseURL = try XCTUnwrap(LocalAIServerConfiguration.normalizedBaseURL(from: "http://localhost:8000/v1/"))

        XCTAssertEqual(
            LocalAIServerConfiguration.healthURL(from: baseURL).absoluteString,
            "http://localhost:8000/health"
        )
        XCTAssertEqual(
            LocalAIServerConfiguration.modelsURL(from: baseURL).absoluteString,
            "http://localhost:8000/v1/models"
        )
    }

    func testLocalAIServerEndpointNormalizationRejectsAmbiguousBaseURLParts() {
        XCTAssertNil(LocalAIServerConfiguration.normalizedBaseURL(from: "http://user:pass@localhost:8000"))
        XCTAssertNil(LocalAIServerConfiguration.normalizedBaseURL(from: "http://localhost:8000?debug=true"))
        XCTAssertNil(LocalAIServerConfiguration.normalizedBaseURL(from: "http://localhost:8000#health"))
    }

    func testEngineFilterHasLocalAIBucket() {
        XCTAssertTrue(EngineFilter.localAI.matches("Local AI Server · mobiuslabsgmbh/faster-whisper-large-v3-turbo"))
        XCTAssertFalse(EngineFilter.other.matches("Local AI Server"))
    }
}

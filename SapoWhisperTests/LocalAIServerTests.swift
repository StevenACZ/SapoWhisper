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

    // MARK: - Transcription form fields

    func testTranscriptionRequestAlwaysEnablesVADFilter() {
        // vad_filter is the layer that stops Whisper from hallucinating
        // ("Thank you.", repetition loops) on silent or short takes —
        // reproduced against real history audio (2026-07-11). Do not drop it.
        let fields = LocalAIServerTranscriber.transcriptionFormFields(
            model: "faster-whisper", languageCode: nil, vocabularyPrompt: "")
        XCTAssertTrue(fields.contains { $0.name == "vad_filter" && $0.value == "true" })
        XCTAssertTrue(fields.contains { $0.name == "model" && $0.value == "faster-whisper" })
        XCTAssertTrue(fields.contains { $0.name == "response_format" && $0.value == "json" })
    }

    func testTranscriptionRequestOmitsEmptyOptionalFields() {
        let fields = LocalAIServerTranscriber.transcriptionFormFields(
            model: "m", languageCode: nil, vocabularyPrompt: "")
        XCTAssertFalse(fields.contains { $0.name == "language" })
        XCTAssertFalse(fields.contains { $0.name == "prompt" })
    }

    func testTranscriptionRequestIncludesLanguageAndPromptWhenSet() {
        let fields = LocalAIServerTranscriber.transcriptionFormFields(
            model: "m", languageCode: "es", vocabularyPrompt: "Glossary: SapoWhisper.")
        XCTAssertTrue(fields.contains { $0.name == "language" && $0.value == "es" })
        XCTAssertTrue(fields.contains { $0.name == "prompt" && $0.value == "Glossary: SapoWhisper." })
    }
}

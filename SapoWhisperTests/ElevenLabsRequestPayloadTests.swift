//
//  ElevenLabsRequestPayloadTests.swift
//  SapoWhisperTests
//
//  Scribe request contract: both endpoints ask for non-verbatim text, and the
//  realtime glossary rides only on the first audio chunk of a session (the API
//  rejects `previous_text` on any later chunk).
//

@testable import SapoWhisper
import XCTest

@MainActor
final class ElevenLabsRequestPayloadTests: XCTestCase {

    func testBatchFormRequestsNoVerbatim() {
        let fields = ElevenLabsScribeTranscriber.uploadFormFields(languageCode: "spa", keyterms: ["SapoWhisper"])

        XCTAssertTrue(fields.contains { $0.name == "no_verbatim" && $0.value == "true" })
        XCTAssertTrue(fields.contains { $0.name == "model_id" && $0.value == "scribe_v2" })
        XCTAssertTrue(fields.contains { $0.name == "language_code" && $0.value == "spa" })
        XCTAssertTrue(fields.contains { $0.name == "keyterms" && $0.value == "SapoWhisper" })
    }

    func testBatchFormOmitsLanguageForAutoDetect() {
        let fields = ElevenLabsScribeTranscriber.uploadFormFields(languageCode: nil, keyterms: [])

        XCTAssertFalse(fields.contains { $0.name == "language_code" })
        XCTAssertFalse(fields.contains { $0.name == "keyterms" })
    }

    func testRealtimeURLRequestsNoVerbatim() throws {
        let url = ElevenLabsScribeRealtimeTranscriber.realtimeURL(language: "es", keyterms: ["SapoWhisper"])
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

        XCTAssertTrue(items.contains(URLQueryItem(name: "no_verbatim", value: "true")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "model_id", value: "scribe_v2_realtime")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "language_code", value: "spa")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "keyterms", value: "SapoWhisper")))
    }

    func testPreviousTextOnlyOnFirstChunk() throws {
        var context = ElevenLabsRealtimeFirstChunkContext(previousText: "Glossary: SapoWhisper.")

        let first = try chunkPayload(previousText: context.consume())
        let second = try chunkPayload(previousText: context.consume())
        let third = try chunkPayload(previousText: context.consume())

        XCTAssertEqual(first["previous_text"] as? String, "Glossary: SapoWhisper.")
        XCTAssertNil(second["previous_text"])
        XCTAssertNil(third["previous_text"])
    }

    func testEmptyGlossaryOmitsPreviousText() throws {
        var context = ElevenLabsRealtimeFirstChunkContext(previousText: "")

        let first = try chunkPayload(previousText: context.consume())

        XCTAssertNil(first["previous_text"])
        XCTAssertEqual(first["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(first["sample_rate"] as? Int, 16000)
        XCTAssertEqual(first["commit"] as? Bool, false)
    }

    private func chunkPayload(previousText: String?) throws -> [String: Any] {
        let message = try ElevenLabsRealtimeAudioSender.makeChunkMessage(
            audioData: Data(repeating: 0, count: 6_400),
            commit: false,
            previousText: previousText
        )
        let object = try JSONSerialization.jsonObject(with: Data(message.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }
}

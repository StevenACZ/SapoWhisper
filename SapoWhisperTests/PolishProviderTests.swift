//
//  PolishProviderTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

final class PolishProviderTests: XCTestCase {

    func testHostedPresetsRequireKeyAndModel() {
        XCTAssertTrue(
            PolishProviderConfiguration.isUsable(
                endpoint: .openRouter, model: "openai/gpt-5.4-nano", customBaseURL: "", apiKey: "sk-or-123"))
        XCTAssertFalse(
            PolishProviderConfiguration.isUsable(
                endpoint: .openRouter, model: "openai/gpt-5.4-nano", customBaseURL: "", apiKey: ""))
        XCTAssertFalse(
            PolishProviderConfiguration.isUsable(
                endpoint: .openAI, model: "", customBaseURL: "", apiKey: "sk-123"))
    }

    func testCustomEndpointAllowsLocalServerWithoutKey() {
        XCTAssertTrue(
            PolishProviderConfiguration.isUsable(
                endpoint: .custom, model: "llama3.2", customBaseURL: "http://localhost:11434/v1", apiKey: ""))
        XCTAssertFalse(
            PolishProviderConfiguration.isUsable(
                endpoint: .custom, model: "llama3.2", customBaseURL: "not a url", apiKey: ""))
    }

    func testPromptBuilderSanitizesHintsAndWrapsContext() {
        let profile = PromptProfile(
            id: "automatic",
            name: "Clean-up",
            details: "test",
            instruction: "Keep it literal.",
            forcesEnglish: false
        )
        let messages = TranscriptPolishPromptBuilder.makeMessages(
            rawText: "hola mundo",
            promptProfile: profile,
            personalContext: "Backend developer",
            outputLanguage: .sameAsInput,
            keyterms: ["SapoWhisper", "evil\nterm"],
            replacements: ["deep green": "Deepgram"]
        )

        XCTAssertEqual(messages.user, "hola mundo")
        XCTAssertTrue(messages.system.contains("<user_profile>"))
        XCTAssertTrue(messages.system.contains("Backend developer"))
        XCTAssertTrue(messages.system.contains("- evil term"), "newlines in hints must be flattened")
        XCTAssertTrue(messages.system.contains("Stay literal"))
        XCTAssertTrue(messages.system.contains("\"deep green\" -> \"Deepgram\""))
    }

    func testPromptBuilderOmitsContextBlockWhenEmpty() {
        let profile = PromptProfile(
            id: "automatic", name: "Clean-up", details: "", instruction: "Keep it literal.", forcesEnglish: false)
        let messages = TranscriptPolishPromptBuilder.makeMessages(
            rawText: "hola",
            promptProfile: profile,
            personalContext: "   ",
            outputLanguage: .sameAsInput,
            keyterms: [],
            replacements: [:]
        )
        XCTAssertFalse(messages.system.contains("<user_profile>"))
    }
}

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

    func testLocalServerPresetUsesLANDefaultsWithoutKey() {
        XCTAssertEqual(PolishEndpoint.localServer.presetBaseURL, "http://localhost:8081/v1")
        XCTAssertEqual(PolishEndpoint.localServer.defaultModel, "qwen3.6-35b-a3b")
        XCTAssertFalse(PolishEndpoint.localServer.requiresAPIKey)
        XCTAssertFalse(PolishEndpoint.localServer.requiresInternet)
        XCTAssertTrue(
            PolishProviderConfiguration.isUsable(
                endpoint: .localServer, model: PolishEndpoint.localServer.defaultModel, customBaseURL: "", apiKey: ""))
    }

    func testHostedPolishPausesOfflineButCustomDoesNot() throws {
        let suiteName = "test.sapowhisper.polish-offline.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: Constants.StorageKeys.aiPolishEnabled)
        defaults.set(PolishEndpoint.openRouter.rawValue, forKey: Constants.StorageKeys.aiPolishEndpoint)
        XCTAssertTrue(PolishProviderConfiguration.hostedEndpointIsPausedOffline(defaults: defaults, isOffline: true))

        defaults.set(PolishEndpoint.custom.rawValue, forKey: Constants.StorageKeys.aiPolishEndpoint)
        XCTAssertFalse(PolishProviderConfiguration.hostedEndpointIsPausedOffline(defaults: defaults, isOffline: true))
        XCTAssertFalse(PolishProviderConfiguration.hostedEndpointIsPausedOffline(defaults: defaults, isOffline: false))

        defaults.set(PolishEndpoint.localServer.rawValue, forKey: Constants.StorageKeys.aiPolishEndpoint)
        XCTAssertFalse(PolishProviderConfiguration.hostedEndpointIsPausedOffline(defaults: defaults, isOffline: true))
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

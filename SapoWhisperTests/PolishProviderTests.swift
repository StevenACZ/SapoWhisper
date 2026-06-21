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

    func testLANCustomEndpointUsesLocalTimeoutBudget() {
        let lanConfiguration = PolishProviderConfiguration(
            endpoint: .custom,
            baseURL: URL(string: "http://local-ai.local:8081/v1")!,
            model: "qwen3.6-35b-a3b",
            apiKey: ""
        )
        let hostedConfiguration = PolishProviderConfiguration(
            endpoint: .openRouter,
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "openai/gpt-5.4-nano",
            apiKey: "sk-or-123"
        )

        XCTAssertTrue(lanConfiguration.usesLocalTimeoutBudget)
        XCTAssertFalse(hostedConfiguration.usesLocalTimeoutBudget)
    }

    func testStoresModelsSeparatelyPerEndpoint() throws {
        let suiteName = "test.sapowhisper.polish-models.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PolishProviderConfiguration.setStoredModel("openai/gpt-5.4-mini", for: .openRouter, defaults: defaults)
        PolishProviderConfiguration.setStoredModel("qwen36", for: .localServer, defaults: defaults)
        PolishProviderConfiguration.setStoredModel("gpt-5.4-nano", for: .openAI, defaults: defaults)
        PolishProviderConfiguration.setStoredModel("llama3.2", for: .custom, defaults: defaults)

        XCTAssertEqual(PolishProviderConfiguration.storedModel(for: .openRouter, defaults: defaults), "openai/gpt-5.4-mini")
        XCTAssertEqual(PolishProviderConfiguration.storedModel(for: .localServer, defaults: defaults), "qwen36")
        XCTAssertEqual(PolishProviderConfiguration.storedModel(for: .openAI, defaults: defaults), "gpt-5.4-nano")
        XCTAssertEqual(PolishProviderConfiguration.storedModel(for: .custom, defaults: defaults), "llama3.2")
    }

    func testLegacyPresetModelDoesNotLeakIntoCustomOrLocalServer() throws {
        let suiteName = "test.sapowhisper.polish-legacy-model.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("openai/gpt-5.4-nano", forKey: Constants.StorageKeys.aiPolishModel)

        defaults.set(PolishEndpoint.custom.rawValue, forKey: Constants.StorageKeys.aiPolishEndpoint)
        XCTAssertEqual(PolishProviderConfiguration.storedModel(for: .custom, defaults: defaults), "")

        defaults.set(PolishEndpoint.localServer.rawValue, forKey: Constants.StorageKeys.aiPolishEndpoint)
        XCTAssertEqual(
            PolishProviderConfiguration.storedModel(for: .localServer, defaults: defaults),
            PolishEndpoint.localServer.defaultModel
        )
    }

    func testLocalServerBaseURLIsEditableAndSeparatesFromCustom() throws {
        let suiteName = "test.sapowhisper.polish-base-url.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PolishProviderConfiguration.setStoredBaseURLInput(
            "http://local-ai.local:8081/v1",
            for: .localServer,
            defaults: defaults
        )
        PolishProviderConfiguration.setStoredBaseURLInput(
            "http://localhost:11434/v1",
            for: .custom,
            defaults: defaults
        )

        XCTAssertEqual(
            PolishProviderConfiguration.storedBaseURLInput(for: .localServer, defaults: defaults),
            "http://local-ai.local:8081/v1"
        )
        XCTAssertEqual(
            PolishProviderConfiguration.storedBaseURLInput(for: .custom, defaults: defaults),
            "http://localhost:11434/v1"
        )
        XCTAssertTrue(
            PolishProviderConfiguration.isUsable(
                endpoint: .localServer,
                model: PolishEndpoint.localServer.defaultModel,
                customBaseURL: "http://local-ai.local:8081/v1",
                apiKey: ""
            )
        )
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
        XCTAssertTrue(messages.system.contains("accidental repeated filler/closing phrases"))
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

    func testHTTPErrorDescriptionHidesProviderBodyAndHintsProviderMismatch() throws {
        let error = PolishProviderError.httpError(
            statusCode: 401,
            endpoint: .openAI,
            message:
                "Incorrect API key provided: sk-or-v1******************************eb76. You can find your API key at https://platform.openai.com/api-keys."
        )
        let description = try XCTUnwrap(error.errorDescription)

        XCTAssertFalse(description.contains("sk-or-v1"))
        XCTAssertFalse(description.contains("eb76"))
        XCTAssertFalse(description.contains("platform.openai.com"))
        XCTAssertTrue(description.contains("OpenAI"))
        XCTAssertTrue(description.contains("OpenRouter"))
    }

    func testConnectionTestMessageLocalizesLocalNetworkFailure() {
        let message = PolishProviderError.connectionTestMessage(
            for: URLError(.cannotConnectToHost),
            endpoint: .localServer
        )

        XCTAssertFalse(message.contains("Could not connect to the server"))
        XCTAssertTrue(message.contains("Servidor local") || message.contains("Local Server"))
    }
}

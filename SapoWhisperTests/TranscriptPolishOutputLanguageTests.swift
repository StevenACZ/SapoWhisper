//
//  TranscriptPolishOutputLanguageTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

@MainActor
final class TranscriptPolishOutputLanguageTests: XCTestCase {

    private final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responsesByHost: [String: [Result<String, URLError>]] = [:]
        nonisolated(unsafe) static var requestCountsByHost: [String: Int] = [:]
        private static let lock = NSLock()

        static func configure(_ responses: [Result<String, URLError>], for host: String) {
            lock.lock()
            responsesByHost[host] = responses
            requestCountsByHost[host] = 0
            lock.unlock()
        }

        static func requestCount(for host: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return requestCountsByHost[host, default: 0]
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            Self.lock.lock()
            let host = request.url?.host ?? ""
            Self.requestCountsByHost[host, default: 0] += 1
            var responses = Self.responsesByHost[host, default: []]
            let response: Result<String, URLError> =
                responses.isEmpty
                ? .failure(URLError(.badServerResponse)) : responses.removeFirst()
            Self.responsesByHost[host] = responses
            Self.lock.unlock()

            switch response {
            case .success(let content):
                let body = try! JSONSerialization.data(withJSONObject: [
                    "choices": [["message": ["content": content], "finish_reason": "stop"]]
                ])
                let http = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
                )!
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    @dynamicMemberLookup
    private struct TranslationRun {
        let result: TranscriptAIResult
        let requestCount: Int

        subscript<T>(dynamicMember keyPath: KeyPath<TranscriptAIResult, T>) -> T {
            result[keyPath: keyPath]
        }
    }

    private func processEnglishTranslation(
        rawText: String,
        responses: [Result<String, URLError>],
        endpoint: PolishEndpoint = .localServer,
        outputLanguage: TranscriptPolishOutputLanguage = .english
    ) async -> TranslationRun {
        let defaults = AppPreferences.defaults
        let enabledKey = Constants.StorageKeys.aiPolishEnabled
        let languageKey = Constants.StorageKeys.aiPolishOutputLanguage
        let modeKey = Constants.StorageKeys.aiPolishMode
        let previousEnabled = defaults.object(forKey: enabledKey)
        let previousLanguage = defaults.object(forKey: languageKey)
        let previousMode = defaults.object(forKey: modeKey)
        defaults.set(true, forKey: enabledKey)
        defaults.set(outputLanguage.rawValue, forKey: languageKey)
        defaults.set(PolishMode.normal.rawValue, forKey: modeKey)
        defer {
            restore(previousEnabled, key: enabledKey, defaults: defaults)
            restore(previousLanguage, key: languageKey, defaults: defaults)
            restore(previousMode, key: modeKey, defaults: defaults)
        }

        let host = "\(UUID().uuidString.lowercased()).provider.test"
        StubURLProtocol.configure(responses, for: host)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        let processor = TranscriptPostProcessor(
            polisher: OpenAICompatiblePolisher(session: URLSession(configuration: sessionConfiguration)),
            vocabularyManager: VocabularyManager(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("translation-vocab-\(UUID().uuidString).json")
            ),
            memoryManager: AIPolishMemoryManager(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("translation-memory-\(UUID().uuidString).json")
            ),
            recentDictationsProvider: { [] }
        )
        let provider = PolishProviderConfiguration(
            endpoint: endpoint,
            baseURL: URL(string: "https://\(host)/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let result = await processor.process(rawText: rawText, provider: provider)
        return TranslationRun(result: result, requestCount: StubURLProtocol.requestCount(for: host))
    }

    private func restore(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

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

    /// Every explicit target must inject its English name into the LIVE
    /// prompt (the builder's language rule) so the polisher actually
    /// translates — asserting on the production prompt, not on a copy.
    func testExplicitTargetsBuildTranslationInstruction() {
        for language in TranscriptPolishOutputLanguage.allCases where language != .sameAsInput {
            guard let englishName = language.englishName else {
                XCTFail("\(language.rawValue) is missing an English name")
                continue
            }
            let messages = TranscriptPolishPromptBuilder.makeMessages(
                rawText: "hola, ¿cómo estás?",
                personalContext: "",
                outputLanguage: language,
                keyterms: [],
                replacements: [:]
            )
            XCTAssertTrue(
                messages.system.contains("Write the ENTIRE output in \(englishName)"),
                "\(language.rawValue) prompt should target \(englishName)"
            )
        }
        XCTAssertNil(TranscriptPolishOutputLanguage.sameAsInput.englishName)
    }

    /// The language verifier needs an ISO code for every explicit target.
    func testExplicitTargetsExposeNLLanguageCode() {
        XCTAssertNil(TranscriptPolishOutputLanguage.sameAsInput.nlLanguageCode)
        for language in TranscriptPolishOutputLanguage.allCases where language != .sameAsInput {
            XCTAssertNotNil(language.nlLanguageCode, "\(language.rawValue) is missing an NL language code")
        }
    }

    /// With an explicit target the system prompt must demand a full
    /// translation; with same-as-input it must pin the transcript language.
    func testExplicitTargetBuildsFullTranslationRule() {
        let translated = TranscriptPolishPromptBuilder.makeMessages(
            rawText: "hola, ¿cómo estás?",
            personalContext: "",
            outputLanguage: .english,
            keyterms: [],
            replacements: [:]
        )
        XCTAssertTrue(translated.system.contains("Write the ENTIRE output in English"))
        XCTAssertTrue(translated.system.contains("output language = English"))

        let literal = TranscriptPolishPromptBuilder.makeMessages(
            rawText: "hola, ¿cómo estás?",
            personalContext: "",
            outputLanguage: .sameAsInput,
            keyterms: [],
            replacements: [:]
        )
        XCTAssertTrue(literal.system.contains("same dominant language as the transcript"))
        XCTAssertTrue(literal.system.contains("output language = same as transcript"))
    }

    func testTranslationAcceptsFirstAttemptAlreadyInTargetLanguage() async {
        let result = await processEnglishTranslation(
            rawText: "Hola equipo",
            responses: [.success("This message is entirely in English.")]
        )

        XCTAssertEqual(result.status, .applied)
        XCTAssertEqual(result.finalText, "This message is entirely in English.")
        XCTAssertEqual(result.requestCount, 1)
    }

    func testShortUntranslatedOutputIsRetriedAndSecondTranslationApplies() async {
        let result = await processEnglishTranslation(
            rawText: "Hola amigo",
            responses: [.success("Hola amigo"), .success("Hello friend")]
        )

        XCTAssertEqual(result.status, .applied)
        XCTAssertEqual(result.finalText, "Hello friend")
        XCTAssertEqual(result.requestCount, 2)
    }

    func testBothTranslationAttemptsMissingTargetFallBackWithoutApplying() async {
        let result = await processEnglishTranslation(
            rawText: "Hola amigo",
            responses: [.success("Hola amigo"), .success("Buenos días")]
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.rawText, "Hola amigo")
        XCTAssertEqual(result.finalText, "Hola amigo")
        XCTAssertEqual(result.error, "ai.provider.error_translation_failed".localized)
        XCTAssertEqual(result.requestCount, 2)
    }

    func testTranslationRetryErrorFallsBackWithoutApplyingFirstAttempt() async {
        let result = await processEnglishTranslation(
            rawText: "Hola amigo",
            responses: [.success("Hola amigo"), .failure(URLError(.timedOut))]
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.finalText, "Hola amigo")
        XCTAssertEqual(result.error, "ai.provider.error_translation_failed".localized)
        XCTAssertEqual(result.requestCount, 2)
    }

    func testMixedLanguageTranslationIsRetried() async {
        let result = await processEnglishTranslation(
            rawText: "Actualiza la documentación y no borres el cache.",
            responses: [
                .success("Update the documentation. No borres el cache."),
                .success("Update the documentation and do not delete the cache."),
            ]
        )

        XCTAssertEqual(result.status, .applied)
        XCTAssertEqual(result.finalText, "Update the documentation and do not delete the cache.")
        XCTAssertEqual(result.requestCount, 2)
    }

    func testNonLinguisticOutputDoesNotRequireLanguageDetection() async {
        let result = await processEnglishTranslation(
            rawText: "123",
            responses: [.success("123")]
        )

        XCTAssertEqual(result.status, .applied)
        XCTAssertEqual(result.finalText, "123")
        XCTAssertEqual(result.requestCount, 1)
    }

    func testShortUppercaseAndCJKSourceTextCannotBypassTranslation() async {
        let cases = ["Sí.", "HOLA.", "你好。"]
        for source in cases {
            let result = await processEnglishTranslation(
                rawText: source,
                responses: [.success(source), .success("Yes.")]
            )

            XCTAssertEqual(result.status, .applied, source)
            XCTAssertEqual(result.finalText, "Yes.", source)
            XCTAssertEqual(result.requestCount, 2, source)
        }
    }

    func testTechnicalIdentifierDoesNotRequireLanguageDetection() async {
        let result = await processEnglishTranslation(
            rawText: "H264",
            responses: [.success("H264")]
        )

        XCTAssertEqual(result.status, .applied)
        XCTAssertEqual(result.finalText, "H264")
        XCTAssertEqual(result.requestCount, 1)
    }

    func testFilenameDoesNotRequireTranslation() async {
        let result = await processEnglishTranslation(
            rawText: "settings.json",
            responses: [.success("settings.json")],
            outputLanguage: .spanish
        )

        XCTAssertEqual(result.status, .applied)
        XCTAssertEqual(result.finalText, "settings.json")
        XCTAssertEqual(result.requestCount, 1)
    }

    func testSemicolonSeparatedLanguageLeakageIsRetried() async {
        let result = await processEnglishTranslation(
            rawText: "Actualiza la documentación y no borres el cache.",
            responses: [
                .success("Update the documentation; no borres el cache."),
                .success("Update the documentation; do not delete the cache."),
            ]
        )

        XCTAssertEqual(result.status, .applied)
        XCTAssertEqual(result.finalText, "Update the documentation; do not delete the cache.")
        XCTAssertEqual(result.requestCount, 2)
    }

    func testCommaSeparatedLanguageLeakageIsRetried() async {
        let result = await processEnglishTranslation(
            rawText: "Actualiza la documentación y no borres el cache.",
            responses: [
                .success(
                    "Update the documentation, deployment plan, server configuration and release checklist, pero no borres la caché."
                ),
                .success(
                    "Update the documentation, deployment plan, server configuration and release checklist, but do not delete the cache."
                ),
            ]
        )

        XCTAssertEqual(result.status, .applied)
        XCTAssertEqual(result.requestCount, 2)
    }

    func testOneFailedTranslationChunkFallsBackTheWholeTranscript() async {
        let first = String(repeating: "Hola equipo ", count: 130) + ". "
        let second = String(repeating: "No borres cache ", count: 90) + "."
        let raw = first + second
        let translatedFirst = String(repeating: "Hello team ", count: 130) + "."
        let result = await processEnglishTranslation(
            rawText: raw,
            responses: [
                .success(translatedFirst),
                .success("No borres el cache."),
                .success("Todavía no borres el cache."),
            ]
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.finalText, raw.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(result.requestCount, 3)
    }

    func testCollapsedChineseTranslationFallsBackAfterThreeResponses() async {
        let raw = "Necesito que revises el informe de ventas y confirmes si todo quedó listo para la tarde."
        let result = await processEnglishTranslation(
            rawText: raw,
            responses: [.success("好的"), .success("好的"), .success("好的")],
            outputLanguage: .chinese
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.finalText, raw)
        XCTAssertEqual(result.error, "ai.provider.error_translation_failed".localized)
        XCTAssertEqual(result.requestCount, 3)
    }

    func testRunawayChineseTranslationFallsBackAfterThreeResponses() async {
        let raw = "Hola equipo"
        let runaway = String(repeating: "通知", count: 12)
        let result = await processEnglishTranslation(
            rawText: raw,
            responses: [.success(runaway), .success(runaway), .success(runaway)],
            outputLanguage: .chinese
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.finalText, raw)
        XCTAssertEqual(result.requestCount, 3)
    }

    func testRetryOnlyFidelityFailureShipsLastOutputAfterAtMostThreeResponses() async {
        let raw = "Actualiza /tmp/cache y no borres 5 archivos."
        let result = await processEnglishTranslation(
            rawText: raw,
            responses: [
                .success("Update the cache and do not delete files."),
                .success("Esta respuesta sigue completamente en español."),
                .success("Update the cache."),
                .success("Update /tmp/cache and do not delete 5 files."),
            ]
        )

        XCTAssertEqual(result.status, .applied)
        XCTAssertEqual(result.finalText, "Update the cache.")
        XCTAssertEqual(result.requestCount, 3)
    }

    func testRecoveredInstructionGuardDoesNotVetoLastRetryOnlyOutput() async {
        let raw = "Actualiza /tmp/cache y no borres 5 archivos."
        let result = await processEnglishTranslation(
            rawText: raw,
            responses: [
                .success("Sure, here is the update: update /tmp/cache and do not delete 5 files."),
                .success("Update the cache and do not delete files."),
                .success("Update the cache."),
            ]
        )

        XCTAssertEqual(result.status, .applied)
        XCTAssertEqual(result.finalText, "Update the cache.")
        XCTAssertEqual(result.requestCount, 3)
    }

    func testEarlierInstructionRejectionWinsOverLaterTranslationFailure() async {
        let raw = "Investiga WebRTC y dime las fuentes."
        let result = await processEnglishTranslation(
            rawText: raw,
            responses: [
                .success("Sure, here is the polished text: research WebRTC and list the sources."),
                .success("Claro, aquí tienes: investiga WebRTC y dime las fuentes."),
                .success("Claro, aquí tienes de nuevo: investiga WebRTC y dime las fuentes."),
            ]
        )

        XCTAssertEqual(result.status, .rejectedFidelity)
        XCTAssertEqual(result.finalText, raw)
        XCTAssertEqual(result.requestCount, 3)
    }

    func testStructuredFallbackCountsTowardThreeResponseBudget() async {
        let raw = "Investiga WebRTC y dime las fuentes."
        let result = await processEnglishTranslation(
            rawText: raw,
            responses: [
                .success(#"{"filler_scan":[],"polished":"invalid schema"}"#),
                .success("Sure, here is the polished text: research WebRTC and list the sources."),
                .success(#"{"filler_scan":"none","polished":}"#),
                .success(#"{"filler_scan":"none","polished":"Research WebRTC and list the sources."}"#),
            ],
            endpoint: .openAI
        )

        XCTAssertEqual(result.status, .rejectedFidelity)
        XCTAssertEqual(result.finalText, raw)
        XCTAssertEqual(result.requestCount, 3)
    }

}

@MainActor
final class TranscriptPolishTimeoutTests: XCTestCase {

    /// Short dictations keep the snappy 5s budget; long transcripts scale up
    /// so a hosted-provider round-trip fits, capped at 20s (per chunk).
    func testHostedPolishTimeoutScalesWithTranscriptLength() {
        func hostedTimeout(_ count: Int) -> UInt64 {
            TranscriptPostProcessor.polishTimeout(
                forCharacterCount: count, duration: nil, usesLocalBudget: false
            )
        }
        XCTAssertEqual(hostedTimeout(0), 5)
        XCTAssertEqual(hostedTimeout(400), 5)
        XCTAssertEqual(hostedTimeout(1400), 10)
        XCTAssertEqual(hostedTimeout(2814), 17)
        XCTAssertEqual(hostedTimeout(100_000), 20)
    }

    /// The overlay countdown consumes this same total: for chunked
    /// transcripts it must be the SUM of per-chunk budgets — showing the
    /// single-call cap made the HUD hit 0 while the polish was still running.
    func testTotalPolishBudgetSumsChunkBudgets() {
        let text = String(repeating: "Una frase corta que termina bien. ", count: 200)
        let chunks = TranscriptPostProcessor.splitIntoChunks(text)
        XCTAssertGreaterThan(chunks.count, 1)

        let expected = chunks.reduce(UInt64(0)) { total, chunk in
            total
                + TranscriptPostProcessor.polishTimeout(
                    forCharacterCount: chunk.count, duration: nil, usesLocalBudget: false
                )
        }
        let total = TranscriptPostProcessor.totalPolishBudget(
            forText: text, duration: nil, usesLocalBudget: false
        )
        XCTAssertEqual(total, expected)
        XCTAssertGreaterThan(
            total,
            TranscriptPostProcessor.polishTimeout(
                forCharacterCount: text.count, duration: nil, usesLocalBudget: false
            )
        )
    }

    func testLocalPolishTimeoutUsesLargerBudget() {
        let localConfiguration = PolishProviderConfiguration(
            endpoint: .custom,
            baseURL: URL(string: "http://local-ai.local:8081/v1")!,
            model: "qwen3.6-35b-a3b",
            apiKey: ""
        )

        XCTAssertEqual(
            TranscriptPostProcessor.polishTimeout(
                forCharacterCount: 400,
                duration: 36,
                configuration: localConfiguration
            ),
            23
        )
        XCTAssertEqual(
            TranscriptPostProcessor.polishTimeout(
                forCharacterCount: 100_000,
                duration: 600,
                configuration: localConfiguration
            ),
            120
        )
    }
}

@MainActor
final class TranscriptPrePolishCorrectionTests: XCTestCase {

    func testProcessAppliesVocabularyCorrectionsWhenAIPolishIsDisabled() async {
        let key = Constants.StorageKeys.aiPolishEnabled
        let defaults = AppPreferences.defaults
        let previous = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let vocabularyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pre-polish-vocab-\(UUID().uuidString).json")
        let vocabularyManager = VocabularyManager(fileURL: vocabularyURL)
        vocabularyManager.addKeyterm("SapoWhisper")
        vocabularyManager.addKeyterm("CLAUDE.md")

        let memoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pre-polish-memory-\(UUID().uuidString).json")
        let memoryManager = AIPolishMemoryManager(fileURL: memoryURL)
        let processor = TranscriptPostProcessor(vocabularyManager: vocabularyManager, memoryManager: memoryManager)
        let result = await processor.process(rawText: "  open sap o whisper and claude dot md \n")

        XCTAssertEqual(result.status, .none)
        XCTAssertEqual(result.rawText, "open sap o whisper and claude dot md")
        XCTAssertEqual(result.finalText, "open SapoWhisper and CLAUDE.md")
    }

    func testProcessTrimsEmptyRawTextWithoutApplyingCorrections() async {
        let processor = TranscriptPostProcessor(
            vocabularyManager: VocabularyManager(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("empty-pre-polish-vocab-\(UUID().uuidString).json")
            ),
            memoryManager: AIPolishMemoryManager(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("empty-pre-polish-memory-\(UUID().uuidString).json")
            )
        )

        let result = await processor.process(rawText: " \n\t ")

        XCTAssertEqual(result.status, .none)
        XCTAssertEqual(result.rawText, "")
        XCTAssertEqual(result.finalText, "")
    }
}

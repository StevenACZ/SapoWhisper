import XCTest

@testable import SapoWhisper

@MainActor
final class TranscriptCorrectionOwnershipTests: XCTestCase {
    func testChainedReplacementsDistinguishOnePassFromProviderPreprocessing() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vocabulary = makeVocabulary(in: directory)

        let input = "a, A! aardvark Beacon."
        let once = vocabulary.applyingRecognitionCorrections(to: input)
        let providerCorrected = vocabulary.applyingReplacements(to: input)
        let twice = vocabulary.applyingRecognitionCorrections(to: providerCorrected)

        XCTAssertEqual(once, "Beacon, Beacon! aardvark Cedar.")
        XCTAssertEqual(twice, "Cedar, Cedar! aardvark Cedar.")
        XCTAssertNotEqual(once, twice)
    }

    func testSharedProcessingAppliesOneCorrectionPassWithoutAIPolish() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = AppPreferences.defaults
        let enabledKey = Constants.StorageKeys.aiPolishEnabled
        let previous = defaults.object(forKey: enabledKey)
        defaults.set(false, forKey: enabledKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: enabledKey)
            } else {
                defaults.removeObject(forKey: enabledKey)
            }
        }
        let vocabulary = makeVocabulary(in: directory)
        let processor = TranscriptPostProcessor(
            vocabularyManager: vocabulary,
            memoryManager: AIPolishMemoryManager(fileURL: directory.appendingPathComponent("memory.json")),
            recentDictationsProvider: { [] }
        )
        let fixtures = [
            ("  a  ", "a", "Beacon"),
            ("A, a! aardvark", "A, a! aardvark", "Beacon, Beacon! aardvark"),
            ("beacon; BEACON.", "beacon; BEACON.", "Cedar; Cedar."),
        ]

        for includeTargets in [true, false] {
            vocabulary.setIncludeReplacementTargetsInRecognitionHints(includeTargets)
            for (input, raw, expected) in fixtures {
                let result = await processor.process(rawText: input)
                XCTAssertEqual(result.status, .none)
                XCTAssertEqual(result.rawText, raw)
                XCTAssertEqual(result.finalText, expected)
            }
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("correction-ownership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeVocabulary(in directory: URL) -> VocabularyManager {
        let vocabulary = VocabularyManager(fileURL: directory.appendingPathComponent("vocabulary.json"))
        vocabulary.addReplacement(from: "a", to: "Beacon")
        vocabulary.addReplacement(from: "Beacon", to: "Cedar")
        return vocabulary
    }
}

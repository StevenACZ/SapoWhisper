//
//  AppleSpeechFixtureBenchTests.swift
//  SapoWhisperTests
//
//  Report-only bench of AppleSpeechTranscriber against the es/en code-switch
//  fixture. It asserts only "produced a non-empty transcript"; the similarity
//  and timing numbers are attached and written to NSTemporaryDirectory()/
//  sapo-bench/ for the vocabulary benchmark script to judge.
//
//  Hermetic by default: locales whose assets are not installed are skipped
//  unless SAPO_BENCH=1, which downloads them in-test.
//

import Speech
import XCTest

@testable import SapoWhisper

@MainActor
final class AppleSpeechFixtureBenchTests: XCTestCase {

    private static let fixtureAudioSeconds = 130.667

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SapoWhisperTests/
            .deletingLastPathComponent()  // repo root
    }

    private static var fixtureDirectory: URL {
        repoRoot
            .appendingPathComponent("TestAssets")
            .appendingPathComponent("LocalAITranscription")
            .appendingPathComponent("technical")
            .appendingPathComponent("es")
    }

    private static var fixtureAudioURL: URL {
        fixtureDirectory.appendingPathComponent("synthetic-public.wav")
    }

    private static var referenceTextURL: URL {
        fixtureDirectory.appendingPathComponent("synthetic-public.txt")
    }

    func testAppleSpeechBenchSpanishSpain() async throws {
        try await runBench(localeIdentifier: "es_ES")
    }

    func testAppleSpeechBenchSpanishMexico() async throws {
        try await runBench(localeIdentifier: "es_MX")
    }

    func testAppleSpeechBenchSpanishUSA() async throws {
        try await runBench(localeIdentifier: "es_US")
    }

    // MARK: - Bench body

    private func runBench(localeIdentifier: String) async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26")
        }
        try await runBenchOnSupportedOS(localeIdentifier: localeIdentifier)
    }

    @available(macOS 26.0, *)
    private func runBenchOnSupportedOS(localeIdentifier: String) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw XCTSkip("SpeechTranscriber is not available on this machine")
        }
        guard
            let resolved = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: localeIdentifier))
        else {
            throw XCTSkip("Locale \(localeIdentifier) is not supported by SpeechTranscriber")
        }

        let engine = AppleSpeechTranscriber()
        await engine.refreshAssetState(locale: resolved)
        if !engine.isConfigured {
            guard ProcessInfo.processInfo.environment["SAPO_BENCH"] == "1" else {
                throw XCTSkip(
                    "Apple Speech assets not installed for \(localeIdentifier); run with SAPO_BENCH=1 to download in-test"
                )
            }
            await engine.downloadAssets(locale: resolved)
            guard engine.isConfigured else {
                XCTFail("Asset download failed for \(localeIdentifier): \(engine.assetState)")
                return
            }
        }

        let audioURL = Self.fixtureAudioURL
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: audioURL.path),
            "Fixture missing at \(audioURL.path)"
        )
        let reference = try String(contentsOf: Self.referenceTextURL, encoding: .utf8)

        let start = Date()
        let transcript = try await engine.transcribe(audioURL: audioURL, localeIdentifier: localeIdentifier)
        let wallSeconds = Date().timeIntervalSince(start)

        XCTAssertFalse(transcript.isEmpty, "Apple Speech returned an empty transcript for \(localeIdentifier)")

        let similarity = Self.tokenF1(candidate: transcript, reference: reference)
        let realTimeFactor = String(format: "%.3f", wallSeconds / Self.fixtureAudioSeconds)
        let report = """
            locale=\(localeIdentifier) resolved=\(resolved.identifier(.bcp47))
            wallSeconds=\(String(format: "%.2f", wallSeconds)) audioSeconds=\(Self.fixtureAudioSeconds) rtf=\(realTimeFactor)
            tokenF1=\(String(format: "%.4f", similarity))
            ---
            \(transcript)
            """
        let attachment = XCTAttachment(string: report)
        attachment.name = "apple-speech-\(localeIdentifier)"
        attachment.lifetime = .keepAlways
        add(attachment)
        print(report)

        try Self.writeBenchTranscript(transcript, localeIdentifier: localeIdentifier)
    }

    // MARK: - Metrics & output

    /// Transcript copy for scripts/stt_benchmark_vocabulary.py.
    private static func writeBenchTranscript(_ transcript: String, localeIdentifier: String) throws {
        let benchDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sapo-bench")
        try FileManager.default.createDirectory(at: benchDirectory, withIntermediateDirectories: true)
        let outputURL = benchDirectory.appendingPathComponent("apple-speech-\(localeIdentifier).txt")
        try transcript.write(to: outputURL, atomically: true, encoding: .utf8)
        print("bench transcript written to \(outputURL.path)")
    }

    /// Deterministic token-level F1: lowercase, punctuation stripped, multiset
    /// overlap of tokens (order-insensitive, duplicates counted).
    private static func tokenF1(candidate: String, reference: String) -> Double {
        let candidateTokens = normalizedTokens(candidate)
        let referenceTokens = normalizedTokens(reference)
        guard !candidateTokens.isEmpty, !referenceTokens.isEmpty else { return 0 }

        var remaining: [String: Int] = [:]
        for token in referenceTokens {
            remaining[token, default: 0] += 1
        }
        var overlap = 0
        for token in candidateTokens {
            if let count = remaining[token], count > 0 {
                remaining[token] = count - 1
                overlap += 1
            }
        }

        let precision = Double(overlap) / Double(candidateTokens.count)
        let recall = Double(overlap) / Double(referenceTokens.count)
        guard precision + recall > 0 else { return 0 }
        return 2 * precision * recall / (precision + recall)
    }

    private static func normalizedTokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

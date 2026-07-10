//
//  AppleSpeechTranscriber.swift
//  SapoWhisperTests
//
//  On-device transcription through Apple's SpeechAnalyzer/SpeechTranscriber
//  stack (macOS 26+). Lives in the TEST target as the es/en code-switch gate
//  harness: the 2026-07-09 fixture run scored weighted 44.8 vs MLX turbo's
//  88.2 (git/file/brand terms mangled; SpeechTranscriber accepts no
//  contextual vocabulary per Apple DTS), so the engine is NOT wired into the
//  app. Re-run AppleSpeechFixtureBenchTests with SAPO_BENCH=1 on new macOS
//  releases; promote this file back to the app target if the gate ever passes.
//

import AVFoundation
import Foundation
import Speech
import os

@testable import SapoWhisper

/// Owns the Apple Speech asset lifecycle for one locale at a time and runs
/// file transcriptions through `SpeechAnalyzer`. Awaits on the main actor are
/// suspensions — the recognition work runs inside the OS speech service.
@available(macOS 26.0, *)
@MainActor
@Observable
final class AppleSpeechTranscriber {

    nonisolated private static let engineName = "Apple Speech"

    /// On-device model assets for the active locale.
    enum AssetState: Equatable {
        case unknown
        case notInstalled
        case downloading(Double)
        case installed
        case failed(String)
    }

    var assetState: AssetState = .unknown
    var isTranscribing = false

    var isConfigured: Bool { assetState == .installed }

    // MARK: - Asset lifecycle

    /// Re-reads whether the on-device assets for `locale` are installed.
    func refreshAssetState(locale: Locale) async {
        guard SpeechTranscriber.isAvailable else {
            assetState = .failed("speech transcriber unavailable")
            return
        }
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            assetState = .notInstalled
            return
        }
        assetState = await Self.isLocaleInstalled(resolved) ? .installed : .notInstalled
    }

    /// Downloads and installs the on-device assets for `locale`, publishing
    /// progress through `assetState`. Failures land in `.failed` — the caller
    /// reads the state instead of catching.
    func downloadAssets(locale: Locale) async {
        if case .downloading = assetState { return }

        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            assetState = .failed("locale unsupported id=\(locale.identifier)")
            return
        }
        if await Self.isLocaleInstalled(resolved) {
            assetState = .installed
            return
        }

        SapoLog.settings.info(
            "Apple Speech asset download started locale=\(resolved.identifier(.bcp47), privacy: .public)"
        )
        assetState = .downloading(0)
        do {
            // Reservation pins the locale's assets so the system never evicts
            // them out from under the app.
            try await AssetInventory.reserve(locale: resolved)
            let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let progress = request.progress
                let poll = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard let self, case .downloading = self.assetState else { return }
                        self.assetState = .downloading(progress.fractionCompleted)
                    }
                }
                defer { poll.cancel() }
                try await request.downloadAndInstall()
            }
            assetState = .installed
            SapoLog.settings.info(
                "Apple Speech asset download complete locale=\(resolved.identifier(.bcp47), privacy: .public)"
            )
        } catch {
            let message = error.localizedDescription
            assetState = .failed(message)
            SapoLog.settings.error(
                "Apple Speech asset download failed locale=\(resolved.identifier(.bcp47), privacy: .public) error=\(message, privacy: .public)"
            )
        }
    }

    /// Locales `SpeechTranscriber` can transcribe on this OS, as BCP-47 ids.
    static func supportedLocaleIDs() async -> [String] {
        let locales = await SpeechTranscriber.supportedLocales
        return locales.map { $0.identifier(.bcp47) }.sorted()
    }

    private static func isLocaleInstalled(_ locale: Locale) async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        let target = locale.identifier(.bcp47)
        return installed.contains { $0.identifier(.bcp47) == target }
    }

    // MARK: - Transcription

    /// Transcribes an audio file with the on-device model for the given
    /// locale. The locale is a parameter (no stored settings in phase 1).
    func transcribe(audioURL: URL, localeIdentifier: String) async throws -> String {
        guard !isTranscribing else {
            throw TranscriptionFailure(
                kind: .unknown, engine: Self.engineName,
                technicalDetail: "transcription already in progress")
        }

        try AudioFileValidator.validate(audioURL)

        guard
            let resolvedLocale = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: localeIdentifier))
        else {
            throw TranscriptionFailure(
                kind: .notConfigured, engine: Self.engineName,
                technicalDetail: "locale unsupported id=\(localeIdentifier)")
        }
        guard await Self.isLocaleInstalled(resolvedLocale) else {
            throw TranscriptionFailure(
                kind: .notConfigured, engine: Self.engineName,
                technicalDetail: "assets not installed locale=\(resolvedLocale.identifier(.bcp47))")
        }

        isTranscribing = true
        defer { isTranscribing = false }

        SapoLog.recording.info(
            "Apple Speech transcription started file=\(audioURL.lastPathComponent, privacy: .public) locale=\(resolvedLocale.identifier(.bcp47), privacy: .public)"
        )
        let start = Date()

        let transcriber = SpeechTranscriber(locale: resolvedLocale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        do {
            let raw = try await withTaskCancellationHandler {
                let file = try AVAudioFile(forReading: audioURL)
                // The results consumer starts BEFORE analysis so no result is
                // ever emitted without a listener.
                async let collected = Self.collect(transcriber.results)
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                return try await collected
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }

            let transcript = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                throw TranscriptionFailure(kind: .emptyTranscription, engine: Self.engineName)
            }
            let elapsed = Date().timeIntervalSince(start)
            SapoLog.recording.info(
                "Apple Speech transcription complete chars=\(transcript.count, privacy: .public) seconds=\(String(format: "%.2f", elapsed), privacy: .public)"
            )
            return transcript
        } catch is CancellationError {
            SapoLog.recording.info("Apple Speech transcription cancelled")
            throw CancellationError()
        } catch let failure as TranscriptionFailure {
            SapoLog.recording.error(
                "Apple Speech transcription failed \(failure.logSummary, privacy: .public)"
            )
            throw failure
        } catch {
            let nsError = error as NSError
            let failure: TranscriptionFailure
            if nsError.domain == "SFSpeechErrorDomain" {
                failure = TranscriptionFailure(
                    kind: .unknown, engine: Self.engineName,
                    technicalDetail: "SFSpeechError code=\(nsError.code)")
            } else {
                failure = TranscriptionFailure.from(error, engine: Self.engineName)
            }
            SapoLog.recording.error(
                "Apple Speech transcription failed \(failure.logSummary, privacy: .public)"
            )
            throw failure
        }
    }

    /// Accumulates the finalized result segments into one transcript.
    private static func collect<Results: AsyncSequence>(
        _ results: Results
    ) async throws -> String where Results.Element == SpeechTranscriber.Result {
        var transcript = AttributedString("")
        for try await result in results where result.isFinal {
            transcript += result.text
        }
        return String(transcript.characters)
    }
}

// MARK: - TranscriptionEngineSession

@available(macOS 26.0, *)
extension AppleSpeechTranscriber: TranscriptionEngineSession {
    var isReady: Bool { isConfigured }
    var isBusy: Bool { isTranscribing }
}

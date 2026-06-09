//
//  DeepgramBatchTranscriber.swift
//  SapoWhisper
//

import AVFoundation
import Combine
import Foundation
import os

/// Batch transcription via Deepgram Nova-3 REST API
class DeepgramBatchTranscriber: ObservableObject {

    @Published var isTranscribing: Bool = false

    /// Brand name surfaced in user-facing failures and logs.
    private static let engineName = "Deepgram"

    /// Check if Deepgram API key is configured
    var isConfigured: Bool {
        let key = UserDefaults.standard.string(forKey: Constants.StorageKeys.deepgramAPIKey) ?? ""
        return !key.isEmpty
    }

    // MARK: - Transcription

    /// Transcribe audio file using Deepgram REST API (pre-recorded)
    func transcribe(audioURL: URL, language: String) async throws -> String {
        guard let apiKey = UserDefaults.standard.string(forKey: Constants.StorageKeys.deepgramAPIKey),
            !apiKey.isEmpty
        else {
            throw TranscriptionFailure(kind: .notConfigured, engine: Self.engineName)
        }

        await MainActor.run { isTranscribing = true }
        defer { Task { @MainActor in isTranscribing = false } }

        // Compress audio for faster upload (int16 ~2x smaller than float32)
        let (audioData, contentType) = compressAudio(from: audioURL)

        // Build URL with query parameters
        // Note: smart_format already includes punctuation, no need for separate punctuate=true
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "language", value: deepgramLanguageCode(for: language)),
            URLQueryItem(name: "smart_format", value: "true"),
        ]

        // Add vocabulary
        queryItems.append(contentsOf: VocabularyManager.shared.keytermQueryItems())
        queryItems.append(contentsOf: VocabularyManager.shared.replaceQueryItems())

        components.queryItems = queryItems

        guard let url = components.url else {
            throw TranscriptionFailure(
                kind: .unknown, engine: Self.engineName, technicalDetail: "invalid endpoint URL")
        }

        // Build request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Scale the timeout to the clip length so long recordings are not aborted early.
        request.timeoutInterval = TranscriptionFailure.requestTimeout(forAudioBytes: audioData.count)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = audioData

        // Send request, retrying transient 5xx responses once or twice.
        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            (data, httpResponse) = try await TransientRequestRetry.data(for: request, engine: Self.engineName)
        } catch {
            throw TranscriptionFailure.from(error, engine: Self.engineName)
        }

        guard httpResponse.statusCode == 200 else {
            let failure = TranscriptionFailure.fromHTTP(
                engine: Self.engineName, statusCode: httpResponse.statusCode, body: data)
            SapoLog.recording.error(
                "Deepgram batch HTTP failure \(failure.logSummary, privacy: .public)")
            throw failure
        }

        // Parse response. A 200 without parsable transcript means "nothing was
        // recognized", which must surface as emptyTranscription (not retryable),
        // matching every other engine.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = json["results"] as? [String: Any],
            let channels = results["channels"] as? [[String: Any]],
            let firstChannel = channels.first,
            let alternatives = firstChannel["alternatives"] as? [[String: Any]],
            let transcript = alternatives.first?["transcript"] as? String
        else {
            SapoLog.recording.warning(
                "Deepgram batch parse failure status=\(httpResponse.statusCode, privacy: .public) audioBytes=\(audioData.count, privacy: .public)"
            )
            throw TranscriptionFailure(
                kind: .emptyTranscription, engine: Self.engineName,
                technicalDetail: "could not parse 200 response bytes=\(data.count)")
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranscriptionFailure(
                kind: .emptyTranscription, engine: Self.engineName,
                technicalDetail: "empty transcript in 200 response")
        }
        return trimmed
    }

    // MARK: - Audio Compression

    /// Convert WAV float32 to int16 WAV for faster upload (~2x smaller)
    /// while staying in memory to avoid extra disk I/O before the request.
    private func compressAudio(from wavURL: URL) -> (Data, String) {
        do {
            let sourceFile = try AVAudioFile(forReading: wavURL)
            let fileFormat = sourceFile.fileFormat

            // Fast path: if the source is already int16 WAV on disk, send as-is.
            if fileFormat.commonFormat == .pcmFormatInt16 {
                let passthroughData = try Data(contentsOf: wavURL)
                return (passthroughData, "audio/wav")
            }

            let int16File = try AVAudioFile(forReading: wavURL, commonFormat: .pcmFormatInt16, interleaved: false)
            let format = int16File.processingFormat
            let channelCount = Int(format.channelCount)
            let sampleRate = UInt32(format.sampleRate)
            let frameCapacity: AVAudioFrameCount = 4096
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
                throw TranscriptionFailure(
                    kind: .audioCorrupt, engine: Self.engineName,
                    technicalDetail: "failed to create audio buffer")
            }

            let estimatedPCMBytes = max(0, Int(int16File.length)) * channelCount * 2
            var pcm16Data = Data()
            pcm16Data.reserveCapacity(estimatedPCMBytes)

            while int16File.framePosition < int16File.length {
                try int16File.read(into: buffer)
                guard let channels = buffer.int16ChannelData else {
                    throw TranscriptionFailure(
                        kind: .audioCorrupt, engine: Self.engineName,
                        technicalDetail: "failed to access int16 channel data")
                }

                let frameLength = Int(buffer.frameLength)
                for frame in 0..<frameLength {
                    for channel in 0..<channelCount {
                        var int16 = channels[channel][frame].littleEndian
                        withUnsafeBytes(of: &int16) { bytes in
                            pcm16Data.append(contentsOf: bytes)
                        }
                    }
                }
            }

            let wavData = makePCM16WAVData(
                pcm16Data: pcm16Data,
                sampleRate: sampleRate,
                channelCount: UInt16(channelCount)
            )
            return (wavData, "audio/wav")
        } catch {
            SapoLog.recording.warning(
                "Deepgram batch compression fallback error=\(error.localizedDescription, privacy: .public)"
            )
            let data = (try? Data(contentsOf: wavURL)) ?? Data()
            return (data, "audio/wav")
        }
    }

    private func makePCM16WAVData(pcm16Data: Data, sampleRate: UInt32, channelCount: UInt16) -> Data {
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let blockAlign = channelCount * (bitsPerSample / 8)
        let dataChunkSize = UInt32(pcm16Data.count)
        let riffChunkSize = 36 + dataChunkSize

        var wav = Data()
        wav.reserveCapacity(Int(44 + dataChunkSize))

        wav.append("RIFF".data(using: .ascii)!)
        appendLE(riffChunkSize, to: &wav)
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        appendLE(UInt32(16), to: &wav)  // PCM fmt chunk size
        appendLE(UInt16(1), to: &wav)  // PCM format
        appendLE(channelCount, to: &wav)
        appendLE(sampleRate, to: &wav)
        appendLE(byteRate, to: &wav)
        appendLE(blockAlign, to: &wav)
        appendLE(bitsPerSample, to: &wav)
        wav.append("data".data(using: .ascii)!)
        appendLE(dataChunkSize, to: &wav)
        wav.append(pcm16Data)

        return wav
    }

    private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    // MARK: - Language Mapping

    private func deepgramLanguageCode(for appLanguage: String) -> String {
        TranscriptionLanguageCatalog.deepgramLanguageCode(for: appLanguage)
    }
}

//
//  DeepgramStreamingTranscriber.swift
//  SapoWhisper
//

import AVFoundation
import Combine
import Foundation

/// Batch transcription via Deepgram Nova-3 REST API
class DeepgramStreamingTranscriber: ObservableObject {

    @Published var isTranscribing: Bool = false

    /// Check if Deepgram API key is configured
    var isConfigured: Bool {
        let key = UserDefaults.standard.string(forKey: Constants.StorageKeys.deepgramAPIKey) ?? ""
        return !key.isEmpty
    }

    // MARK: - Transcription

    /// Transcribe audio file using Deepgram REST API (pre-recorded)
    func transcribe(audioURL: URL, language: String) async throws -> String {
        guard let apiKey = UserDefaults.standard.string(forKey: Constants.StorageKeys.deepgramAPIKey),
              !apiKey.isEmpty else {
            throw DeepgramError.notConfigured
        }

        await MainActor.run { isTranscribing = true }
        defer { Task { @MainActor in isTranscribing = false } }

        let transcribeStart = CFAbsoluteTimeGetCurrent()

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
            throw DeepgramError.invalidURL
        }

        // Build request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = audioData

        print("⏱️ [request] sending \(audioData.count) bytes (\(deepgramLanguageCode(for: language)))")
        let apiStart = CFAbsoluteTimeGetCurrent()

        // Send request
        let (data, response) = try await URLSession.shared.data(for: request)
        let apiElapsed = (CFAbsoluteTimeGetCurrent() - apiStart) * 1000
        print("⏱️ [request] API responded in \(String(format: "%.0f", apiElapsed))ms")

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepgramError.apiError("Invalid response")
        }

        // Handle HTTP errors
        switch httpResponse.statusCode {
        case 200:
            break
        case 401, 403:
            throw DeepgramError.invalidAPIKey
        case 429:
            throw DeepgramError.quotaExceeded
        default:
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw DeepgramError.apiError("HTTP \(httpResponse.statusCode): \(body)")
        }

        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any],
              let channels = results["channels"] as? [[String: Any]],
              let firstChannel = channels.first,
              let alternatives = firstChannel["alternatives"] as? [[String: Any]],
              let transcript = alternatives.first?["transcript"] as? String else {
            throw DeepgramError.apiError("Could not parse response")
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let totalElapsed = (CFAbsoluteTimeGetCurrent() - transcribeStart) * 1000
        print("⏱️ [total] transcription complete in \(String(format: "%.0f", totalElapsed))ms (\(trimmed.count) chars)")
        return trimmed
    }

    // MARK: - Audio Compression

    /// Convert WAV float32 to int16 WAV for faster upload (~2x smaller)
    /// while staying in memory to avoid extra disk I/O before the request.
    private func compressAudio(from wavURL: URL) -> (Data, String) {
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let sourceFile = try AVAudioFile(forReading: wavURL)
            let format = sourceFile.processingFormat

            // Fast path: if the source is already int16 WAV, send as-is.
            if format.commonFormat == .pcmFormatInt16 {
                let passthroughData = try Data(contentsOf: wavURL)
                let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                print("⏱️ [compress] passthrough int16 WAV (\(passthroughData.count) bytes, \(String(format: "%.0f", elapsed))ms)")
                return (passthroughData, "audio/wav")
            }

            let channelCount = Int(format.channelCount)
            let sampleRate = UInt32(format.sampleRate)
            let frameCapacity: AVAudioFrameCount = 4096
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
                throw DeepgramError.apiError("Failed to create audio buffer")
            }

            let estimatedPCMBytes = max(0, Int(sourceFile.length)) * channelCount * 2
            var pcm16Data = Data()
            pcm16Data.reserveCapacity(estimatedPCMBytes)

            while sourceFile.framePosition < sourceFile.length {
                try sourceFile.read(into: buffer)
                guard let channels = buffer.floatChannelData else {
                    throw DeepgramError.apiError("Failed to access float channel data")
                }

                let frameLength = Int(buffer.frameLength)
                for frame in 0..<frameLength {
                    for channel in 0..<channelCount {
                        let sample = max(-1.0, min(1.0, channels[channel][frame]))
                        var int16 = Int16(sample * 32767.0).littleEndian
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
            let originalSize = (try? FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? NSNumber)?.intValue ?? 0
            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            print("⏱️ [compress] \(originalSize) → \(wavData.count) bytes (int16 in-memory, \(String(format: "%.0f", elapsed))ms)")
            return (wavData, "audio/wav")
        } catch {
            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            print("⏱️ [compress] failed (\(error)), sending raw WAV (\(String(format: "%.0f", elapsed))ms)")
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
        appendLE(UInt32(16), to: &wav) // PCM fmt chunk size
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
        switch appLanguage {
        case "es": return "es"
        case "en": return "en"
        case "auto": return "multi"
        default: return "es"
        }
    }
}

// MARK: - Errors

enum DeepgramError: LocalizedError {
    case notConfigured
    case invalidURL
    case invalidAPIKey
    case quotaExceeded
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Deepgram API key not configured"
        case .invalidURL:
            return "Invalid Deepgram URL"
        case .invalidAPIKey:
            return "error.deepgram_auth".localized
        case .quotaExceeded:
            return "Deepgram: Quota exceeded"
        case .apiError(let message):
            return "Deepgram: \(message)"
        }
    }
}

//
//  TranscriptionFailure.swift
//  SapoWhisper
//

import AVFoundation
import Foundation

/// Unified, semantic failure model shared by every transcription engine.
///
/// Each engine maps its raw failure (HTTP status, `URLError`, decode error, ...)
/// into one of these so the UI can show an honest, localized message and decide
/// whether a retry makes sense, while the logs keep the technical detail.
struct TranscriptionFailure: LocalizedError, Equatable {

    /// Semantic failure category, independent of which engine produced it.
    enum Kind: String, Equatable {
        case notConfigured = "not_configured"
        case auth
        case outOfCredits = "out_of_credits"
        case rateLimited = "rate_limited"
        case planRestricted = "plan_restricted"
        case serverError = "server_error"
        case network
        case timedOut = "timed_out"
        case audioEmpty = "audio_empty"
        case audioCorrupt = "audio_corrupt"
        case recordingInterrupted = "recording_interrupted"
        case emptyTranscription = "empty_transcription"
        case unknown
    }

    let kind: Kind
    /// Engine brand shown to the user, e.g. `"ElevenLabs"`. `nil` for engine-agnostic failures.
    let engine: String?
    /// HTTP status, response body snippet, error code — logged, never shown to the user.
    let technicalDetail: String?
    /// Pre-localized message that wins over `kind`'s default text. Used to preserve the
    /// specific wording of engine-domain errors (model not loaded, permission denied, ...).
    let messageOverride: String?

    init(
        kind: Kind,
        engine: String? = nil,
        technicalDetail: String? = nil,
        messageOverride: String? = nil
    ) {
        self.kind = kind
        self.engine = engine
        self.technicalDetail = technicalDetail
        self.messageOverride = messageOverride
    }

    // MARK: - User-facing text

    var errorDescription: String? {
        if let messageOverride, !messageOverride.isEmpty {
            return messageOverride
        }
        let engineName = engine ?? "failure.generic_engine".localized
        switch kind {
        case .notConfigured:
            return "failure.not_configured".localized(engineName)
        case .auth:
            return "failure.auth".localized(engineName)
        case .outOfCredits:
            return "failure.out_of_credits".localized(engineName)
        case .rateLimited:
            return "failure.rate_limited".localized(engineName)
        case .planRestricted:
            return "failure.plan_restricted".localized(engineName)
        case .serverError:
            return "failure.server_error".localized(engineName)
        case .network:
            return "failure.network".localized
        case .timedOut:
            return "failure.timed_out".localized
        case .audioEmpty:
            return "failure.audio_empty".localized
        case .audioCorrupt:
            return "failure.audio_corrupt".localized
        case .recordingInterrupted:
            return "failure.recording_interrupted".localized
        case .emptyTranscription:
            return "failure.empty_transcription".localized
        case .unknown:
            return "failure.unknown".localized(engineName)
        }
    }

    /// Whether offering the user a "Retry" affordance makes sense for this failure.
    var isRetryable: Bool {
        switch kind {
        case .rateLimited, .serverError, .network, .timedOut, .recordingInterrupted, .unknown:
            return true
        case .notConfigured, .auth, .outOfCredits, .planRestricted,
            .audioEmpty, .audioCorrupt, .emptyTranscription:
            return false
        }
    }

    /// Compact, log-friendly identifier, e.g. `ElevenLabs/auth`.
    var diagnosticCode: String {
        "\(engine ?? "?")/\(kind.rawValue)"
    }

    /// Single log line carrying the code plus technical detail. Safe for unified logging.
    var logSummary: String {
        if let technicalDetail, !technicalDetail.isEmpty {
            return "\(diagnosticCode) detail=\(technicalDetail)"
        }
        return diagnosticCode
    }
}

// MARK: - Factories

extension TranscriptionFailure {

    /// Classifies a non-2xx HTTP response, capturing a trimmed body snippet for logs.
    ///
    /// The body is only used for keyword hints (e.g. "quota" vs "api key") and a short
    /// log snippet — it is never shown to the user.
    static func fromHTTP(engine: String, statusCode: Int, body: Data) -> TranscriptionFailure {
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        let lower = bodyText.lowercased()
        let snippet =
            bodyText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(300)
        let detail = "HTTP \(statusCode) body=\(snippet)"

        let mentionsCredits =
            lower.contains("quota") || lower.contains("credit")
            || lower.contains("insufficient") || lower.contains("balance")
            || lower.contains("out of") || lower.contains("usage limit")
        let mentionsRate =
            lower.contains("rate limit") || lower.contains("rate_limit")
            || lower.contains("too many requests") || lower.contains("concurrent")
        let mentionsKey =
            lower.contains("api key") || lower.contains("api_key")
            || lower.contains("invalid_api_key") || lower.contains("unauthorized")
            || lower.contains("authentication")

        let kind: Kind
        switch statusCode {
        case 401:
            kind = mentionsCredits ? .outOfCredits : .auth
        case 402:
            kind = .outOfCredits
        case 403:
            if mentionsKey {
                kind = .auth
            } else if mentionsCredits {
                kind = .outOfCredits
            } else {
                kind = .planRestricted
            }
        case 429:
            kind = mentionsCredits && !mentionsRate ? .outOfCredits : .rateLimited
        case 408, 504:
            kind = .timedOut
        case 500...599:
            kind = .serverError
        default:
            kind = .unknown
        }
        return TranscriptionFailure(kind: kind, engine: engine, technicalDetail: detail)
    }

    /// Normalizes any caught error into a `TranscriptionFailure`.
    ///
    /// Recognizes failures already of this type, `URLError`, the engine-domain error
    /// enums, and Apple Speech `NSError`s; everything else becomes `.unknown`.
    static func from(_ error: Error, engine: String? = nil) -> TranscriptionFailure {
        if let failure = error as? TranscriptionFailure {
            return failure
        }
        if let urlError = error as? URLError {
            return fromURLError(urlError, engine: engine)
        }
        if let vertexError = error as? VertexGenerateContentError {
            return fromVertex(vertexError, engine: engine ?? "Gemini")
        }
        if let recordingError = error as? RecordingError {
            return fromRecording(recordingError, engine: engine)
        }
        if let transcriberError = error as? TranscriberError {
            switch transcriberError {
            case .permissionDenied, .modelNotDownloaded, .modelNotLoaded:
                return TranscriptionFailure(
                    kind: .notConfigured, engine: engine,
                    technicalDetail: "TranscriberError.\(transcriberError)",
                    messageOverride: transcriberError.errorDescription)
            case .transcriptionFailed:
                return TranscriptionFailure(
                    kind: .unknown, engine: engine,
                    technicalDetail: "TranscriberError.transcriptionFailed",
                    messageOverride: transcriberError.errorDescription)
            }
        }
        if let whisperKitError = error as? WhisperKitError {
            switch whisperKitError {
            case .notAvailable, .modelNotLoaded:
                return TranscriptionFailure(
                    kind: .notConfigured, engine: engine,
                    technicalDetail: "WhisperKitError.\(whisperKitError)",
                    messageOverride: whisperKitError.errorDescription)
            case .modelLoadFailed, .transcriptionFailed:
                return TranscriptionFailure(
                    kind: .unknown, engine: engine,
                    technicalDetail: "WhisperKitError",
                    messageOverride: whisperKitError.errorDescription)
            }
        }

        let nsError = error as NSError
        // Apple Speech surfaces failures under kAFAssistantErrorDomain; 1110 = no speech.
        if nsError.domain == "kAFAssistantErrorDomain" {
            let kind: Kind = nsError.code == 1110 ? .emptyTranscription : .unknown
            return TranscriptionFailure(
                kind: kind, engine: engine,
                technicalDetail: "kAFAssistantErrorDomain/\(nsError.code)")
        }

        return TranscriptionFailure(
            kind: .unknown, engine: engine,
            technicalDetail: "\(nsError.domain)/\(nsError.code) \(error.localizedDescription)")
    }

    private static func fromURLError(_ urlError: URLError, engine: String?) -> TranscriptionFailure {
        switch urlError.code {
        case .timedOut:
            return TranscriptionFailure(
                kind: .timedOut, engine: engine, technicalDetail: "URLError.timedOut")
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
            .secureConnectionFailed, .resourceUnavailable:
            return TranscriptionFailure(
                kind: .network, engine: engine,
                technicalDetail: "URLError.\(urlError.code.rawValue)")
        default:
            return TranscriptionFailure(
                kind: .unknown, engine: engine,
                technicalDetail: "URLError.\(urlError.code.rawValue)")
        }
    }

    private static func fromVertex(
        _ error: VertexGenerateContentError, engine: String
    ) -> TranscriptionFailure {
        switch error {
        case .notConfigured:
            return TranscriptionFailure(kind: .notConfigured, engine: engine)
        case .invalidURL:
            return TranscriptionFailure(
                kind: .unknown, engine: engine,
                technicalDetail: "VertexGenerateContentError.invalidURL")
        case .emptyResponse:
            return TranscriptionFailure(kind: .emptyTranscription, engine: engine)
        case .httpError(let statusCode, let message):
            return fromHTTP(engine: engine, statusCode: statusCode, body: Data(message.utf8))
        }
    }

    private static func fromRecording(
        _ error: RecordingError, engine: String?
    ) -> TranscriptionFailure {
        switch error {
        case .noInputAfterDeviceSwitch:
            return TranscriptionFailure(
                kind: .recordingInterrupted, engine: engine,
                technicalDetail: "RecordingError.noInputAfterDeviceSwitch")
        case .fileCreationFailed:
            return TranscriptionFailure(
                kind: .audioCorrupt, engine: engine,
                technicalDetail: "RecordingError.fileCreationFailed")
        default:
            return TranscriptionFailure(
                kind: .unknown, engine: engine,
                technicalDetail: "RecordingError.\(error)",
                messageOverride: error.errorDescription)
        }
    }
}

// MARK: - Request timeout

extension TranscriptionFailure {
    /// Request timeout, in seconds, scaled to the audio length so long recordings
    /// are not aborted early. A 30 s clip yields ~180 s; clamped to [120, 600].
    static func requestTimeout(forEstimatedSeconds estimatedSeconds: Double) -> TimeInterval {
        min(600, max(120, estimatedSeconds * 6))
    }

    /// Convenience overload from a raw 16 kHz mono int16 byte count (32 KB per second).
    static func requestTimeout(forAudioBytes byteCount: Int) -> TimeInterval {
        requestTimeout(forEstimatedSeconds: Double(byteCount) / 32_000.0)
    }
}

// MARK: - Audio file validation

/// Lightweight pre-flight check that a recorded WAV is usable before sending it to an engine.
enum AudioFileValidator {
    /// A canonical WAV header is 44 bytes; anything at or below that carries no samples.
    private static let minimumByteCount = 44

    /// Throws a `TranscriptionFailure` if the file is missing, empty, or unreadable.
    static func validate(_ url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw TranscriptionFailure(
                kind: .audioEmpty,
                technicalDetail: "file missing path=\(url.lastPathComponent)")
        }

        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let byteCount = (attributes?[.size] as? Int) ?? 0
        guard byteCount > minimumByteCount else {
            throw TranscriptionFailure(
                kind: .audioEmpty, technicalDetail: "file too small bytes=\(byteCount)")
        }

        do {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0 else {
                throw TranscriptionFailure(
                    kind: .audioEmpty,
                    technicalDetail: "decoded zero frames bytes=\(byteCount)")
            }
        } catch let failure as TranscriptionFailure {
            throw failure
        } catch {
            throw TranscriptionFailure(
                kind: .audioCorrupt,
                technicalDetail:
                    "AVAudioFile open failed bytes=\(byteCount) error=\(error.localizedDescription)")
        }
    }
}

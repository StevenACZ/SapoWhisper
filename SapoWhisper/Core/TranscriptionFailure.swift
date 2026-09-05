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
        /// Non-transient 4xx (bad request, unsupported media, not found): a
        /// retry with the same input fails identically, so it must not be one.
        case clientError = "client_error"
        case serverError = "server_error"
        case network
        case timedOut = "timed_out"
        case audioEmpty = "audio_empty"
        case audioCorrupt = "audio_corrupt"
        case audioStorageFailed = "audio_storage_failed"
        case audioPreparationFailed = "audio_preparation_failed"
        case recordingInterrupted = "recording_interrupted"
        case userCancelled = "user_cancelled"
        case emptyTranscription = "empty_transcription"
        case unknown
    }

    let kind: Kind
    /// Engine brand shown to the user, e.g. `"ElevenLabs"`. `nil` for engine-agnostic failures.
    let engine: String?
    /// Safe status, domain, or error code metadata logged but never shown to the user.
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
        case .clientError:
            return "failure.client_error".localized(engineName)
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
        case .audioStorageFailed:
            return "failure.audio_storage_failed".localized
        case .audioPreparationFailed:
            return "failure.audio_preparation_failed".localized
        case .recordingInterrupted:
            return "failure.recording_interrupted".localized
        case .userCancelled:
            return "failure.user_cancelled".localized
        case .emptyTranscription:
            return "failure.empty_transcription".localized
        case .unknown:
            return "failure.unknown".localized(engineName)
        }
    }

    /// Whether offering the user a "Retry" affordance makes sense for this failure.
    var isRetryable: Bool {
        switch kind {
        case .rateLimited, .serverError, .network, .timedOut, .recordingInterrupted, .audioStorageFailed,
            .audioPreparationFailed, .unknown:
            return true
        case .notConfigured, .auth, .outOfCredits, .planRestricted, .clientError,
            .audioEmpty, .audioCorrupt, .userCancelled, .emptyTranscription:
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

    nonisolated static func diagnosticDetail(for error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)/\(nsError.code)"
    }
}

// MARK: - Factories

extension TranscriptionFailure {

    /// Classifies a non-2xx HTTP response. The body is used only for classification.
    static func fromHTTP(engine: String, statusCode: Int, body: Data) -> TranscriptionFailure {
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        let lower = bodyText.lowercased()
        let detail = "HTTP status=\(statusCode)"

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
        case 400..<500:
            // Any other 4xx is a non-transient client error (bad request,
            // unsupported media, wrong endpoint, conflict, gone, ...): retrying the
            // same payload fails identically. 401/402/403/408/429 matched above.
            kind = .clientError
        default:
            kind = .unknown
        }
        return TranscriptionFailure(kind: kind, engine: engine, technicalDetail: detail)
    }

    /// Redacts secrets from an error-body snippet before it is logged or shown.
    /// Internal (not private) so OpenAI-compatible polish errors reuse the same
    /// patterns instead of logging a raw provider body.
    static func redactedLogSnippet(from bodyText: String) -> String {
        LogSanitizer.redactedSnippet(from: bodyText)
    }

    /// Normalizes any caught error into a `TranscriptionFailure`.
    ///
    /// Recognizes failures already of this type, `URLError`, and the
    /// engine-domain error enums; everything else becomes `.unknown`.
    static func from(_ error: Error, engine: String? = nil) -> TranscriptionFailure {
        if error is CancellationError {
            return TranscriptionFailure(kind: .userCancelled, engine: engine, technicalDetail: "CancellationError")
        }
        if let failure = error as? TranscriptionFailure {
            return failure
        }
        if let urlError = error as? URLError {
            return fromURLError(urlError, engine: engine)
        }
        if let recordingError = error as? RecordingError {
            return fromRecording(recordingError, engine: engine)
        }
        if let mlxError = error as? MLXWhisperError {
            switch mlxError {
            case .modelNotLoaded:
                return TranscriptionFailure(
                    kind: .notConfigured, engine: engine,
                    technicalDetail: "MLXWhisperError.modelNotLoaded",
                    messageOverride: mlxError.errorDescription)
            case .transcriptionInProgress:
                return TranscriptionFailure(
                    kind: .unknown, engine: engine,
                    technicalDetail: "MLXWhisperError.transcriptionInProgress",
                    messageOverride: mlxError.errorDescription)
            case .modelLoadFailed, .transcriptionFailed:
                return TranscriptionFailure(
                    kind: .unknown, engine: engine,
                    technicalDetail: "MLXWhisperError",
                    messageOverride: mlxError.errorDescription)
            }
        }

        return TranscriptionFailure(
            kind: .unknown, engine: engine,
            technicalDetail: diagnosticDetail(for: error))
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
        case .permissionDenied:
            // Not retryable: the user must grant mic access in System Settings,
            // so a Retry button would just fail again. Keep the specific message.
            return TranscriptionFailure(
                kind: .notConfigured, engine: engine,
                technicalDetail: "RecordingError.permissionDenied",
                messageOverride: error.errorDescription)
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
                    "AVAudioFile open failed bytes=\(byteCount) error=\(TranscriptionFailure.diagnosticDetail(for: error))"
            )
        }
    }
}

//
//  EngineKeyValidator.swift
//  SapoWhisper
//

import Foundation

enum EngineKeyValidationError: LocalizedError {
    case invalidKey
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "welcome.key_invalid".localized
        case .server(let statusCode):
            return "welcome.key_server_error".localized(String(statusCode))
        }
    }
}

/// Validates a cloud engine API key with a cheap authenticated request, so
/// the Welcome flow and settings can show ✓/✗ before any real dictation.
enum EngineKeyValidator {

    static func validate(engine: TranscriptionEngine, key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EngineKeyValidationError.invalidKey }

        switch engine {
        case .deepgram:
            try await probe(
                url: URL(string: "https://api.deepgram.com/v1/projects")!,
                headers: ["Authorization": "Token \(trimmed)"]
            )
        case .elevenLabsScribe:
            try await probe(
                url: URL(string: "https://api.elevenlabs.io/v1/user")!,
                headers: ["xi-api-key": trimmed]
            )
        case .whisperLocal, .localAIServer:
            return  // Local engines have no required key.
        }
    }

    private static func probe(url: URL, headers: [String: String]) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        switch http.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw EngineKeyValidationError.invalidKey
        default:
            throw EngineKeyValidationError.server(http.statusCode)
        }
    }
}

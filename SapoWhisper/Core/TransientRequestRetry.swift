//
//  TransientRequestRetry.swift
//  SapoWhisper
//

import Foundation
import os

/// Shared retry policy for idempotent cloud requests: up to two extra attempts
/// on transient 5xx responses with a short backoff. Non-retryable statuses are
/// returned to the caller for normal failure mapping.
enum TransientRequestRetry {
    static let retryableStatusCodes: Set<Int> = [500, 502, 503, 504]
    static let backoffs: [TimeInterval] = [1.0, 3.0]

    /// Performs `request`, retrying on retryable 5xx statuses. Network-level
    /// errors (`URLError`) are thrown unchanged so engines keep their mapping.
    static func data(
        for request: URLRequest,
        session: URLSession = .shared,
        engine: String
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            guard retryableStatusCodes.contains(http.statusCode), attempt < backoffs.count else {
                return (data, http)
            }

            let backoff = backoffs[attempt]
            attempt += 1
            SapoLog.recording.warning(
                "Transient server error engine=\(engine, privacy: .public) status=\(http.statusCode, privacy: .public) retry=\(attempt, privacy: .public)/\(backoffs.count, privacy: .public) backoffMs=\(Int(backoff * 1000), privacy: .public)"
            )
            try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
        }
    }
}

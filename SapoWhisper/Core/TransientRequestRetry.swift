//
//  TransientRequestRetry.swift
//  SapoWhisper
//

import Foundation
import os

/// Shared retry policy for idempotent cloud requests: up to two extra attempts
/// on transient 5xx responses or connectivity-flap URLErrors, with a short
/// backoff. Non-retryable statuses and every other network error are returned
/// to the caller for normal failure mapping.
enum TransientRequestRetry {
    static let retryableStatusCodes: Set<Int> = [500, 502, 503, 504]
    /// The network path flapped mid-request (Wi-Fi/Bluetooth coexistence
    /// blips, route transitions): the request never completed against the
    /// server, so retrying is safe and usually succeeds within a second.
    /// Engines that require internet fast-fail BEFORE the request when
    /// genuinely offline (R7), so hitting one of these here usually means a
    /// blip, not a dead link.
    static let retryableURLErrorCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost,
    ]
    static let backoffs: [TimeInterval] = [1.0, 3.0]

    /// Performs `request`, retrying on retryable 5xx statuses and transient
    /// connectivity URLErrors. Every other network-level error is thrown
    /// unchanged so engines keep their mapping.
    static func data(
        for request: URLRequest,
        session: URLSession = .shared,
        engine: String
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError
                where retryableURLErrorCodes.contains(error.code) && attempt < backoffs.count
            {
                let backoff = backoffs[attempt]
                attempt += 1
                SapoLog.recording.warning(
                    "Transient network error engine=\(engine, privacy: .public) code=\(error.code.rawValue, privacy: .public) retry=\(attempt, privacy: .public)/\(backoffs.count, privacy: .public) backoffMs=\(Int(backoff * 1000), privacy: .public)"
                )
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                continue
            }
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

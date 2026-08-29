//
//  ProviderURLSecurity.swift
//  SapoWhisper
//

import Foundation

nonisolated enum ProviderURLSecurity {
    static func validatedURL(from input: String, bearerToken: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil
        else {
            return nil
        }

        let hasBearerToken = !bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard scheme == "https" || !hasBearerToken || isLoopbackHost(host) else { return nil }
        return components.url
    }

    static func sanitizedForStorage(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return "" }
        guard components.user != nil || components.password != nil || components.query != nil || components.fragment != nil else {
            return trimmed
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func sanitizedValidURLString(_ input: String) -> String? {
        let sanitized = sanitizedForStorage(input)
        guard validatedURL(from: sanitized, bearerToken: "") != nil else { return nil }
        return sanitized
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
    }
}

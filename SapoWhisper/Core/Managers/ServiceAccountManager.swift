//
//  ServiceAccountManager.swift
//  SapoWhisper
//

import Foundation
import os

// MARK: - Service Account Manager

class ServiceAccountManager {
    static let shared = ServiceAccountManager()

    private var cachedToken: String?
    private var tokenExpiry: Date?
    private var credentials: ADCredentials?

    var isConfigured: Bool { credentials != nil }
    var projectID: String? { credentials?.projectID }
    var email: String? { credentials?.account }

    private init() {
        loadCredentials()
    }

    // MARK: - File Management

    /// Import a JSON credentials file (ADC or service account) — copies to App Support
    func importFile(from sourceURL: URL) throws {
        let data = try Data(contentsOf: sourceURL)
        let creds = try ADCredentials(data: data)
        try data.write(to: Self.storagePath(), options: .atomic)
        credentials = creds
        cachedToken = nil
        tokenExpiry = nil
        UserDefaults.standard.set(true, forKey: Constants.StorageKeys.serviceAccountConfigured)
        SapoLog.gemini.info("Credentials imported type=\(String(describing: creds.type), privacy: .public)")
    }

    /// Remove stored credentials
    func remove() {
        try? FileManager.default.removeItem(at: Self.storagePath())
        credentials = nil
        cachedToken = nil
        tokenExpiry = nil
        UserDefaults.standard.set(false, forKey: Constants.StorageKeys.serviceAccountConfigured)
        SapoLog.gemini.info("Credentials removed")
    }

    /// Reload credentials (e.g. after user runs gcloud auth)
    func reload() {
        loadCredentials()
    }

    // MARK: - Token Access

    func getValidAccessToken() async throws -> String {
        if let token = cachedToken, let expiry = tokenExpiry, Date() < expiry.addingTimeInterval(-60) {
            return token
        }
        guard let creds = credentials else { throw ServiceAccountError.notConfigured }
        return try await refreshToken(creds: creds)
    }

    // MARK: - Private

    private func loadCredentials() {
        // 1. Check imported file in App Support
        let storedPath = Self.storagePath()
        if let creds = try? ADCredentials(url: storedPath) {
            credentials = creds
            SapoLog.gemini.info(
                "Credentials loaded source=appSupport type=\(String(describing: creds.type), privacy: .public)"
            )
            return
        }

        // 2. Check default gcloud ADC path
        let adcPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/gcloud/application_default_credentials.json")
        if let creds = try? ADCredentials(url: adcPath) {
            credentials = creds
            SapoLog.gemini.info(
                "Credentials loaded source=gcloudADC type=\(String(describing: creds.type), privacy: .public)"
            )
            return
        }
    }

    private static func storagePath() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SapoWhisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("gcloud-credentials.json")
    }

    private func refreshToken(creds: ADCredentials) async throws -> String {
        var request = URLRequest(url: URL(string: GoogleCloudConfig.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id=\(creds.clientID)",
            "client_secret=\(creds.clientSecret)",
            "refresh_token=\(creds.refreshToken)",
            "grant_type=refresh_token",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown"
            throw ServiceAccountError.tokenError(msg)
        }

        let tokenResp = try JSONDecoder().decode(TokenResponse.self, from: data)
        cachedToken = tokenResp.accessToken
        tokenExpiry = Date().addingTimeInterval(TimeInterval(tokenResp.expiresIn))
        return tokenResp.accessToken
    }
}

// MARK: - Credentials Model

private struct ADCredentials {
    let type: String
    let clientID: String
    let clientSecret: String
    let refreshToken: String
    let projectID: String
    let account: String?

    init(data: Data) throws {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceAccountError.invalidFile("Invalid JSON")
        }

        guard let type = json["type"] as? String else {
            throw ServiceAccountError.invalidFile("Missing 'type' field")
        }

        guard type == "authorized_user" else {
            throw ServiceAccountError.invalidFile("Only 'authorized_user' type supported. Run: gcloud auth application-default login")
        }

        guard let clientID = json["client_id"] as? String,
            let clientSecret = json["client_secret"] as? String,
            let refreshToken = json["refresh_token"] as? String
        else {
            throw ServiceAccountError.invalidFile("Missing required fields")
        }

        guard let projectID = json["quota_project_id"] as? String, !projectID.isEmpty else {
            throw ServiceAccountError.invalidFile("Missing quota_project_id")
        }

        self.type = type
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.refreshToken = refreshToken
        self.projectID = projectID
        self.account = json["account"] as? String
    }

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        try self.init(data: data)
    }
}

// MARK: - Token Response

private struct TokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

// MARK: - Errors

enum ServiceAccountError: LocalizedError {
    case notConfigured
    case invalidFile(String)
    case tokenError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Google Cloud credentials not configured"
        case .invalidFile(let m): return "Invalid credentials: \(m)"
        case .tokenError(let m): return "Token error: \(m)"
        }
    }
}

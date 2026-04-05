//
//  GoogleCloudConstants.swift
//  SapoWhisper
//

import Foundation

enum GoogleCloudConfig {
    static let region = "us"
    static let scope = "https://www.googleapis.com/auth/cloud-platform"
    static let tokenURL = "https://oauth2.googleapis.com/token"

    /// Derives project ID from the service account JSON at runtime
    static func v2Endpoint(projectID: String) -> String {
        "https://\(region)-speech.googleapis.com/v2/projects/\(projectID)/locations/\(region)/recognizers/_:recognize"
    }
}

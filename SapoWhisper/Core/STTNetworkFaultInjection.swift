#if DEBUG
    import Foundation
    import os

    nonisolated final class STTNetworkFaultInjection: URLProtocol, @unchecked Sendable {
        private static let failures = Set(
            (ProcessInfo.processInfo.environment["SAPO_QA_FAIL_STT_NETWORK"] ?? "")
                .split(separator: ",").map(String.init)
        ).intersection(["local", "deepgram"])

        static func installIfRequested() {
            guard !failures.isEmpty, !UIPreviewMode.skipsConsentPrompts else { return }
            URLProtocol.registerClass(Self.self)
        }

        static func matches(_ url: URL?, failures: Set<String>, localHost: String?) -> Bool {
            guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                let host = url.host?.lowercased()
            else { return false }
            return (failures.contains("deepgram") && host == "api.deepgram.com")
                || (failures.contains("local") && host == localHost?.lowercased())
        }

        override class func canInit(with request: URLRequest) -> Bool {
            let configuredURL = AppPreferences.defaults.string(forKey: Constants.StorageKeys.localAIServerBaseURL)
            return matches(request.url, failures: failures, localHost: configuredURL.flatMap(URL.init(string:))?.host)
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            SapoLog.recording.notice("QA STT network failure injected")
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }

        override func stopLoading() {}
    }
#endif

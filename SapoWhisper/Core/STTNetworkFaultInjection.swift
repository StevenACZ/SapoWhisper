#if DEBUG
    import Foundation
    import os

    nonisolated final class STTNetworkFaultInjection: URLProtocol, @unchecked Sendable {
        private static let failures = Set(
            (ProcessInfo.processInfo.environment["SAPO_QA_FAIL_STT_NETWORK"] ?? "")
                .split(separator: ",").map(String.init)
        ).intersection(["local", "deepgram", "local-stall"])

        static func installIfRequested() {
            guard !failures.isEmpty, !UIPreviewMode.skipsConsentPrompts else { return }
            URLProtocol.registerClass(Self.self)
        }

        enum Mode: Equatable {
            case unreachable
            case stalled
        }

        private static var localHost: String? {
            AppPreferences.defaults.string(forKey: Constants.StorageKeys.localAIServerBaseURL)
                .flatMap(URL.init(string:))?.host
        }

        static func mode(_ url: URL?, failures: Set<String>, localHost: String?) -> Mode? {
            guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                let host = url.host?.lowercased()
            else { return nil }
            if failures.contains("deepgram"), host == "api.deepgram.com" { return .unreachable }
            guard host == localHost?.lowercased() else { return nil }
            if failures.contains("local") { return .unreachable }
            if failures.contains("local-stall"), url.path.hasSuffix("/audio/transcriptions") { return .stalled }
            return nil
        }

        static func matches(_ url: URL?, failures: Set<String>, localHost: String?) -> Bool {
            mode(url, failures: failures, localHost: localHost) != nil
        }

        override class func canInit(with request: URLRequest) -> Bool {
            matches(request.url, failures: failures, localHost: localHost)
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            if Self.mode(request.url, failures: Self.failures, localHost: Self.localHost) == .stalled {
                SapoLog.recording.notice("QA STT upload stalled")
                return
            }
            SapoLog.recording.notice("QA STT network failure injected")
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }

        override func stopLoading() {
            SapoLog.recording.notice("QA STT fault request stopped")
        }
    }
#endif

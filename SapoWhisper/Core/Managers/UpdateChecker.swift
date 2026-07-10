//
//  UpdateChecker.swift
//  SapoWhisper
//
//  Silent daily check of the latest GitHub release. Any failure — offline,
//  rate limit, decode error — is total silence; the only visible effect is
//  `availableUpdate` becoming non-nil when a newer version exists.
//

import Foundation
import os

@MainActor
@Observable
final class UpdateChecker {

    static let shared = UpdateChecker()

    struct AvailableUpdate: Equatable {
        let version: String
        let releaseURL: URL
    }

    /// Minimal shape of GitHub's `releases/latest` payload.
    struct LatestRelease: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    private(set) var availableUpdate: AvailableUpdate?

    private nonisolated static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/StevenACZ/SapoWhisper/releases/latest")!
    /// Below the 24 h timer period so a slightly early fire never skips a day.
    private nonisolated static let checkThrottleSeconds: TimeInterval = 20 * 3_600

    private let session: URLSession
    @ObservationIgnored private var timer: Timer?

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Scheduling

    func start() {
        guard timer == nil, isAutoCheckEnabled else { return }

        let timer = Timer(timeInterval: 86_400, repeats: true) { [weak self] _ in
            // Scheduled on RunLoop.main, so the timer always fires on main.
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.performCheck() }
            }
        }
        timer.tolerance = 3_600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            await self?.performCheck()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// On-demand check (About tab); same toggle and throttle as the timer.
    func checkNow() async {
        await performCheck()
    }

    // MARK: - Check

    /// Defaults to enabled until the Settings toggle writes the key.
    private var isAutoCheckEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Constants.StorageKeys.autoUpdateCheckEnabled) != nil else { return true }
        return defaults.bool(forKey: Constants.StorageKeys.autoUpdateCheckEnabled)
    }

    private func performCheck() async {
        guard isAutoCheckEnabled else { return }
        guard !NetworkReachability.shared.isOffline else { return }

        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        guard !Self.isThrottled(lastCheckAt: defaults.double(forKey: Constants.StorageKeys.lastUpdateCheckAt), now: now)
        else { return }

        var request = URLRequest(url: Self.latestReleaseURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("SapoWhisper/\(Constants.appVersion)", forHTTPHeaderField: "User-Agent")
        if let etag = defaults.string(forKey: Constants.StorageKeys.updateCheckETag) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            defaults.set(now, forKey: Constants.StorageKeys.lastUpdateCheckAt)
            SapoLog.lifecycle.debug("Update check status=\(http.statusCode, privacy: .public)")
            guard http.statusCode == 200 else { return }

            if let etag = http.value(forHTTPHeaderField: "ETag") {
                defaults.set(etag, forKey: Constants.StorageKeys.updateCheckETag)
            }
            let release = try JSONDecoder().decode(LatestRelease.self, from: data)
            guard Self.isVersion(release.tagName, newerThan: Constants.appVersion),
                let releaseURL = URL(string: release.htmlURL)
            else { return }
            availableUpdate = AvailableUpdate(
                version: Self.normalizedVersionText(release.tagName),
                releaseURL: releaseURL
            )
        } catch {
            SapoLog.lifecycle.debug("Update check failed status=none")
        }
    }

    // MARK: - Pure logic

    /// Numeric component comparison; a leading "v"/"V" on either side is
    /// stripped. Malformed or empty versions are never "newer".
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        guard let candidateParts = numericComponents(of: candidate),
            let currentParts = numericComponents(of: current)
        else { return false }
        let count = max(candidateParts.count, currentParts.count)
        for index in 0..<count {
            let lhs = index < candidateParts.count ? candidateParts[index] : 0
            let rhs = index < currentParts.count ? currentParts[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    nonisolated static func isThrottled(lastCheckAt: TimeInterval, now: TimeInterval) -> Bool {
        now - lastCheckAt < checkThrottleSeconds
    }

    nonisolated static func normalizedVersionText(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("v") || trimmed.hasPrefix("V") else { return trimmed }
        return String(trimmed.dropFirst())
    }

    private nonisolated static func numericComponents(of version: String) -> [Int]? {
        let parts = normalizedVersionText(version).split(separator: ".")
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        return numbers
    }
}

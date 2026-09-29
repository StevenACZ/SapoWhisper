import Darwin
import Foundation

nonisolated enum AppPreferences {
    private static let isolatedSuiteName: String? = {
        guard UIPreviewMode.skipsConsentPrompts else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SapoWhisperEphemeral", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = directory.appendingPathComponent(UUID().uuidString).path
        atexit {
            AppPreferences.removeIsolatedDomain()
        }
        return name
    }()

    static var defaults: UserDefaults {
        guard let isolatedSuiteName else { return UserDefaults.standard }
        guard let defaults = UserDefaults(suiteName: isolatedSuiteName) else {
            fatalError("Unable to create isolated app preferences")
        }
        return defaults
    }

    private static func removeIsolatedDomain() {
        guard let isolatedSuiteName else { return }
        UserDefaults(suiteName: isolatedSuiteName)?.removePersistentDomain(forName: isolatedSuiteName)
    }
}

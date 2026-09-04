import Darwin
import Foundation

nonisolated enum AppPreferences {
    private static let isolatedSuiteName: String? = {
        guard UIPreviewMode.skipsConsentPrompts else { return nil }
        let name = "oli.SapoWhisper.ephemeral.\(UUID().uuidString)"
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

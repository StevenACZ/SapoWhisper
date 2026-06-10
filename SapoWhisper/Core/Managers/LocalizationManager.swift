//
//  LocalizationManager.swift
//  SapoWhisper
//
//

import Combine
import SwiftUI

/// Gestor de internacionalización de la aplicación
///
/// Concurrency: lookups run from any thread (error descriptions are built on
/// capture queues), so `localizedString` is nonisolated and reads
/// `activeBundle` — a benign-race mirror only written on language changes.
/// The Published bundle keeps driving SwiftUI refreshes on the main actor.
class LocalizationManager: ObservableObject {
    nonisolated static let shared = LocalizationManager()

    /// New installs follow the macOS UI language (es/en supported); users can
    /// still override it in Settings, which persists to the same key.
    nonisolated static var systemDefaultLanguage: String {
        Locale.preferredLanguages.first?.hasPrefix("es") == true ? "es" : "en"
    }

    @AppStorage("appLanguage") var language: String = LocalizationManager.systemDefaultLanguage {
        didSet {
            updateBundle()
        }
    }

    /// Only purpose is firing objectWillChange when the language changes —
    /// lookups go through `activeBundle`, so nobody reads this value.
    @Published var bundle: Bundle?

    // nonisolated(unsafe): written on language changes (main) and at init;
    // read from any thread. Bundle itself is thread-safe.
    private nonisolated(unsafe) var activeBundle: Bundle?

    var locale: Locale {
        return Locale(identifier: language)
    }

    private nonisolated init() {
        let language =
            UserDefaults.standard.string(forKey: "appLanguage")
            ?? Self.systemDefaultLanguage
        activeBundle = Self.resolveBundle(for: language)
    }

    private func updateBundle() {
        let resolved = Self.resolveBundle(for: language)
        activeBundle = resolved
        bundle = resolved
    }

    private nonisolated static func resolveBundle(for language: String) -> Bundle {
        if let path = Bundle.main.path(forResource: language, ofType: "lproj"),
            let bundle = Bundle(path: path)
        {
            return bundle
        }
        return Bundle.main
    }

    nonisolated func localizedString(_ key: String, arguments: CVarArg...) -> String {
        let selectedBundle = activeBundle ?? Bundle.main
        let format = selectedBundle.localizedString(forKey: key, value: nil, table: "Localizable")

        if arguments.isEmpty {
            return format
        }

        return String(format: format, arguments: arguments)
    }
}

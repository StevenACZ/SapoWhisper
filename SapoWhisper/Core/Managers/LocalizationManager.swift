//
//  LocalizationManager.swift
//  SapoWhisper
//
//

import Combine
import SwiftUI

/// Gestor de internacionalización de la aplicación
class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    /// New installs follow the macOS UI language (es/en supported); users can
    /// still override it in Settings, which persists to the same key.
    static var systemDefaultLanguage: String {
        Locale.preferredLanguages.first?.hasPrefix("es") == true ? "es" : "en"
    }

    @AppStorage("appLanguage") var language: String = LocalizationManager.systemDefaultLanguage {
        didSet {
            updateBundle()
        }
    }

    @Published var bundle: Bundle?

    var locale: Locale {
        return Locale(identifier: language)
    }

    private init() {
        updateBundle()
    }

    private func updateBundle() {
        if let path = Bundle.main.path(forResource: language, ofType: "lproj") {
            bundle = Bundle(path: path)
        } else {
            bundle = Bundle.main
        }
    }

    func localizedString(_ key: String, arguments: CVarArg...) -> String {
        let selectedBundle = bundle ?? Bundle.main
        let format = selectedBundle.localizedString(forKey: key, value: nil, table: "Localizable")

        if arguments.isEmpty {
            return format
        }

        return String(format: format, arguments: arguments)
    }
}

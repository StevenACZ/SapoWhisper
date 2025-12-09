//
//  LocalizationManager.swift
//  SapoWhisper
//
//  Created by Steven on 9/12/24.
//

import SwiftUI
import Combine

/// Gestor de internacionalización de la aplicación
class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()
    
    @AppStorage("appLanguage") var language: String = "es" {
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

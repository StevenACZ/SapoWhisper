//
//  String+Localization.swift
//  SapoWhisper
//
//  Created by Steven on 9/12/24.
//

import Foundation

extension String {
    /// Devuelve el string localizado usando el LocalizationManager global
    var localized: String {
        LocalizationManager.shared.localizedString(self)
    }
    
    /// Devuelve el string localizado con argumentos
    func localized(_ args: CVarArg...) -> String {
        LocalizationManager.shared.localizedString(self, arguments: args)
    }
}

//
//  Constants.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import SwiftUI

/// Constantes globales de la aplicación
enum Constants {
    
    // MARK: - App Info
    
    static let appName = "SapoWhisper"
    static let appVersion = "1.0.0"
    static let appDescription = "Speech-to-Text 100% local"
    static let githubURL = "https://github.com/StevenACZ/SapoWhisper"
    
    // MARK: - Colores de la Marca
    
    enum Colors {
        // Colores principales del sapo
        static let sapoGreen = Color(red: 0.298, green: 0.686, blue: 0.314)      // #4CAF50
        static let sapoGreenDark = Color(red: 0.220, green: 0.557, blue: 0.235)  // #388E3C
        static let sapoGreenLight = Color(red: 0.784, green: 0.902, blue: 0.788) // #C8E6C9
        
        // Estados
        static let recording = Color(red: 0.957, green: 0.263, blue: 0.212)      // #F44336
        static let processing = Color(red: 1.0, green: 0.757, blue: 0.027)       // #FFC107
        static let error = Color(red: 1.0, green: 0.596, blue: 0.0)              // #FF9800
        static let disabled = Color(red: 0.620, green: 0.620, blue: 0.620)       // #9E9E9E
        
        // UI
        static let background = Color(red: 0.118, green: 0.118, blue: 0.118)     // #1E1E1E
        static let surface = Color(red: 0.176, green: 0.176, blue: 0.176)        // #2D2D2D
        static let cardBackground = Color(red: 0.15, green: 0.15, blue: 0.15)
    }
    
    // MARK: - Animaciones
    
    enum Animation {
        static let springResponse: Double = 0.3
        static let springDamping: Double = 0.7
        static let defaultDuration: Double = 0.2
        
        static var spring: SwiftUI.Animation {
            .spring(response: springResponse, dampingFraction: springDamping)
        }
        
        static var easeOut: SwiftUI.Animation {
            .easeOut(duration: defaultDuration)
        }
    }
    
    // MARK: - UI Sizes
    
    enum Sizes {
        static let menuBarWidth: CGFloat = 320
        static let cornerRadius: CGFloat = 12
        static let smallCornerRadius: CGFloat = 8
        static let padding: CGFloat = 16
        static let smallPadding: CGFloat = 8
        static let iconSize: CGFloat = 24
        static let buttonHeight: CGFloat = 44
    }
    
    // MARK: - Hotkey Defaults
    
    enum Hotkey {
        static let defaultKeyCode: UInt32 = 49  // Space
        static let defaultModifiers: UInt32 = 2048  // Option key
    }
    
    // MARK: - Audio Settings
    
    enum Audio {
        static let sampleRate: Double = 16000
        static let channels: UInt32 = 1
        static let bufferSize: UInt32 = 4096
    }
    
    // MARK: - Storage Keys
    
    enum StorageKeys {
        static let autoPaste = "autoPaste"
        static let playSound = "playSound"
        static let language = "language"
        static let selectedModel = "selectedModel"
        static let onboardingComplete = "onboardingComplete"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let selectedMicrophone = "selectedMicrophone"
    }
}

// MARK: - Color Extensions

extension Color {
    static let sapoGreen = Constants.Colors.sapoGreen
    static let sapoGreenDark = Constants.Colors.sapoGreenDark
    static let sapoGreenLight = Constants.Colors.sapoGreenLight
    static let recording = Constants.Colors.recording
    static let processing = Constants.Colors.processing
    static let sapoError = Constants.Colors.error
    static let disabled = Constants.Colors.disabled
}

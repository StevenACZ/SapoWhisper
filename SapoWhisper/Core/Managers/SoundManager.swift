//
//  SoundManager.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import AVFoundation
import AppKit

/// Maneja los sonidos de feedback de la aplicación
class SoundManager {
    
    static let shared = SoundManager()
    
    private var audioPlayer: AVAudioPlayer?
    
    private init() {}
    
    // MARK: - Sound Types
    
    enum SoundType: String {
        case startRecording = "start"
        case stopRecording = "stop"
        case success = "success"
        case error = "error"
    }
    
    // MARK: - Play Sound
    
    /// Reproduce un sonido personalizado desde Resources/Sounds
    func play(_ type: SoundType) {
        // Verificar si los sonidos están habilitados
        guard UserDefaults.standard.bool(forKey: Constants.StorageKeys.playSound) != false else {
            return
        }
        
        // Buscar el archivo de sonido en el bundle
        guard let soundURL = Bundle.main.url(forResource: type.rawValue, withExtension: "wav", subdirectory: "Sounds") else {
            print("⚠️ Sound not found: \(type.rawValue).wav")
            // Fallback a sonidos del sistema
            playSystemFallback(type)
            return
        }
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: soundURL)
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
        } catch {
            print("⚠️ Error playing sound: \(error.localizedDescription)")
            playSystemFallback(type)
        }
    }
    
    /// Fallback a sonidos del sistema si no se encuentran los personalizados
    private func playSystemFallback(_ type: SoundType) {
        let soundName: NSSound.Name
        
        switch type {
        case .startRecording:
            soundName = NSSound.Name("Morse")
        case .stopRecording:
            soundName = NSSound.Name("Pop")
        case .success:
            soundName = NSSound.Name("Glass")
        case .error:
            soundName = NSSound.Name("Basso")
        }
        
        NSSound(named: soundName)?.play()
    }
}

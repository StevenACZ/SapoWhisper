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
    
    /// Reproduce un sonido personalizado desde Resources
    /// Los archivos WAV deben agregarse al proyecto en Xcode y estar incluidos en el target
    func play(_ type: SoundType) {
        // Obtener el volumen configurado (por defecto 1.0 = 100%)
        let volume = UserDefaults.standard.object(forKey: Constants.StorageKeys.soundVolume) as? Float ?? 1.0
        
        // Buscar el archivo de sonido en el bundle
        // Primero intenta en subcarpeta Sounds/, luego en la raíz de Resources
        let soundURL = Bundle.main.url(forResource: type.rawValue, withExtension: "wav", subdirectory: "Sounds")
                    ?? Bundle.main.url(forResource: type.rawValue, withExtension: "wav")
        
        guard let url = soundURL else {
            #if DEBUG
            print("🔊 Sound '\(type.rawValue).wav' not found - using system fallback")
            #endif
            playSystemFallback(type, volume: volume)
            return
        }
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.volume = volume
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
        } catch {
            #if DEBUG
            print("⚠️ Error playing sound: \(error.localizedDescription)")
            #endif
            playSystemFallback(type, volume: volume)
        }
    }
    
    /// Fallback a sonidos del sistema si no se encuentran los personalizados
    private func playSystemFallback(_ type: SoundType, volume: Float) {
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
        
        if let sound = NSSound(named: soundName) {
            sound.volume = volume
            sound.play()
        }
    }
}

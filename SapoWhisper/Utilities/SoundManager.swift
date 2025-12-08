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
    
    enum SoundType {
        case startRecording
        case stopRecording
        case success
        case error
        
        var systemSound: NSSound.Name? {
            switch self {
            case .startRecording:
                return NSSound.Name("Morse")
            case .stopRecording:
                return NSSound.Name("Pop")
            case .success:
                return NSSound.Name("Glass")
            case .error:
                return NSSound.Name("Basso")
            }
        }
    }
    
    // MARK: - Play Sound
    
    /// Reproduce un sonido del sistema
    func play(_ type: SoundType) {
        guard UserDefaults.standard.bool(forKey: Constants.StorageKeys.playSound) != false else {
            return
        }
        
        if let soundName = type.systemSound, let sound = NSSound(named: soundName) {
            sound.play()
        }
    }
    
    /// Reproduce un sonido de clic suave usando síntesis
    func playClick() {
        NSSound.beep()
    }
}

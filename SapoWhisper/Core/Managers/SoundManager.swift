//
//  SoundManager.swift
//  SapoWhisper
//
//

import AVFoundation
import AppKit

/// Maneja los sonidos de feedback de la aplicación
class SoundManager {

    static let shared = SoundManager()

    /// Pre-cached players avoid disk I/O + AVAudioPlayer creation (~20-70ms) on each play
    private var cachedPlayers: [SoundType: AVAudioPlayer] = [:]

    private init() {
        preloadSounds()
    }

    // MARK: - Sound Types

    enum SoundType: String {
        case startRecording = "start"
        case stopRecording = "stop"
        case success = "success"
        case error = "error"
    }

    // MARK: - Preloading

    /// Load all sound files into memory on init so play() is instant
    private func preloadSounds() {
        for type in [SoundType.startRecording, .stopRecording, .success, .error] {
            let url =
                Bundle.main.url(forResource: type.rawValue, withExtension: "wav", subdirectory: "Sounds")
                ?? Bundle.main.url(forResource: type.rawValue, withExtension: "wav")
            guard let url = url else { continue }
            guard let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.prepareToPlay()
            cachedPlayers[type] = player
        }
    }

    // MARK: - Play Sound

    /// Reproduce un sonido pre-cargado desde cache (sin I/O de disco)
    func play(_ type: SoundType) {
        let volume: Float
        if UserDefaults.standard.object(forKey: Constants.StorageKeys.soundVolume) != nil {
            volume = Float(UserDefaults.standard.double(forKey: Constants.StorageKeys.soundVolume))
        } else {
            volume = 1.0
        }

        if let player = cachedPlayers[type] {
            player.volume = volume
            player.currentTime = 0
            player.play()
            return
        }

        playSystemFallback(type, volume: volume)
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

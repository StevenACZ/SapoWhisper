//
//  WhisperModel.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import Foundation

/// Modelos de Whisper disponibles para descarga
enum WhisperModel: String, CaseIterable, Identifiable {
    case tiny = "ggml-tiny.bin"
    case base = "ggml-base.bin"
    case small = "ggml-small.bin"
    case medium = "ggml-medium.bin"
    case largeV3 = "ggml-large-v3.bin"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .medium: return "Medium"
        case .largeV3: return "Large V3"
        }
    }
    
    var fileSize: String {
        switch self {
        case .tiny: return "75 MB"
        case .base: return "142 MB"
        case .small: return "466 MB"
        case .medium: return "1.5 GB"
        case .largeV3: return "3.1 GB"
        }
    }
    
    var fileSizeBytes: Int64 {
        switch self {
        case .tiny: return 75_000_000
        case .base: return 142_000_000
        case .small: return 466_000_000
        case .medium: return 1_500_000_000
        case .largeV3: return 3_100_000_000
        }
    }
    
    var accuracy: Int {
        switch self {
        case .tiny: return 2
        case .base: return 3
        case .small: return 4
        case .medium: return 5
        case .largeV3: return 5
        }
    }
    
    var speed: String {
        switch self {
        case .tiny: return "Muy rápido"
        case .base: return "Rápido"
        case .small: return "Medio"
        case .medium: return "Lento"
        case .largeV3: return "Muy lento"
        }
    }
    
    var isRecommended: Bool {
        self == .medium
    }
    
    var downloadURL: URL {
        let base = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
        return URL(string: base + rawValue)!
    }
    
    /// Directorio donde se guardan los modelos
    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDir = appSupport.appendingPathComponent("SapoWhisper/Models", isDirectory: true)
        
        // Crear directorio si no existe
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        
        return modelsDir
    }
    
    /// Ruta local del modelo
    var localPath: URL {
        WhisperModel.modelsDirectory.appendingPathComponent(rawValue)
    }
    
    /// Verifica si el modelo está descargado
    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: localPath.path)
    }
    
    /// Obtiene el primer modelo descargado disponible
    static var firstAvailable: WhisperModel? {
        allCases.first { $0.isDownloaded }
    }
}

//
//  DownloadManager.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import Foundation
import Combine

/// Maneja la descarga de modelos de Whisper
@MainActor
class DownloadManager: NSObject, ObservableObject {
    
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var errorMessage: String?
    @Published var currentModel: WhisperModel?
    
    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    
    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }
    
    /// Descarga un modelo de Whisper
    func downloadModel(_ model: WhisperModel) {
        guard !isDownloading else { return }
        
        // Si ya está descargado, no hacer nada
        if model.isDownloaded {
            print("✅ Modelo ya descargado: \(model.displayName)")
            return
        }
        
        isDownloading = true
        downloadProgress = 0
        downloadedBytes = 0
        totalBytes = model.fileSizeBytes
        errorMessage = nil
        currentModel = model
        
        print("⬇️ Iniciando descarga de: \(model.displayName) (\(model.fileSize))")
        
        downloadTask = session?.downloadTask(with: model.downloadURL)
        downloadTask?.resume()
    }
    
    /// Cancela la descarga actual
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        currentModel = nil
    }
    
    /// Formatea bytes a string legible
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        Task { @MainActor in
            guard let model = currentModel else { return }
            
            do {
                // Mover archivo descargado a la ubicación final
                let destinationURL = model.localPath
                
                // Eliminar archivo anterior si existe
                try? FileManager.default.removeItem(at: destinationURL)
                
                // Mover el archivo descargado
                try FileManager.default.moveItem(at: location, to: destinationURL)
                
                print("✅ Modelo descargado exitosamente: \(model.displayName)")
                print("📁 Ubicación: \(destinationURL.path)")
                
                isDownloading = false
                downloadProgress = 1.0
                currentModel = nil
            } catch {
                errorMessage = "Error al guardar: \(error.localizedDescription)"
                isDownloading = false
            }
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            downloadedBytes = totalBytesWritten
            if totalBytesExpectedToWrite > 0 {
                totalBytes = totalBytesExpectedToWrite
                downloadProgress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            }
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            if let error = error as NSError?, error.code != NSURLErrorCancelled {
                errorMessage = error.localizedDescription
                isDownloading = false
                currentModel = nil
            }
        }
    }
}

//
//  SapoWhisperViewModel.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import SwiftUI
import Combine

/// ViewModel principal que coordina toda la funcionalidad de la app
@MainActor
class SapoWhisperViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published private(set) var appState: AppState = .idle
    @Published private(set) var lastTranscription: String = ""
    @Published var showSettings = false
    @Published var autoPasteEnabled = true
    @Published var recordingDuration: TimeInterval = 0
    
    // MARK: - Managers
    
    let audioRecorder = AudioRecorder()
    let transcriber = WhisperTranscriber()
    let downloadManager = DownloadManager()
    let hotkeyManager = HotkeyManager.shared
    
    // MARK: - Private Properties
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    init() {
        setupBindings()
        checkInitialState()
        setupHotkey()
    }
    
    private func setupBindings() {
        // Observar estado de grabación
        audioRecorder.$isRecording
            .sink { [weak self] isRecording in
                if isRecording {
                    self?.appState = .recording
                }
            }
            .store(in: &cancellables)
        
        // Observar duración de grabación
        audioRecorder.$recordingDuration
            .sink { [weak self] duration in
                self?.recordingDuration = duration
            }
            .store(in: &cancellables)
        
        // Observar estado de transcripción
        transcriber.$isTranscribing
            .sink { [weak self] isTranscribing in
                if isTranscribing {
                    self?.appState = .processing
                }
            }
            .store(in: &cancellables)
        
        // Observar cuando el modelo está listo
        transcriber.$isModelLoaded
            .sink { [weak self] isLoaded in
                if isLoaded && self?.audioRecorder.isRecording == false && self?.transcriber.isTranscribing == false {
                    self?.appState = .idle
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Initial State
    
    private func checkInitialState() {
        if transcriber.isModelLoaded {
            appState = .idle
        } else {
            appState = .noModel
        }
    }
    
    /// Descarga un modelo de Whisper
    func downloadModel(_ model: WhisperModel) {
        downloadManager.downloadModel(model)
    }
    
    /// Carga un modelo después de configurarlo
    func loadModel(_ model: WhisperModel) async {
        do {
            try await transcriber.loadModel(model)
            appState = .idle
        } catch {
            appState = .error(error.localizedDescription)
        }
    }
    
    // MARK: - Recording & Transcription
    
    /// Toggle de grabación (llamado por hotkey o botón)
    func toggleRecording() {
        if audioRecorder.isRecording {
            stopRecordingAndTranscribe()
        } else {
            startRecording()
        }
    }
    
    /// Inicia la grabación
    func startRecording() {
        guard transcriber.isModelLoaded else {
            appState = .noModel
            return
        }
        
        do {
            try audioRecorder.startRecording()
            appState = .recording
            print("🎤 Grabación iniciada")
        } catch {
            appState = .error(error.localizedDescription)
            print("❌ Error al iniciar grabación: \(error)")
        }
    }
    
    /// Detiene la grabación y transcribe
    func stopRecordingAndTranscribe() {
        guard let audioURL = audioRecorder.stopRecording() else {
            appState = .error("No se pudo obtener el audio")
            return
        }
        
        print("🎤 Grabación detenida, iniciando transcripción...")
        appState = .processing
        
        Task {
            do {
                let transcription = try await transcriber.transcribe(audioURL: audioURL)
                lastTranscription = transcription
                
                // Copiar al portapapeles
                PasteManager.copyToClipboard(transcription)
                
                // Auto-paste si está habilitado
                if autoPasteEnabled {
                    // Pequeño delay para asegurar que el clipboard esté listo
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    PasteManager.simulatePaste()
                }
                
                appState = .idle
                
                // Limpiar archivo temporal
                audioRecorder.deleteRecording(at: audioURL)
                print("✅ Transcripción completada y copiada")
            } catch {
                appState = .error(error.localizedDescription)
                print("❌ Error en transcripción: \(error)")
            }
        }
    }
    
    // MARK: - Hotkey
    
    private func setupHotkey() {
        hotkeyManager.registerHotkey { [weak self] in
            Task { @MainActor in
                self?.toggleRecording()
            }
        }
    }
    
    /// Texto del estado actual
    var statusText: String {
        switch appState {
        case .recording:
            let duration = Int(recordingDuration)
            return "Grabando... \(duration)s"
        default:
            return appState.statusText
        }
    }
    
    /// Texto del botón de grabación
    var recordButtonText: String {
        audioRecorder.isRecording ? "⏹ Detener" : "🎤 Grabar"
    }
    
    /// Si el botón de grabar está habilitado
    var canRecord: Bool {
        transcriber.isModelLoaded && !transcriber.isTranscribing
    }
    
    /// Formatea la duración de grabación
    var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

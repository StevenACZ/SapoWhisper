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

    // MARK: - AppStorage Properties

    @AppStorage(Constants.StorageKeys.language) var selectedLanguage = "es"
    @AppStorage(Constants.StorageKeys.selectedMicrophone) var selectedMicrophone = "default"
    @AppStorage(Constants.StorageKeys.hotkeyKeyCode) var hotkeyKeyCode: Int = Int(Constants.Hotkey.defaultKeyCode)
    @AppStorage(Constants.StorageKeys.hotkeyModifiers) var hotkeyModifiers: Int = Int(Constants.Hotkey.defaultModifiers)
    @AppStorage(Constants.StorageKeys.playSound) var playSoundEnabled = true

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
        loadSavedSettings()
    }

    /// Carga las configuraciones guardadas
    private func loadSavedSettings() {
        // Aplicar micrófono guardado
        audioRecorder.selectedDeviceUID = selectedMicrophone

        // Aplicar hotkey guardado
        hotkeyManager.currentKeyCode = UInt32(hotkeyKeyCode)
        hotkeyManager.currentModifiers = UInt32(hotkeyModifiers)
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

        // Guardar la app activa para volver a ella después de pegar
        PasteManager.savePreviousApp()

        do {
            // Actualizar micrófono seleccionado antes de grabar
            audioRecorder.selectedDeviceUID = selectedMicrophone
            try audioRecorder.startRecording()
            appState = .recording
            if playSoundEnabled {
                SoundManager.shared.play(.startRecording)
            }
            print("🎤 Grabación iniciada")
        } catch {
            appState = .error(error.localizedDescription)
            if playSoundEnabled {
                SoundManager.shared.play(.error)
            }
            print("❌ Error al iniciar grabación: \(error)")
        }
    }
    
    /// Detiene la grabación y transcribe
    func stopRecordingAndTranscribe() {
        if playSoundEnabled {
            SoundManager.shared.play(.stopRecording)
        }

        guard let audioURL = audioRecorder.stopRecording() else {
            appState = .error("No se pudo obtener el audio")
            if playSoundEnabled {
                SoundManager.shared.play(.error)
            }
            return
        }

        print("🎤 Grabación detenida, iniciando transcripción...")
        appState = .processing

        // Capturar el idioma seleccionado para usar en el Task
        let language = selectedLanguage

        Task {
            do {
                let transcription = try await transcriber.transcribe(audioURL: audioURL, language: language)
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
                if playSoundEnabled {
                    SoundManager.shared.play(.success)
                }

                // Limpiar archivo temporal
                audioRecorder.deleteRecording(at: audioURL)
                print("✅ Transcripción completada y copiada")
            } catch {
                appState = .error(error.localizedDescription)
                if playSoundEnabled {
                    SoundManager.shared.play(.error)
                }
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

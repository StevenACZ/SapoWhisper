//
//  DockIconManager.swift
//  SapoWhisper
//
//  Created by Steven on 9/12/24.
//

import AppKit
import Combine

/// Administrador centralizado de los iconos del Dock
/// Se encarga de cambiar dinámicamente el icono de la app según su estado
@MainActor
final class DockIconManager: ObservableObject {
    static let shared = DockIconManager()
    
    private var cancellables = Set<AnyCancellable>()
    
    // Cache de imágenes
    // NOTA: Los nombres deben coincidir con los "Image Set" en Assets.xcassets
    // Hemos creado carpetas .imageset llamadas "DockIconIdle", "DockIconLoading", etc.
    // El nombre del recurso es el nombre de la carpeta .imageset sin la extensión.
    private let idleIcon = NSImage(named: "DockIconIdle")
    private let loadingIcon = NSImage(named: "DockIconLoading")
    private let recordingIcon = NSImage(named: "DockIconRecording")
    private let transcribingIcon = NSImage(named: "DockIconTranscribing")
    private var lastIconName: String?
    private let isMenuBarOnlyApp = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true
    
    private init() {
        // Verificar que todas las imágenes carguen correctamente
        print("🎨 DockIconManager: Initializing...")
        if idleIcon == nil { print("⚠️ DockIconManager: Failed to load DockIconIdle") }
        else { print("✅ DockIconManager: DockIconIdle loaded") }
        
        if loadingIcon == nil { print("⚠️ DockIconManager: Failed to load DockIconLoading") }
        else { print("✅ DockIconManager: DockIconLoading loaded") }
        
        if recordingIcon == nil { print("⚠️ DockIconManager: Failed to load DockIconRecording") }
        else { print("✅ DockIconManager: DockIconRecording loaded") }
        
        if transcribingIcon == nil { print("⚠️ DockIconManager: Failed to load DockIconTranscribing") }
        else { print("✅ DockIconManager: DockIconTranscribing loaded") }
    }
    
    /// Actualiza el icono del Dock basado en el estado de la app
    func updateIcon(for state: AppState, isModelLoading: Bool = false) {
        let t0 = CFAbsoluteTimeGetCurrent()

        if isMenuBarOnlyApp {
            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            print("⏱️ [dock icon] skipped in menu-bar-only mode (\(String(format: "%.0f", elapsed))ms)")
            return
        }

        let newIcon: NSImage?
        var iconName: String = ""
        
        if isModelLoading {
            newIcon = loadingIcon
            iconName = "Loading"
        } else {
            switch state {
            case .idle, .error, .noModel:
                newIcon = idleIcon
                iconName = "Idle"
            case .recording:
                newIcon = recordingIcon
                iconName = "Recording"
            case .processing:
                newIcon = transcribingIcon
                iconName = "Transcribing"
            }
        }
        
        print("🎨 DockIconManager: Updating to \(iconName) (state: \(state), isModelLoading: \(isModelLoading))")

        if lastIconName == iconName {
            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            print("⏱️ [dock icon] skipped duplicate \(iconName) (\(String(format: "%.0f", elapsed))ms)")
            return
        }
        
        // Solo actualizar si la imagen es válida y diferente (aunque NSApp lo gestiona bien)
        if let icon = newIcon {
            NSApp.applicationIconImage = icon
            lastIconName = iconName
            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            print("✅ DockIconManager: Icon updated successfully (\(String(format: "%.0f", elapsed))ms)")
        } else {
            // Fallback al icono original de la app si algo falla
            NSApp.applicationIconImage = nil 
            lastIconName = nil
            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            print("⚠️ DockIconManager: Icon was nil, using default (\(String(format: "%.0f", elapsed))ms)")
        }
    }
    
    /// Restaura el icono original (útil al cerrar la app)
    func restoreDefaultIcon() {
        NSApp.applicationIconImage = nil
    }
}

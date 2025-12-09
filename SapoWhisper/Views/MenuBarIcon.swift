//
//  MenuBarIcon.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import SwiftUI

/// Icono personalizado para el Menu Bar que muestra el estado de la app
/// Usa imágenes del sapo que cambian según el estado
struct MenuBarIcon: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    
    var body: some View {
        Image(nsImage: menuBarImage)
            .renderingMode(.original)
    }
    
    /// Imagen del Menu Bar basada en el estado actual
    private var menuBarImage: NSImage {
        let imageName = menuBarImageName
        
        // Intentar cargar la imagen del asset catalog
        if let image = NSImage(named: imageName) {
            // Configurar el tamaño correcto para el menu bar
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        
        // Fallback: crear una imagen con SF Symbol si falla
        print("⚠️ MenuBarIcon: Failed to load \(imageName), using fallback")
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        return NSImage(systemSymbolName: fallbackIconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
    }
    
    /// Nombre del asset de imagen según el estado
    private var menuBarImageName: String {
        // Primero verificar si el modelo está cargando
        if viewModel.isLoadingWhisperKit {
            return "MenuBarIconLoading"
        }
        
        switch viewModel.appState {
        case .recording:
            return "MenuBarIconRecording"
        case .processing:
            return "MenuBarIconTranscribing"
        case .idle, .error, .noModel:
            return "MenuBarIconIdle"
        }
    }
    
    /// SF Symbol de respaldo si la imagen no carga
    private var fallbackIconName: String {
        switch viewModel.appState {
        case .recording:
            return "mic.circle.fill"
        case .processing:
            return "ellipsis.circle.fill"
        case .error:
            return "exclamationmark.circle.fill"
        case .noModel:
            return "questionmark.circle.fill"
        default:
            return "waveform.circle.fill"
        }
    }
}

#Preview {
    MenuBarIcon(viewModel: SapoWhisperViewModel())
}

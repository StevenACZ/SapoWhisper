//
//  MenuBarIcon.swift
//  SapoWhisper
//
//

import SwiftUI

/// Icono personalizado para el Menu Bar que muestra el estado de la app
/// Usa imágenes del sapo que cambian según el estado
struct MenuBarIcon: View {
    @ObservedObject var viewModel: SapoWhisperViewModel

    var body: some View {
        Image(
            nsImage: MenuBarIconImageProvider.image(
                for: viewModel.appState,
                isLoadingWhisperKit: viewModel.isLoadingWhisperKit
            )
        )
        .renderingMode(.original)
    }
}

enum MenuBarIconImageProvider {
    static func image(for appState: AppState, isLoadingWhisperKit: Bool) -> NSImage {
        let imageName = menuBarImageName(for: appState, isLoadingWhisperKit: isLoadingWhisperKit)

        if let image = NSImage(named: imageName) {
            let statusImage = (image.copy() as? NSImage) ?? image
            statusImage.size = NSSize(width: 22, height: 22)
            return statusImage
        }

        print("⚠️ MenuBarIcon: Failed to load \(imageName), using fallback")
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        return NSImage(systemSymbolName: fallbackIconName(for: appState), accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
    }

    private static func menuBarImageName(
        for appState: AppState,
        isLoadingWhisperKit: Bool
    ) -> String {
        if isLoadingWhisperKit {
            return "MenuBarIconLoading"
        }

        switch appState {
        case .recording:
            return "MenuBarIconRecording"
        case .processing:
            return "MenuBarIconTranscribing"
        case .idle, .error, .noModel:
            return "MenuBarIconIdle"
        }
    }

    private static func fallbackIconName(for appState: AppState) -> String {
        switch appState {
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

#Preview("Menu Bar Icon") {
    MenuBarIcon(viewModel: SapoWhisperViewModel())
        .padding()
}

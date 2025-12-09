//
//  MenuBarIcon.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import SwiftUI

/// Icono personalizado para el Menu Bar que muestra el estado de la app
struct MenuBarIcon: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    
    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.hierarchical)
    }
    
    private var iconName: String {
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
            return "waveform.circle.fill"  // Estado idle/normal
        }
    }
}

#Preview {
    MenuBarIcon(viewModel: SapoWhisperViewModel())
}

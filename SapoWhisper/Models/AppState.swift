//
//  AppState.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import SwiftUI

/// Estados posibles de la aplicación
enum AppState: Equatable {
    case idle           // Verde - Listo para grabar
    case recording      // Rojo - Grabando audio
    case processing     // Amarillo - Transcribiendo
    case error(String)  // Naranja - Error
    case noModel        // Gris - Sin modelo instalado
    
    var statusText: String {
        switch self {
        case .idle:
            return "Listo para grabar"
        case .recording:
            return "Grabando..."
        case .processing:
            return "Transcribiendo..."
        case .error(let message):
            return "Error: \(message)"
        case .noModel:
            return "Descarga un modelo primero"
        }
    }
    
    var iconName: String {
        switch self {
        case .idle:
            return "waveform.circle.fill"
        case .recording:
            return "record.circle.fill"
        case .processing:
            return "ellipsis.circle.fill"
        case .error:
            return "exclamationmark.circle.fill"
        case .noModel:
            return "arrow.down.circle.fill"
        }
    }
    
    var iconColor: Color {
        switch self {
        case .idle:
            return Color(red: 0.298, green: 0.686, blue: 0.314)  // #4CAF50
        case .recording:
            return Color(red: 0.957, green: 0.263, blue: 0.212)  // #F44336
        case .processing:
            return Color(red: 1.0, green: 0.757, blue: 0.027)    // #FFC107
        case .error:
            return Color(red: 1.0, green: 0.596, blue: 0.0)      // #FF9800
        case .noModel:
            return Color(red: 0.620, green: 0.620, blue: 0.620)  // #9E9E9E
        }
    }
}

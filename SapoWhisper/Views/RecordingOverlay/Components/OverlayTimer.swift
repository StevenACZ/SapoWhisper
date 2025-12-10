//
//  OverlayTimer.swift
//  SapoWhisper
//

import SwiftUI

/// Contador de tiempo durante grabacion
struct OverlayTimer: View {
    let duration: TimeInterval

    var body: some View {
        Text(formattedDuration)
            .font(.system(size: 24, weight: .semibold, design: .monospaced))
            .foregroundColor(.primary)
            .contentTransition(.numericText())
    }

    private var formattedDuration: String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

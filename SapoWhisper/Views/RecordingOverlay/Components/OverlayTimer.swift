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
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
            .contentTransition(.numericText())
            .animation(.easeOut(duration: 0.2), value: formattedDuration)
    }

    private var formattedDuration: String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

#Preview("Timer States") {
    VStack(spacing: 12) {
        HStack(spacing: 12) {
            Text("0s").font(.caption2).foregroundColor(.secondary).frame(width: 40)
            OverlayTimer(duration: 0)
        }
        HStack(spacing: 12) {
            Text("5s").font(.caption2).foregroundColor(.secondary).frame(width: 40)
            OverlayTimer(duration: 5)
        }
        HStack(spacing: 12) {
            Text("1m 5s").font(.caption2).foregroundColor(.secondary).frame(width: 40)
            OverlayTimer(duration: 65)
        }
        HStack(spacing: 12) {
            Text("61m").font(.caption2).foregroundColor(.secondary).frame(width: 40)
            OverlayTimer(duration: 3661)
        }
    }
    .padding(20)
}

//
//  RecordingOverlayPreviews.swift
//  SapoWhisper
//

import SwiftUI

private struct PillPreview<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
            content
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                )
                .fixedSize()
        }
        .frame(width: 460, height: 100)
    }
}

#Preview("Recording") {
    PillPreview { RecordingPillView(duration: 15, onPause: {}, audioLevel: 0.5) }
}

#Preview("Paused") {
    PillPreview { PausedPillView(duration: 42, onResume: {}) }
}

#Preview("Transcribing") {
    PillPreview { TranscribingPillView() }
}

#Preview("Completed") {
    PillPreview { CompletedPillView(text: "Hola, esta es una transcripcion") }
}

#Preview("Error") {
    PillPreview { ErrorPillView(message: "No se pudo conectar", onRetry: {}) }
}

#Preview("Device Detected") {
    PillPreview { DeviceDetectedPillView(deviceName: "MacBook Pro Microphone") }
}

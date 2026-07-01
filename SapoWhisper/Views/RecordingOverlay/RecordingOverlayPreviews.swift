//
//  RecordingOverlayPreviews.swift
//  SapoWhisper
//

import Combine
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
    PillPreview {
        RecordingPillView(
            duration: 15,
            onPause: {},
            audioLevelPublisher: Just(Float(0.5)).eraseToAnyPublisher()
        )
    }
}

#Preview("Paused") {
    PillPreview { PausedPillView(duration: 42, onResume: {}) }
}

#Preview("Transcribing") {
    PillPreview { TranscribingPillView() }
}

#Preview("Recording - Edit Session") {
    PillPreview {
        RecordingPillView(
            duration: 8,
            onPause: {},
            audioLevelPublisher: Just(Float(0.5)).eraseToAnyPublisher(),
            isEditSession: true
        )
    }
}

#Preview("Completed") {
    PillPreview { CompletedPillView(text: "Hola, esta es una transcripcion") }
}

#Preview("Completed - Long") {
    PillPreview {
        CompletedPillView(
            text: String(repeating: "Esta es una transcripcion larga para probar el scroll del pill. ", count: 12)
        )
    }
}

#Preview("Cancelled") {
    PillPreview { CancelledPillView() }
}

#Preview("Docked") {
    PillPreview { DockedChipView(onTap: {}) }
}

#Preview("Error") {
    PillPreview { ErrorPillView(message: "No se pudo conectar", onRetry: {}) }
}

#Preview("Device Detected") {
    PillPreview { DeviceDetectedPillView(deviceName: "MacBook Pro Microphone") }
}

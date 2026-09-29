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
                .padding(.horizontal, OverlayPillChrome.horizontalPadding)
                .padding(.vertical, OverlayPillChrome.verticalPadding)
                .overlayPillChrome()
                .fixedSize()
        }
        .frame(width: 460, height: 100)
    }
}

#Preview("Recording") {
    PillPreview {
        DictationPillView(
            phase: .recording,
            duration: 15,
            audioLevelPublisher: Just(Float(0.5)).eraseToAnyPublisher()
        )
    }
}

#Preview("Paused") {
    PillPreview {
        DictationPillView(phase: .paused, duration: 42, audioLevelPublisher: Just(Float(0)).eraseToAnyPublisher())
    }
}

#Preview("Transcribing") {
    PillPreview {
        DictationPillView(
            phase: .transcribing,
            duration: 42,
            audioLevelPublisher: Just(Float(0)).eraseToAnyPublisher(),
            onCancel: {}
        )
    }
}

#Preview("Copied") {
    PillPreview { CopiedPillView() }
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

#Preview("Error") {
    PillPreview { ErrorPillView(message: "No se pudo conectar", onRetry: {}) }
}

#Preview("Device Connecting") {
    PillPreview {
        DeviceChangePillView(
            announcement: DeviceChangeAnnouncement(
                deviceName: "AirPods Pro", transport: .bluetooth, phase: .connecting
            )
        )
    }
}

#Preview("Device Ready") {
    PillPreview {
        DeviceChangePillView(
            announcement: DeviceChangeAnnouncement(
                deviceName: "MacBook Pro Microphone", transport: .builtIn, phase: .ready
            )
        )
    }
}

#Preview("Device Fallback") {
    PillPreview {
        DeviceChangePillView(
            announcement: DeviceChangeAnnouncement(
                deviceName: "MacBook Pro Microphone", transport: .builtIn, phase: .fallback
            )
        )
    }
}

#Preview("Recording Connecting") {
    PillPreview {
        DictationPillView(
            phase: .recording,
            duration: 0,
            audioLevelPublisher: Just(Float(0)).eraseToAnyPublisher(),
            connectingDeviceName: "AirPods Pro"
        )
    }
}

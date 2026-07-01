//
//  RecordingOverlayView.swift
//  SapoWhisper
//
//  Created by Claude on 9/12/24.
//

import SwiftUI

/// Vista principal del overlay de grabacion - pill horizontal en la parte inferior
struct RecordingOverlayView: View {

    @ObservedObject var manager: OverlayWindowManager

    @State private var scale: CGFloat = 1.0
    @State private var contentOpacity: Double = 1.0
    @State private var entranceOffset: CGFloat = 0

    private var stateCategory: String { manager.state.stateCategory }
    private var isDocked: Bool { stateCategory == "docked" }

    var body: some View {
        // The ZStack hosts the outgoing and incoming pill contents during a
        // state swap so the capsule morphs once while the texts hand off
        // sequentially (old fades out fast, new fades in right after) instead
        // of crushing both inside the resizing capsule.
        ZStack {
            contentForState
                .id(stateCategory)
                .transition(
                    .asymmetric(
                        insertion: .opacity.animation(.easeIn(duration: 0.16).delay(0.1)),
                        removal: .opacity.animation(.easeOut(duration: 0.1))
                    )
                )
        }
        .padding(.horizontal, isDocked ? 10 : 20)
        .padding(.vertical, isDocked ? 5 : 12)
        .background(
            // Continuous rounded rect instead of a capsule: multi-line states
            // (chips, expanded transcript) made the capsule's semicircular
            // ends huge, reading as wasted width. The docked chip shares the
            // same shape so expand/collapse reads as one surface morphing.
            RoundedRectangle(cornerRadius: isDocked ? 10 : 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.25), radius: isDocked ? 5 : 10, y: 3)
        )
        .fixedSize()
        // Transparent margin inside the auto-sized window so the shadow, the
        // glow stroke, and the micro-bounce overshoot are never clipped at
        // the window edge (a clipped shadow reads as a hard rectangle).
        .padding(.horizontal, isDocked ? 12 : 36)
        .padding(.vertical, isDocked ? 8 : 26)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: OverlayPillSizeKey.self, value: proxy.size)
            }
        )
        .scaleEffect(scale)
        .opacity(contentOpacity)
        .offset(y: entranceOffset)
        .onChange(of: stateCategory) { oldValue, newValue in
            guard newValue != "hidden" else { return }
            if oldValue == "hidden" {
                runEntrance()
            } else {
                microBounce()
            }
        }
        .onChange(of: manager.isDismissing) { _, dismissing in
            if dismissing {
                withAnimation(.easeIn(duration: 0.22)) {
                    scale = 0.95
                }
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    scale = 1.0
                }
            }
        }
        .onAppear {
            if stateCategory != "hidden" {
                runEntrance()
            }
        }
        .onPreferenceChange(OverlayPillSizeKey.self) { [manager] size in
            // The window tracks the pill's laid-out size, so long error
            // messages grow it instead of being clipped at a fixed frame.
            Task { @MainActor in
                manager.updateWindowSize(to: size)
            }
        }
    }

    /// Pop-in played on every appearance (the window is reused, so onAppear
    /// alone only covers the first one): start slightly small, transparent and
    /// low, then spring to rest.
    private func runEntrance() {
        var snap = Transaction()
        snap.disablesAnimations = true
        withTransaction(snap) {
            scale = 0.92
            contentOpacity = 0
            entranceOffset = 6
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.75)) {
            scale = 1.0
            contentOpacity = 1.0
            entranceOffset = 0
        }
    }

    /// Micro-bounce effect when state changes — subtle scale pop for tactile feedback
    private func microBounce() {
        withAnimation(.spring(response: 0.12, dampingFraction: 0.4)) {
            scale = 1.05
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                scale = 1.0
            }
        }
    }

    // MARK: - Content Views

    @ViewBuilder
    private var contentForState: some View {
        switch manager.state {
        case .hidden:
            EmptyView()

        case .docked:
            DockedChipView(
                onHoverChanged: { manager.handleDockHover($0) },
                onTap: { manager.expandDockToLastTranscription() }
            )

        case .recording(let duration):
            RecordingPillView(
                duration: duration,
                onPause: { manager.onPauseToggle?() },
                audioLevelPublisher: manager.audioLevelPublisher,
                showsNoSpeechHint: manager.showsNoSpeechHint,
                isEditSession: manager.isEditSession,
                onModeSelected: { manager.onQuickModeSelected?($0) },
                onTranslationToggled: { manager.onQuickTranslationToggled?($0) }
            )

        case .paused(let duration):
            PausedPillView(
                duration: duration,
                onResume: { manager.onPauseToggle?() }
            )

        case .transcribing:
            TranscribingPillView()

        case .polishing(let timeoutSeconds):
            AIPolishingPillView(timeoutSeconds: timeoutSeconds)

        case .completed(let text):
            CompletedPillView(
                text: text,
                onRepolish: { manager.onRepolishRequested?() },
                onVoiceEdit: { manager.onVoiceEditRequested?() },
                onClose: { manager.hide() }
            )
            .onHover { hovering in
                manager.setCompletedHover(hovering)
            }

        case .cancelled:
            CancelledPillView()

        case .error(let message, let isRetryable):
            ErrorPillView(message: message, onRetry: isRetryable ? manager.onRetry : nil)

        case .deviceDetected(let deviceName):
            DeviceDetectedPillView(deviceName: deviceName)
        }
    }
}

/// Reports the pill's laid-out size so the hosting window can match it.
private nonisolated struct OverlayPillSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

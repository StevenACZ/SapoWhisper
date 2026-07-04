//
//  RecordingOverlayView.swift
//  SapoWhisper
//
//  Created by Claude on 9/12/24.
//

import SwiftUI

/// Window-relative frame of the pill + chip stack inside the fixed
/// transparent surface (`.global` in a hosting view is window space).
struct OverlayContentFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// Vista principal del overlay de grabacion. Two-piece layout: the dock chip
/// is a permanent fixture hugging the screen edge, and every active state
/// (recording, transcribing, completed, ...) is a separate "droplet" pill that
/// detaches from the chip when it appears and is absorbed back on dismiss.
/// Because the droplet enters as one finished unit (background + content
/// together), there is never an empty background morph or content sticking
/// out of a half-grown pill.
struct RecordingOverlayView: View {

    @ObservedObject var manager: OverlayWindowManager

    @State private var scale: CGFloat = 1.0

    private var stateCategory: String { manager.state.stateCategory }
    private var isActive: Bool { stateCategory != "hidden" && stateCategory != "docked" }
    /// The chip hugs the configured screen edge; the droplet detaches toward
    /// the screen center, so a top-anchored overlay flips the stack.
    private var chipOnTop: Bool { OverlayPosition.configured == .top }

    /// Where the content rests inside the fixed transparent surface.
    private var surfaceAlignment: Alignment {
        switch OverlayPosition.configured {
        case .top: return .top
        case .center: return .center
        case .bottom: return .bottom
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if chipOnTop {
                chip
            }
            if isActive {
                activePill
                    // Small fixed gap to the chip: at the start of the detach
                    // the tiny droplet reads as connected, and once grown it
                    // reads as two separated parts with the chip peeking out.
                    .padding(chipOnTop ? .top : .bottom, 8)
                    .transition(dropletTransition)
            }
            if !chipOnTop {
                chip
            }
        }
        .fixedSize()
        // Publish where the real content sits inside the mostly-transparent
        // surface, so the outside-click collapse can compare against the
        // visible pill instead of the whole fixed window rect.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: OverlayContentFramePreferenceKey.self,
                    value: proxy.frame(in: .global)
                )
            }
        )
        // Slim transparent inset on the chip side so its shadow still renders
        // while the chip visually hugs the screen edge.
        .padding(chipOnTop ? .top : .bottom, 4)
        // The hosting window is a fixed transparent surface that NEVER
        // resizes: window resizes during SwiftUI transaction animations made
        // NSHostingView animate the window frame from inside the display
        // cycle (updateAnimatedWindowSize), which throws and crashes the app.
        // The content simply lays out against the configured edge; empty
        // surface pixels are alpha-transparent, so clicks there fall through
        // to whatever is behind the window.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: surfaceAlignment)
        .onPreferenceChange(OverlayContentFramePreferenceKey.self) { frame in
            Task { @MainActor in
                OverlayWindowManager.shared.setActiveContentFrame(frame)
            }
        }
        .onChange(of: stateCategory) { oldValue, newValue in
            // Micro-bounce only on active-to-active swaps; dock transitions
            // are carried entirely by the droplet detach/absorb.
            guard isActive, oldValue != "hidden", oldValue != "docked" else { return }
            microBounce()
        }
    }

    private var chip: some View {
        DockedChipView(isExpanded: isActive, onTap: { manager.dockChipTapped() })
    }

    /// The droplet grows out of the chip's edge and collapses back into it:
    /// scale is anchored at the chip side and stays fully opaque, so the
    /// enter/exit reads as a drop separating from (and being absorbed by)
    /// the resting chip rather than a crossfade.
    private var dropletTransition: AnyTransition {
        .scale(scale: 0.04, anchor: chipOnTop ? .top : .bottom)
    }

    private var activePill: some View {
        // The ZStack hosts the outgoing and incoming pill contents during an
        // active-to-active swap so the pill morphs once while the texts hand
        // off sequentially (old fades out fast, new fades in right after).
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
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            // Continuous rounded rect instead of a capsule: multi-line states
            // (chips, expanded transcript) made the capsule's semicircular
            // ends huge, reading as wasted width.
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        )
        .scaleEffect(scale)
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
        case .hidden, .docked:
            EmptyView()

        case .recording(let duration):
            RecordingPillView(
                duration: duration,
                onPause: { manager.onPauseToggle?() },
                audioLevelPublisher: manager.audioLevelPublisher,
                showsNoSpeechHint: manager.showsNoSpeechHint,
                connectingDeviceName: manager.micConnectingName,
                resumeOffer: manager.resumeOffer,
                onResumeToggle: { manager.toggleResumeOffer() },
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
                onClose: { manager.hide() }
            )
            .onHover { hovering in
                manager.setCompletedHover(hovering)
            }

        case .cancelled:
            CancelledPillView()

        case .error(let message, let isRetryable):
            ErrorPillView(message: message, onRetry: isRetryable ? manager.onRetry : nil)

        case .deviceChange(let announcement):
            DeviceChangePillView(announcement: announcement)
        }
    }
}

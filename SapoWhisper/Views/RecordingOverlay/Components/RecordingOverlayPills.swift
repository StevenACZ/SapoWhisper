//
//  RecordingOverlayPills.swift
//  SapoWhisper
//

import Combine
import SwiftUI

struct RecordingPillView: View {
    let duration: TimeInterval
    let onPause: () -> Void
    let audioLevelPublisher: AnyPublisher<Float, Never>
    var showsNoSpeechHint: Bool = false
    /// Non-nil while the input still delivers dead air (Bluetooth handshake):
    /// the pill explains the silence instead of showing a flat waveform.
    var connectingDeviceName: String? = nil
    /// "Continue previous dictation" chip: a recent cancelled/crashed take can
    /// be prepended to this recording at stop time.
    var resumeOffer: OverlayWindowManager.ResumeOffer? = nil
    var onResumeToggle: (() -> Void)?
    var onTranslationToggled: ((Bool) -> Void)?
    /// Compact polish mode is active for this dictation: purple meter + chip.
    var compactModeActive: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            FloatingSapoIcon(state: .recording, size: 32)
            PillDivider()
            MiniEqualizerView(
                audioLevelPublisher: audioLevelPublisher,
                barCount: 11,
                isConnecting: connectingDeviceName != nil,
                barColor: compactModeActive ? .compactMode : .recording
            )

            if let connectingDeviceName {
                Text("overlay.mic_connecting".localized(connectingDeviceName))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            } else if showsNoSpeechHint {
                HStack(spacing: 5) {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("overlay.no_speech".localized)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.sapoError)
                .transition(.opacity)
            } else {
                Text("overlay.recording".localized)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .transition(.opacity)
            }

            Spacer(minLength: 6)

            if let resumeOffer {
                ResumePreviousChip(offer: resumeOffer, onTap: { onResumeToggle?() })
            }

            // Compact + language chips read as one tight control cluster; the
            // default HStack spacing left them looking scattered.
            HStack(spacing: 5) {
                if compactModeActive {
                    CompactModeChip()
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }

                OverlayTranslationChip(onTranslationToggled: onTranslationToggled)
            }

            OverlayIconButton(
                systemName: "pause.fill",
                label: "overlay.a11y.pause".localized,
                diameter: 26,
                iconSize: 11,
                action: onPause
            )

            OverlayTimer(duration: duration)
        }
        .frame(minWidth: 250)
        // No local animation for the connecting swap: the manager's spring
        // transaction drives it (same pattern as `showsNoSpeechHint`).
        // The chip appears mid-recording when the minimum-duration threshold
        // is crossed (duration ticks swap state without animation), so its
        // pop is driven locally.
        .animation(.smooth(duration: 0.25), value: compactModeActive)
    }
}

/// Opt-in chip to prepend the previous (cancelled or crash-recovered) take to
/// the current recording. Shows the recoverable duration; active state fills
/// green so "this dictation will include the previous one" is unambiguous.
struct ResumePreviousChip: View {
    let offer: OverlayWindowManager.ResumeOffer
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10, weight: .semibold))
                Text("overlay.resume_chip".localized(offer.durationLabel))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
            // The pill morph animates through widths below ideal; without a
            // fixed size the duration label wraps mid-animation ("+0:0" / "3")
            // and can stay wrapped. The pill's Spacer absorbs pressure instead.
            .fixedSize()
            .foregroundColor(offer.isActive ? .white : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(offer.isActive ? Color.sapoGreen : Color.primary.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .help("overlay.resume_previous".localized)
    }
}

struct PausedPillView: View {
    let duration: TimeInterval
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            FloatingSapoIcon(state: .paused, size: 32)
            PillDivider()

            HStack(spacing: 6) {
                Circle()
                    .fill(Color.processing)
                    .frame(width: 7, height: 7)

                Text("overlay.paused".localized)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
            }

            Spacer(minLength: 20)

            OverlayIconButton(
                systemName: "play.fill",
                label: "overlay.a11y.resume".localized,
                diameter: 26,
                iconSize: 11,
                action: onResume
            )

            OverlayTimer(duration: duration)
        }
        .frame(minWidth: 250)
    }
}

struct TranscribingPillView: View {
    var body: some View {
        HStack(spacing: 10) {
            FloatingSapoIcon(state: .transcribing, size: 32)
            PillDivider()
            TranscribingIndicator()

            Text("overlay.transcribing".localized)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
        }
    }
}

/// Static "Compacto" badge on the recording pill while compact mode is on.
struct CompactModeChip: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 9, weight: .bold))
            Text("overlay.compact_chip".localized)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        // The pill lays out at ideal size inside a fixed surface; without a
        // hard horizontal size the chip label wraps ("Compac/t") when
        // siblings compete for width.
        .fixedSize()
        .foregroundColor(.compactMode)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.compactMode.opacity(0.16)))
    }
}

struct AIPolishingPillView: View {
    let timeoutSeconds: UInt64
    var compact: Bool = false

    @State private var startedAt = Date()

    var body: some View {
        HStack(spacing: 10) {
            FloatingSapoIcon(state: .polishing, size: 32)
            PillDivider()
            TranscribingIndicator(color: compact ? .compactMode : .aiPolish)

            Text((compact ? "overlay.ai_compacting" : "overlay.ai_polishing").localized)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)

            // L10: countdown to the polish timeout — the user sees the worst
            // case shrinking instead of an open-ended spinner.
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let elapsed = Int(context.date.timeIntervalSince(startedAt))
                let remaining = max(0, Int(timeoutSeconds) - elapsed)
                Text("\(remaining)s")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(Constants.Animation.tick, value: remaining)
            }
        }
        .onAppear { startedAt = Date() }
    }
}

/// Compact post-dictation toast: the text already landed at the caret, so
/// this only confirms the copy with the success icon pop + glow and then
/// collapses into the dock chip, which reopens the full transcript on demand.
struct CopiedPillView: View {
    var outcome: CopiedOutcome = .standard

    @State private var iconScale: CGFloat = 0
    @State private var glowFlash = 0

    /// Text/glyph tint: the contrast-safe green variant, not the fill green.
    private var accent: Color {
        outcome == .aiSkipped ? .sapoError : .sapoGreenText
    }

    /// The decorative outline flash keeps the brand fill green.
    private var glowColor: Color {
        outcome == .aiSkipped ? .sapoError : .sapoGreen
    }

    private var icon: String {
        outcome == .aiSkipped ? "exclamationmark.triangle.fill" : "doc.on.clipboard.fill"
    }

    private var label: String {
        (outcome == .aiSkipped ? "overlay.copied_raw" : "overlay.copied").localized
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(accent)
                .scaleEffect(iconScale)

            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(accent)

            if case .compacted(let percentReduced) = outcome, percentReduced > 0 {
                Text("−\(percentReduced)%")
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(.compactMode)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.compactMode.opacity(0.16)))
            }
        }
        .keyframeAnimator(initialValue: 0.0, trigger: glowFlash) { [glowColor] content, glow in
            content.overlay(glowStroke(color: glowColor, intensity: glow))
        } keyframes: { _ in
            PillGlowFlashKeyframes()
        }
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.5).delay(0.1)) {
                iconScale = 1.0
            }
            glowFlash += 1
        }
    }
}

struct CompletedPillView: View {
    let text: String
    var onRepolish: (() -> Void)?
    var onOpenHistory: (() -> Void)?
    var onClose: (() -> Void)?

    @State private var iconScale: CGFloat = 0
    @State private var glowFlash = 0
    @State private var showRecopied = false
    @AppStorage(Constants.StorageKeys.aiPolishEnabled) private var aiPolishEnabled = false

    private static let contentWidth: CGFloat = 400
    private static let transcriptFontSize: CGFloat = 12
    private static let transcriptLineSpacing: CGFloat = 3.5
    /// Measured text taller than this (~10 lines) scrolls in a fixed viewport;
    /// anything shorter hugs its real height so the pill never shows a mostly
    /// empty scroll area.
    private static let scrollThresholdHeight: CGFloat = 178
    private static let scrollViewportHeight: CGFloat = 184

    /// Real Core Text measurement at the pill's wrap width. The layout never
    /// trusts this number for sizing — the concrete-width frame plus
    /// `fixedSize(vertical:)` below re-measure inside SwiftUI — it only picks
    /// hugging vs scroll and slims single-line pills. The old estimate
    /// (characters per line) routinely undersized multi-line text, and under
    /// the overlay's ideal-size layout a `maxWidth` frame reports one line of
    /// height, so the transcript overflowed past the pill background and the
    /// fixed window edge (clipped chips and dock chip).
    private static func measuredTextSize(_ text: String) -> CGSize {
        // Single-entry cache: the body re-evaluates repeatedly for the same
        // transcript (hover, recopy, glow), and each Core Text pass is
        // comparatively expensive.
        if let lastMeasurement, lastMeasurement.text == text {
            return lastMeasurement.size
        }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = transcriptLineSpacing
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: transcriptFontSize),
                .paragraphStyle: paragraphStyle,
            ]
        )
        let bounds = attributed.boundingRect(
            with: CGSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let size = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
        lastMeasurement = (text, size)
        return size
    }

    private static var lastMeasurement: (text: String, size: CGSize)?

    /// Concrete wrap width: measured single lines keep the pill slim (plus a
    /// small cushion against Core Text/SwiftUI rounding differences), longer
    /// text uses the full column.
    private static func transcriptWidth(for measuredSize: CGSize) -> CGFloat {
        min(measuredSize.width + 2, contentWidth)
    }

    private var transcriptText: some View {
        Text(text)
            .font(.system(size: Self.transcriptFontSize))
            .lineSpacing(Self.transcriptLineSpacing)
            .foregroundColor(.primary.opacity(0.9))
            .textSelection(.enabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.sapoGreenText)
                    .scaleEffect(iconScale)

                Text((showRecopied ? "overlay.copied_again" : "overlay.copied").localized)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.sapoGreenText)

                Spacer(minLength: 16)

                // Toggling the language here re-polishes the shown text into
                // the new target without re-pasting.
                if aiPolishEnabled, !text.isEmpty {
                    OverlayTranslationChip(onTranslationToggled: { _ in onRepolish?() })
                }

                if onOpenHistory != nil {
                    OverlayIconButton(
                        systemName: "clock.arrow.circlepath",
                        label: "overlay.open_history".localized,
                        help: "overlay.open_history".localized,
                        action: { onOpenHistory?() }
                    )
                }

                OverlayIconButton(
                    systemName: "doc.on.doc",
                    label: "overlay.copy".localized,
                    help: "overlay.copy".localized,
                    action: {
                        PasteManager.copyToClipboard(text)
                        showRecopied = true
                    }
                )

                OverlayIconButton(
                    systemName: "xmark",
                    label: "overlay.close".localized,
                    help: "overlay.close".localized,
                    action: { onClose?() }
                )
            }

            if !text.isEmpty {
                // The hosting pill lays out at its ideal size, so a ScrollView
                // would grow to the full transcript height. Short texts hug
                // their measured content; only genuinely long ones get a
                // fixed, scrollable viewport — a fixed height on a 3-line
                // text reads as a giant empty pill.
                let measuredSize = Self.measuredTextSize(text)
                if measuredSize.height <= Self.scrollThresholdHeight {
                    transcriptText
                        .frame(width: Self.transcriptWidth(for: measuredSize), alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        transcriptText
                            .frame(width: Self.contentWidth, alignment: .leading)
                            .padding(.bottom, 6)
                    }
                    .frame(width: Self.contentWidth, height: Self.scrollViewportHeight)
                }
            }

        }
        .frame(maxWidth: Self.contentWidth)
        .keyframeAnimator(initialValue: 0.0, trigger: glowFlash) { [accent = Color.sapoGreen] content, glow in
            content.overlay(glowStroke(color: accent, intensity: glow))
        } keyframes: { _ in
            PillGlowFlashKeyframes()
        }
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.5).delay(0.1)) {
                iconScale = 1.0
            }
            glowFlash += 1
        }
    }
}

/// Slim always-visible bar at the anchor position — the overlay's permanent
/// resting fixture the droplet pill detaches from. Hover only highlights it
/// as an affordance; a click toggles the last transcription open/closed, so a
/// stray mouse pass at the screen edge does nothing.
struct DockedChipView: View {
    /// True while a droplet pill floats detached above the chip.
    var isExpanded: Bool = false
    /// Overlay glass namespace; nil (previews) renders glass without an ID.
    var glassNamespace: Namespace.ID? = nil
    var onTap: () -> Void

    @State private var isHovering = false
    @State private var splashTrigger = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onTap) {
            Capsule()
                .fill(Color.sapoGreen.opacity(isExpanded ? 0.9 : (isHovering ? 0.95 : 0.65)))
                .frame(width: 24, height: 4)
                .frame(width: 34, height: 8)
                // Same ~46×12 footprint the chip had when it shared the pill's
                // background, now self-contained.
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlayChipChrome(glassNamespace: glassNamespace)
                // Squash-and-stretch splash as the droplet detaches from or falls
                // back into the chip — sells the "drop separating" read on both
                // directions. Phase-driven so rapid open/close toggles can never
                // strand the chip stretched.
                .phaseAnimator([1.0, 1.75], trigger: splashTrigger) { content, stretch in
                    content.scaleEffect(x: 1, y: stretch)
                } animation: { stretch in
                    stretch > 1 ? Constants.Animation.microBounce : .spring(duration: 0.3, bounce: 0.45)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onChange(of: isExpanded) { _, _ in
            guard !reduceMotion else { return }
            splashTrigger += 1
        }
        .accessibilityLabel("overlay.dock_last".localized)
        .help("overlay.dock_last".localized)
    }
}

struct CancelledPillView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(.secondary)

            Text("overlay.cancelled_saved".localized)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
        }
    }
}

struct ErrorPillView: View {
    let message: String
    var onRetry: (() -> Void)?

    @State private var glowFlash = 0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundColor(.sapoError)

            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                // A concrete width (maxWidth cannot wrap under the pill's
                // ideal-size layout) so long failure messages break into
                // lines instead of widening the pill past the screen.
                .frame(width: message.count > 50 ? 340 : nil, alignment: .leading)

            Spacer()

            if let onRetry {
                Button(action: onRetry) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("overlay.retry".localized)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
        }
        // Same one-shot outline flash as the completed pill, in error amber.
        .keyframeAnimator(initialValue: 0.0, trigger: glowFlash) { [accent = Color.sapoError] content, glow in
            content.overlay(glowStroke(color: accent, intensity: glow))
        } keyframes: { _ in
            PillGlowFlashKeyframes()
        }
        .onAppear {
            glowFlash += 1
        }
    }
}

/// Phase-aware device HUD: a Bluetooth device appears with its real glyph
/// (AirPods get AirPods), pulses while the route settles, then morphs in place
/// to a green "ready" check — or to an amber fallback notice when the
/// preferred mic vanished. The pill view is stable across phase changes
/// (same overlay state category), so the phase swap animates inside it.
struct DeviceChangePillView: View {
    let announcement: DeviceChangeAnnouncement

    @State private var badgeScale: CGFloat = 0
    @State private var iconPulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accentColor: Color {
        switch announcement.phase {
        // Glyph tint over material, so the contrast-safe green variant.
        case .connecting: return .aiPolish
        case .ready: return .sapoGreenText
        case .fallback: return .sapoError
        }
    }

    private var subtitle: String {
        switch announcement.phase {
        case .connecting: return "overlay.device_connecting".localized
        case .ready: return "overlay.device_ready".localized
        case .fallback: return "overlay.device_fallback".localized
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: announcement.symbolName)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(accentColor)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28)
                .opacity(iconPulsing ? 0.35 : 1.0)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 2) {
                Text(announcement.deviceName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(announcement.phase == .fallback ? accentColor : .secondary)
                    .lineLimit(2)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 12)

            phaseBadge
        }
        .frame(minWidth: 230)
        .onAppear { applyPhaseAnimation() }
        .onChange(of: announcement.phase) { _, _ in
            badgeScale = 0
            applyPhaseAnimation()
        }
    }

    @ViewBuilder
    private var phaseBadge: some View {
        switch announcement.phase {
        case .connecting:
            TranscribingIndicator(color: accentColor)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17))
                .foregroundColor(accentColor)
                .scaleEffect(badgeScale)
        case .fallback:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundColor(accentColor)
                .scaleEffect(badgeScale)
        }
    }

    private func applyPhaseAnimation() {
        switch announcement.phase {
        case .connecting:
            // Reduce Motion keeps the glyph steady instead of pulsing.
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                iconPulsing = true
            }
        case .ready, .fallback:
            withAnimation(.easeOut(duration: 0.2)) {
                iconPulsing = false
            }
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.55).delay(0.1)) {
                badgeScale = 1.0
            }
        }
    }
}

struct PillDivider: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 16)
    }
}

/// `intensity` is the 0...1 keyframe value; full flash keeps the old 0.4 peak.
/// Negative padding pushes the stroke back out over the pill chrome that the
/// hosting view applies around this content.
nonisolated private func glowStroke(color: Color, intensity: Double) -> some View {
    OverlayPillChrome.pillShape
        .strokeBorder(color.opacity(0.4 * intensity), lineWidth: 1.5)
        .padding(.horizontal, -OverlayPillChrome.horizontalPadding)
        .padding(.vertical, -OverlayPillChrome.verticalPadding)
}

/// One-shot pill outline flash timeline: short delay, ~0.3 s flash in, hold,
/// ~0.8 s fade out. One shared timeline replaces the old pair of delayed
/// withAnimation calls, which competed over one flag and could leave a stale
/// glow when the pill changed under them. Call sites keep `keyframeAnimator`
/// inline: hoisting it into a generic View extension makes the @Sendable
/// content closure capture `Self.Type`, which strict concurrency rejects.
private struct PillGlowFlashKeyframes: Keyframes {
    var body: some Keyframes<Double> {
        KeyframeTrack {
            LinearKeyframe(0.0, duration: 0.15)
            CubicKeyframe(1.0, duration: 0.3)
            LinearKeyframe(1.0, duration: 0.75)
            CubicKeyframe(0.0, duration: 0.8)
        }
    }
}

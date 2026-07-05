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

            if compactModeActive {
                CompactModeChip()
            }

            Spacer(minLength: 12)

            if let resumeOffer {
                ResumePreviousChip(offer: resumeOffer, onTap: { onResumeToggle?() })
            }

            OverlayTranslationChip(onTranslationToggled: onTranslationToggled)

            Button(action: onPause) {
                Image(systemName: "pause.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)

            OverlayTimer(duration: duration)
        }
        .frame(minWidth: 250)
        // No local animation for the connecting swap: the manager's spring
        // transaction drives it (same pattern as `showsNoSpeechHint`).
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

            Button(action: onResume) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)

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
        }
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

    private var accent: Color {
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
        .keyframeAnimator(initialValue: 0.0, trigger: glowFlash) { content, glow in
            content.overlay(glowStroke(color: accent, intensity: glow))
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(0.0, duration: 0.15)
                CubicKeyframe(1.0, duration: 0.3)
                LinearKeyframe(1.0, duration: 0.75)
                CubicKeyframe(0.0, duration: 0.8)
            }
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
                    .foregroundColor(.sapoGreen)
                    .scaleEffect(iconScale)

                Text((showRecopied ? "overlay.copied_again" : "overlay.copied").localized)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.sapoGreen)

                Spacer(minLength: 16)

                // Toggling the language here re-polishes the shown text into
                // the new target without re-pasting.
                if aiPolishEnabled, !text.isEmpty {
                    OverlayTranslationChip(onTranslationToggled: { _ in onRepolish?() })
                }

                if onOpenHistory != nil {
                    Button {
                        onOpenHistory?()
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.primary.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .help("overlay.open_history".localized)
                }

                Button {
                    PasteManager.copyToClipboard(text)
                    showRecopied = true
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("overlay.copy".localized)

                Button {
                    onClose?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("overlay.close".localized)
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
        // One-shot success outline: short delay, ~0.3 s flash in, hold,
        // ~0.8 s fade out. Keyframes replace the old pair of delayed
        // withAnimation calls, which competed over one flag and could leave
        // a stale glow when the pill changed under them.
        .keyframeAnimator(initialValue: 0.0, trigger: glowFlash) { content, glow in
            content.overlay(glowStroke(color: .sapoGreen, intensity: glow))
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(0.0, duration: 0.15)
                CubicKeyframe(1.0, duration: 0.3)
                LinearKeyframe(1.0, duration: 0.75)
                CubicKeyframe(0.0, duration: 0.8)
            }
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
    var onTap: () -> Void

    @State private var isHovering = false
    @State private var splashTrigger = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(Color.sapoGreen.opacity(isExpanded ? 0.9 : (isHovering ? 0.95 : 0.65)))
            .frame(width: 24, height: 4)
            .frame(width: 34, height: 8)
            // Same ~46×12 footprint the chip had when it shared the pill's
            // background, now self-contained.
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 3)
            )
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
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
            .onTapGesture(perform: onTap)
            .onChange(of: isExpanded) { _, _ in
                guard !reduceMotion else { return }
                splashTrigger += 1
            }
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
        .keyframeAnimator(initialValue: 0.0, trigger: glowFlash) { content, glow in
            content.overlay(glowStroke(color: .sapoError, intensity: glow))
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(0.0, duration: 0.15)
                CubicKeyframe(1.0, duration: 0.3)
                LinearKeyframe(1.0, duration: 0.75)
                CubicKeyframe(0.0, duration: 0.8)
            }
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
        case .connecting: return .aiPolish
        case .ready: return .sapoGreen
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
private func glowStroke(color: Color, intensity: Double) -> some View {
    RoundedRectangle(cornerRadius: 26, style: .continuous)
        .strokeBorder(color.opacity(0.4 * intensity), lineWidth: 1.5)
        .padding(.horizontal, -20)
        .padding(.vertical, -12)
}

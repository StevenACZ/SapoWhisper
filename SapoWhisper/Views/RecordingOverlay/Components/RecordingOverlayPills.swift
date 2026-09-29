//
//  RecordingOverlayPills.swift
//  SapoWhisper
//

import SwiftUI

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

/// "Hold Esc" — swapped in for the status text while the armed cancel
/// warning is live; the pill heartbeat carries the urgency.
struct CancelWarningHint: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "escape")
                .font(.system(size: 11, weight: .semibold))
            Text("overlay.cancel_hint".localized)
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundColor(.red)
        // Mid-morph widths below ideal wrap the hint; the pill's Spacer
        // absorbs pressure instead (same rule as the resume chip).
        .fixedSize()
    }
}

/// Hold-to-cancel sweep behind the pill content. The leading edge is
/// feathered, so the red reads as liquid filling the pill rather than a
/// block sliding across it; it moves by offset, a cheap transform.
struct CancelHoldFill: View {
    let progress: CGFloat

    private static let feather: CGFloat = 40

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width + Self.feather
            LinearGradient(
                stops: [
                    .init(color: .red.opacity(0.1), location: 0),
                    .init(color: .red.opacity(0.32), location: 1 - Self.feather / width),
                    .init(color: .red.opacity(0), location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: width)
            .offset(x: -width * (1 - progress))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

/// Compact post-dictation toast: the text already landed at the caret, so
/// this only confirms the copy with the success icon pop + glow and then
/// sinks away.
struct CopiedPillView: View {
    var outcome: CopiedOutcome = .standard

    @State private var iconScale: CGFloat = 0

    /// Text/glyph tint: the contrast-safe green variant, not the fill green.
    private var accent: Color {
        outcome == .aiSkipped ? .sapoError : .sapoGreenText
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
                .font(.system(size: 15, weight: .semibold))
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
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.5).delay(0.1)) {
                iconScale = 1.0
            }
        }

    }
}

/// One-shot outline flash that confirms a finished pill (copied, cancelled).
struct PillGlowFlash: View {
    let color: Color
    @State private var glowFlash = 0

    var body: some View {
        Color.clear
            .keyframeAnimator(initialValue: 0.0, trigger: glowFlash) {
                [color] content, glow in
                content.overlay(glowStroke(color: color, intensity: glow, expandsToChrome: false))
            } keyframes: { _ in
                PillGlowFlashKeyframes()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                if let delay = glowFlashDelay() {
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
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
    @AppStorage(Constants.StorageKeys.aiPolishEnabled, store: AppPreferences.defaults) private var aiPolishEnabled = false

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
            .foregroundStyle(.primary)
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
        .keyframeAnimator(initialValue: 0.0, trigger: glowFlash) {
            [accent = Color.sapoGreen] content, glow in
            content.overlay(glowStroke(color: accent, intensity: glow))
        } keyframes: { _ in
            PillGlowFlashKeyframes()
        }
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.5).delay(0.1)) {
                iconScale = 1.0
            }
        }
        .task {
            if let delay = glowFlashDelay() {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            glowFlash += 1
        }
    }
}

/// The cancel lands with the same icon pop as the copied toast: the ✕ spins
/// in from a quarter turn so the confirmation reads as a decisive snap.
struct CancelledPillView: View {
    var message: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var landed = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.red)
                .scaleEffect(landed ? 1 : 0.2)
                .rotationEffect(.degrees(landed ? 0 : -90))
                .opacity(landed ? 1 : 0)

            Text(message ?? "overlay.cancelled_saved".localized)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.5).delay(0.08)) {
                landed = true
            }
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
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
        }
        // Same one-shot outline flash as the completed pill, in error amber.
        .keyframeAnimator(initialValue: 0.0, trigger: glowFlash) {
            [accent = Color.sapoError] content, glow in
            content.overlay(glowStroke(color: accent, intensity: glow))
        } keyframes: { _ in
            PillGlowFlashKeyframes()
        }
        .task {
            if let delay = glowFlashDelay() {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
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
                    .foregroundStyle(.primary)
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

/// A pill that just popped in is still scaling: an outline flashed mid-entrance
/// floats visibly inside the real pill edge, so those flashes wait for the
/// entrance spring to settle first.
@MainActor
private func glowFlashDelay() -> Duration? {
    OverlayWindowManager.shared.lastPresentationLeftDock ? .milliseconds(400) : nil
}

/// `intensity` is the 0...1 keyframe value; full flash keeps the old 0.4 peak.
/// Negative padding pushes the stroke back out over the pill chrome that the
/// hosting view applies around this content.
nonisolated private func glowStroke(
    color: Color, intensity: Double, expandsToChrome: Bool = true
) -> some View {
    OverlayPillChrome.pillShape
        .strokeBorder(color.opacity(0.4 * intensity), lineWidth: 1.5)
        .padding(.horizontal, expandsToChrome ? -OverlayPillChrome.horizontalPadding : 0)
        .padding(.vertical, expandsToChrome ? -OverlayPillChrome.verticalPadding : 0)
}

/// One-shot pill outline flash timeline: short delay, quick flash in, brief
/// hold, fade out; about half a second, since every frame re-renders the pill. One shared timeline replaces the old pair of delayed
/// withAnimation calls, which competed over one flag and could leave a stale
/// glow when the pill changed under them. Call sites keep `keyframeAnimator`
/// inline: hoisting it into a generic View extension makes the @Sendable
/// content closure capture `Self.Type`, which strict concurrency rejects.
private struct PillGlowFlashKeyframes: Keyframes {
    var body: some Keyframes<Double> {
        KeyframeTrack {
            LinearKeyframe(0.0, duration: 0.04)
            CubicKeyframe(1.0, duration: 0.12)
            LinearKeyframe(1.0, duration: 0.14)
            CubicKeyframe(0.0, duration: 0.24)
        }
    }
}

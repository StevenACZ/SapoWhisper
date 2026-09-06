//
//  OverlayPillChrome.swift
//  SapoWhisper
//

import SwiftUI

/// Shared chrome geometry for the overlay droplet pill: the background shape,
/// the content padding, and the glow flash overlay must stay in lockstep or
/// the glow outline drifts off the pill edge.
nonisolated enum OverlayPillChrome {
    static let cornerRadius: CGFloat = 26
    static let horizontalPadding: CGFloat = 20
    static let verticalPadding: CGFloat = 12
    static let chipCornerRadius: CGFloat = 6

    /// Continuous rounded rect instead of a capsule: multi-line states
    /// (chips, expanded transcript) made the capsule's semicircular ends
    /// huge, reading as wasted width.
    static var pillShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    static var chipShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: chipCornerRadius, style: .continuous)
    }

    /// Which vertical side of the pill faces the dock chip.
    @MainActor static var chipOnTop: Bool {
        OverlayPosition.configured == .top
    }
}

private struct OverlaySurface<Surface: Shape>: ViewModifier {
    let shape: Surface
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        content
            .foregroundStyle(
                dark ? Color.white : Color.black,
                Color(white: dark ? 0.84 : 0.22)
            )
            .background(shape.fill(Color(white: dark ? 0.12 : 0.97)))
    }
}

extension View {
    func overlayPillChrome() -> some View {
        modifier(OverlaySurface(shape: OverlayPillChrome.pillShape))
    }

    func overlayChipChrome() -> some View {
        modifier(OverlaySurface(shape: OverlayPillChrome.chipShape))
    }
}

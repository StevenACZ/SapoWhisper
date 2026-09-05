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

    /// Which vertical side of the pill faces the dock chip (and its glass
    /// neck) for the configured overlay position.
    @MainActor static var chipOnTop: Bool {
        OverlayPosition.configured == .top
    }
}

/// Stable glass identities inside the overlay's shared namespace so the
/// droplet pill and the dock chip visually fuse on detach/absorb (macOS 26).
enum OverlayGlassID {
    static let droplet = "droplet"
    static let chip = "chip"
}

private struct OverlayLegibilitySurface<Surface: Shape>: ViewModifier {
    let shape: Surface
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        content
            .foregroundStyle(
                dark ? Color.white : Color.black,
                Color(white: dark ? 0.84 : 0.22)
            )
            .background(
                shape.fill(
                    Color(white: dark ? 0.12 : 0.97).opacity(
                        reduceTransparency || contrast == .increased ? 1 : 0.88
                    ))
            )
    }
}

extension View {
    /// Droplet pill chrome: Liquid Glass on macOS 26, the original material
    /// card everywhere else.
    @ViewBuilder
    func overlayPillChrome(glassNamespace: Namespace.ID) -> some View {
        if #available(macOS 26, *) {
            self
                .modifier(OverlayLegibilitySurface(shape: OverlayPillChrome.pillShape))
                .glassEffect(.regular, in: OverlayPillChrome.pillShape)
                .glassEffectID(OverlayGlassID.droplet, in: glassNamespace)
        } else {
            self.modifier(OverlayLegibilitySurface(shape: OverlayPillChrome.pillShape)).background(
                OverlayPillChrome.pillShape
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
            )
        }
    }

    /// Dock chip chrome, same split. `glassNamespace` is optional so previews
    /// can render the chip without a namespace owner (no morph, glass only).
    @ViewBuilder
    func overlayChipChrome(glassNamespace: Namespace.ID?) -> some View {
        if #available(macOS 26, *) {
            if let glassNamespace {
                self
                    .modifier(OverlayLegibilitySurface(shape: OverlayPillChrome.chipShape))
                    .glassEffect(.regular, in: OverlayPillChrome.chipShape)
                    .glassEffectID(OverlayGlassID.chip, in: glassNamespace)
            } else {
                self.modifier(OverlayLegibilitySurface(shape: OverlayPillChrome.chipShape))
                    .glassEffect(.regular, in: OverlayPillChrome.chipShape)
            }
        } else {
            self.modifier(OverlayLegibilitySurface(shape: OverlayPillChrome.chipShape)).background(
                OverlayPillChrome.chipShape
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 3)
            )
        }
    }
}

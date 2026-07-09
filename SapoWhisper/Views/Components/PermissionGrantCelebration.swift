//
//  PermissionGrantCelebration.swift
//  SapoWhisper
//
//  One-shot green flash + pop fired when a permission flips to granted, so
//  the user gets an unmistakable "this one is done" signal.
//

import SwiftUI

struct PermissionGrantCelebration: ViewModifier {
    let trigger: Int
    var cornerRadius: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .phaseAnimator([false, true], trigger: trigger) { view, flashing in
                view
                    // Reduce Motion keeps the color flash, drops the scale pop.
                    .scaleEffect(flashing && !reduceMotion ? 1.02 : 1.0)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.green.opacity(flashing ? 0.85 : 0), lineWidth: 2.5)
                            .blur(radius: 1.5)
                            .allowsHitTesting(false)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.green.opacity(flashing ? 0.10 : 0))
                            .allowsHitTesting(false)
                    )
            } animation: { flashing in
                flashing ? .spring(duration: 0.25) : .easeOut(duration: 0.55)
            }
    }
}

extension View {
    /// Flashes a celebratory green glow each time `trigger` increments.
    func permissionGrantCelebration(trigger: Int, cornerRadius: CGFloat) -> some View {
        modifier(PermissionGrantCelebration(trigger: trigger, cornerRadius: cornerRadius))
    }
}

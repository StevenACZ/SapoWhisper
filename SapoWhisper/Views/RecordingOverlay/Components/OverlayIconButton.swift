//
//  OverlayIconButton.swift
//  SapoWhisper
//

import SwiftUI

/// Icon-only circular button used across the overlay pills. `label` names the
/// control for VoiceOver (the glyph alone is not accessible); `help` adds the
/// hover tooltip where the original button had one.
struct OverlayIconButton: View {
    let systemName: String
    let label: String
    var help: String? = nil
    var diameter: CGFloat = 22
    var iconSize: CGFloat = 10
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundColor(.primary)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Color.primary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)

        if let help {
            button.help(help)
        } else {
            button
        }
    }
}

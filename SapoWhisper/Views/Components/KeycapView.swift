//
//  KeycapView.swift
//  SapoWhisper
//

import SwiftUI

/// Physical-looking keycap shared by the welcome tour and hotkey settings.
struct KeycapView: View {
    let label: String
    var width: CGFloat = 52

    var body: some View {
        Text(label)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .frame(width: width, height: 46)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(color: .black.opacity(0.28), radius: 0, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            )
    }
}

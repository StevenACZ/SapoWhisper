//
//  SettingsSectionHeader.swift
//  SapoWhisper
//

import SwiftUI

/// Shared title + subtitle header for settings sections and disclosure labels.
struct SettingsSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

//
//  SettingsTextEditor.swift
//  SapoWhisper
//

import SwiftUI

/// TextEditor with the shared settings look: padded, rounded corners, and a
/// subtle background + stroke matching the rest of the settings inputs.
struct SettingsTextEditor: View {
    @Binding var text: String
    let minHeight: CGFloat

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12))
            .lineSpacing(4)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18))
            )
    }
}

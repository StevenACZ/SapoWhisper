//
//  SettingsTextEditor.swift
//  SapoWhisper
//

import SwiftUI

/// TextEditor with the shared settings look: padded, rounded corners, and a
/// subtle background + stroke matching the rest of the settings inputs; the
/// stroke tints green while the editor has focus.
struct SettingsTextEditor: View {
    @Binding var text: String
    let minHeight: CGFloat

    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12))
            .lineSpacing(4)
            .scrollContentBackground(.hidden)
            .focused($isFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(isFocused ? 0.09 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isFocused ? Color.sapoGreen.opacity(0.45) : Color.secondary.opacity(0.18))
            )
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

//
//  MenuBarTranscriptionSection.swift
//  SapoWhisper
//
//  Shows the latest transcription inside the menu bar popover.
//

import SwiftUI

struct MenuBarTranscriptionSection: View {
    let transcription: String
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "text.quote")
                    .foregroundColor(.secondary)
                    .font(.caption)

                Text("menu.last_transcription".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("menu.copy_clipboard".localized)
            }

            Text(transcription)
                .font(.callout)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(Constants.Sizes.smallCornerRadius)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

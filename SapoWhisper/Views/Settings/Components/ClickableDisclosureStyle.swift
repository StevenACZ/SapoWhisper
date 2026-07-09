//
//  ClickableDisclosureStyle.swift
//  SapoWhisper
//

import SwiftUI

/// Disclosure style where the whole header row toggles the group — clicking
/// the title or the subtitle works, not just the chevron.
struct ClickableDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Constants.Animation.reveal) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))

                    configuration.label

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if configuration.isExpanded {
                configuration.content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

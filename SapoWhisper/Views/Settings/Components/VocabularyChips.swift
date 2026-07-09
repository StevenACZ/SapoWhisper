//
//  VocabularyChips.swift
//  SapoWhisper
//

import AppKit
import SwiftUI

/// Chip for a saved keyterm. The delete button only appears on hover so a
/// large vocabulary reads as a clean grid instead of a wall of ✕ buttons.
struct VocabularyTermRow: View {
    let term: String
    /// Appearances in recent transcripts; hidden when nil or zero.
    var usageCount: Int?
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            VocabularyMonospacedText(text: term)

            if let usageCount, usageCount > 0 {
                VocabularyUsageBadge(count: usageCount)
            }

            Spacer(minLength: 0)

            VocabularyDeleteButton(isVisible: isHovering, action: onDelete)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(chipBackground(isHovering: isHovering))
        .onHover { isHovering = $0 }
        .animation(Constants.Animation.hover, value: isHovering)
    }
}

/// Row for a saved auto-correction pair (original → replacement).
struct VocabularyReplacementRow: View {
    let original: String
    let replacement: String
    var isAISuggested = false
    /// Appearances of the replacement value in recent transcripts.
    var usageCount: Int?
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            VocabularyMonospacedText(text: original, foregroundColor: .secondary)

            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundColor(.secondary)

            VocabularyMonospacedText(text: replacement)

            if isAISuggested {
                VocabularyAIBadge()
            }

            if let usageCount, usageCount > 0 {
                VocabularyUsageBadge(count: usageCount)
            }

            Spacer(minLength: 0)

            VocabularyDeleteButton(isVisible: isHovering, action: onDelete)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(chipBackground(isHovering: isHovering))
        .onHover { isHovering = $0 }
        .animation(Constants.Animation.hover, value: isHovering)
    }
}

/// Subtle "×12" badge with how often a term shows up in recent transcripts.
private struct VocabularyUsageBadge: View {
    let count: Int

    var body: some View {
        Text("×\(count)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .help("vocab.metrics.top_help".localized)
    }
}

private struct VocabularyAIBadge: View {
    var body: some View {
        Text("vocab.learning.saved_badge".localized)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.sapoGreenText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.sapoGreen.opacity(0.12))
            )
            .help("vocab.learning.saved_badge_help".localized)
    }
}

/// Delete button that stays in the layout (no reflow) but only shows on hover
/// or while keyboard focus sits on it (Full Keyboard Access / VoiceOver).
private struct VocabularyDeleteButton: View {
    let isVisible: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .opacity(isVisible || isFocused ? 1 : 0)
        .accessibilityLabel("config.delete_term_accessibility".localized)
    }
}

private func chipBackground(isHovering: Bool) -> some View {
    RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(isHovering ? Color.primary.opacity(0.07) : Color(NSColor.windowBackgroundColor))
}

/// Monospaced single-line text that shows a tooltip only when truncated.
struct VocabularyMonospacedText: View {
    let text: String
    var foregroundColor: Color = .primary

    @State private var availableWidth: CGFloat = 0

    private static let measurementFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private var isTruncated: Bool {
        guard availableWidth > 0 else { return false }
        let intrinsicWidth = (text as NSString).size(withAttributes: [
            .font: Self.measurementFont
        ]).width
        return intrinsicWidth > availableWidth + 0.5
    }

    var body: some View {
        let label = Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(foregroundColor)
            .lineLimit(1)
            .truncationMode(.middle)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { availableWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newValue in
                            availableWidth = newValue
                        }
                }
            )

        if isTruncated {
            label.help(text)
        } else {
            label
        }
    }
}

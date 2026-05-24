//
//  EngineButton.swift
//  SapoWhisper
//
//

import AppKit
import SwiftUI

/// Selectable engine row with optional inline settings for the active engine.
struct EngineOptionRow<Details: View>: View {
    let engine: TranscriptionEngine
    let isSelected: Bool
    let isLoading: Bool
    let loadingProgress: Double
    let loadingMessage: String
    let hasDetails: Bool
    @Binding var isExpanded: Bool
    let action: () -> Void
    let details: () -> Details
    @State private var isSettingsHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                HStack(spacing: 12) {
                    icon

                    VStack(alignment: .leading, spacing: 2) {
                        titleRow

                        Text(engine.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    selectionIndicator
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            if isSelected && hasDetails {
                inlineSettings
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(isSelected ? Color.sapoGreen.opacity(0.1) : Color(NSColor.windowBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.sapoGreen.opacity(0.5) : Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private var icon: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.sapoGreen.opacity(0.2) : Color(NSColor.controlBackgroundColor))
                .frame(width: 36, height: 36)

            Image(systemName: engine.icon)
                .font(.system(size: 15))
                .foregroundColor(isSelected ? .sapoGreen : .secondary)
        }
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Text(engine.displayName)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)

            if engine.isRecommended {
                Text("badge.recommended".localized)
                    .font(.caption2)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.sapoGreen)
                    .cornerRadius(4)
            }

            if isLoading, !loadingMessage.isEmpty {
                Text(loadingMessage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var selectionIndicator: some View {
        if isLoading {
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 22, height: 22)
        } else if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.sapoGreen)
                .font(.system(size: 20))
        } else {
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1.5)
                .frame(width: 20, height: 20)
        }
    }

    private var inlineSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
                .padding(.leading, 48)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                settingsDisclosureLabel
            }
            .buttonStyle(.plain)
            .background(isSettingsHovering ? Color.primary.opacity(0.05) : Color.clear)
            .cornerRadius(7)
            .onHover { hovering in
                isSettingsHovering = hovering
            }
            .pointingHandCursor()

            if isExpanded {
                details()
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var settingsDisclosureLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 12)

            Image(systemName: "slider.horizontal.3")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("config.tab_settings".localized)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    @State private var didPushCursor = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, !didPushCursor {
                    NSCursor.pointingHand.push()
                    didPushCursor = true
                } else if !hovering, didPushCursor {
                    NSCursor.pop()
                    didPushCursor = false
                }
            }
            .onDisappear {
                if didPushCursor {
                    NSCursor.pop()
                    didPushCursor = false
                }
            }
    }
}

extension View {
    fileprivate func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

#Preview("Engine Buttons") {
    VStack(spacing: 8) {
        EngineOptionRow(
            engine: .appleOnline,
            isSelected: true,
            isLoading: false,
            loadingProgress: 0,
            loadingMessage: "",
            hasDetails: false,
            isExpanded: .constant(true)
        ) {
        } details: {
            EmptyView()
        }

        EngineOptionRow(
            engine: .whisperLocal,
            isSelected: false,
            isLoading: false,
            loadingProgress: 0,
            loadingMessage: "",
            hasDetails: true,
            isExpanded: .constant(true)
        ) {
        } details: {
            Text("Whisper settings")
                .font(.caption)
        }

        EngineOptionRow(
            engine: .googleCloud,
            isSelected: false,
            isLoading: true,
            loadingProgress: 0.6,
            loadingMessage: "Loading...",
            hasDetails: true,
            isExpanded: .constant(true)
        ) {
        } details: {
            Text("Google settings")
                .font(.caption)
        }

        EngineOptionRow(
            engine: .deepgram,
            isSelected: true,
            isLoading: false,
            loadingProgress: 0,
            loadingMessage: "",
            hasDetails: true,
            isExpanded: .constant(false)
        ) {
        } details: {
            Text("Deepgram settings")
                .font(.caption)
        }
    }
    .padding()
    .frame(width: 520)
}

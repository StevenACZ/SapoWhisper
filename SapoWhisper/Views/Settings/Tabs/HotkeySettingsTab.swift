//
//  HotkeySettingsTab.swift
//  SapoWhisper
//
//

import Carbon
import SwiftUI

/// Global hotkey settings tab.
struct HotkeySettingsTab: View {
    @AppStorage(Constants.StorageKeys.hotkeyTriggerKind) private var hotkeyTriggerKindRaw: String =
        Constants.Hotkey.defaultTriggerKind
    @AppStorage(Constants.StorageKeys.hotkeyKeyCode) private var hotkeyKeyCode: Int = Int(Constants.Hotkey.defaultKeyCode)
    @AppStorage(Constants.StorageKeys.hotkeyModifiers) private var hotkeyModifiers: Int = Int(Constants.Hotkey.defaultModifiers)
    @AppStorage(Constants.StorageKeys.hotkeyDoubleTapModifier) private var hotkeyDoubleTapModifier: Int = Int(
        Constants.Hotkey.defaultDoubleTapModifier
    )

    @State private var isRecordingHotkey = false
    @State private var keycapPressBounce = 0
    @State private var conflictShake = 0
    @State private var doubleTapFeedbackPhase = 0
    @State private var doubleTapFeedbackResetTask: Task<Void, Never>?
    private let presetColumns = [
        GridItem(.adaptive(minimum: 104), spacing: 10, alignment: .leading)
    ]

    private var triggerKind: HotkeyTriggerKind {
        HotkeyTriggerKind(rawValue: hotkeyTriggerKindRaw) ?? .keyCombination
    }

    private var triggerKindBinding: Binding<HotkeyTriggerKind> {
        Binding(
            get: { triggerKind },
            set: { updateTriggerKind($0) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hotkeyCard
                presetsCard
                permissionsCard
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
    }

    // MARK: - Hotkey Card

    private var hotkeyCard: some View {
        SettingsCard(icon: "keyboard", title: "settings.hotkeys".localized) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("settings.hotkey_activation_mode".localized, selection: triggerKindBinding) {
                    Text("settings.hotkey_mode_combination".localized)
                        .tag(HotkeyTriggerKind.keyCombination)
                    Text("settings.hotkey_mode_double_modifier".localized)
                        .tag(HotkeyTriggerKind.doubleModifier)
                }
                .pickerStyle(.segmented)

                Text(
                    triggerKind == .keyCombination
                        ? "settings.hotkey_mode_combination_caption".localized
                        : "settings.hotkey_mode_double_caption".localized
                )
                .font(.caption)
                .foregroundColor(.secondary)

                if triggerKind == .keyCombination {
                    combinationSection
                } else {
                    doubleTapSection
                }
            }
            .animation(.smooth(duration: 0.25), value: triggerKind)
        }
    }

    // MARK: - Key combination

    private var combinationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            currentComboKeycaps
                .frame(maxWidth: .infinity)
                .modifier(ShakeEffect(trigger: conflictShake))

            HotkeyRecorderView(
                keyCode: $hotkeyKeyCode,
                modifiers: $hotkeyModifiers,
                isRecording: $isRecordingHotkey,
                onHotkeyChanged: { keyCode, modifiers in
                    updateHotkey(keyCode: keyCode, modifiers: modifiers)
                }
            )
            .frame(height: 36)
            .overlay(recorderGlow)

            Text("config.hotkey_instruction".localized)
                .font(.caption)
                .foregroundColor(.secondary)

            if let conflict = systemConflictName(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers) {
                Label("settings.hotkey_conflict".localized(conflict), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }
        }
    }

    /// The active combo drawn as physical keycaps; they press once whenever a
    /// new combo is recorded or picked.
    private var currentComboKeycaps: some View {
        HStack(spacing: 8) {
            ForEach(
                HotkeyKeyName.keycapLabels(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers),
                id: \.self
            ) { label in
                KeycapView(label: label, width: label.count > 1 ? 88 : 48)
            }
        }
        .phaseAnimator([false, true], trigger: keycapPressBounce) { content, pressed in
            content.scaleEffect(pressed ? 0.93 : 1.0)
        } animation: { pressed in
            pressed ? .spring(duration: 0.16) : .easeOut(duration: 0.3)
        }
    }

    @ViewBuilder
    private var recorderGlow: some View {
        if isRecordingHotkey {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.sapoGreen, lineWidth: 2)
                .blur(radius: 2.5)
                .phaseAnimator([0.35, 0.85]) { content, opacity in
                    content.opacity(opacity)
                } animation: { _ in
                    .easeInOut(duration: 0.7)
                }
                .allowsHitTesting(false)
        }
    }

    private func systemConflictName(keyCode: Int, modifiers: Int) -> String? {
        guard keyCode == kVK_Space else { return nil }
        switch modifiers {
        case cmdKey:
            return "settings.hotkey_conflict_spotlight".localized
        case controlKey, controlKey | optionKey:
            return "settings.hotkey_conflict_input_source".localized
        case controlKey | cmdKey:
            return "settings.hotkey_conflict_character_viewer".localized
        default:
            return nil
        }
    }

    // MARK: - Double tap

    private var doubleTapSection: some View {
        HStack(alignment: .center, spacing: 16) {
            DoubleTapKeycapDemo(symbol: currentDoubleTapModifier.symbol)

            VStack(alignment: .leading, spacing: 6) {
                Text("settings.hotkey_double_modifier_desc".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)

                doubleTapLiveFeedback
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    /// Dots that light up as the user actually tries the gesture: first valid
    /// tap fills one dot, the accepted double tap fills both.
    private var doubleTapLiveFeedback: some View {
        HStack(spacing: 6) {
            doubleTapDot(filled: doubleTapFeedbackPhase >= 1)
            doubleTapDot(filled: doubleTapFeedbackPhase >= 2)
            Text(
                doubleTapFeedbackPhase >= 2
                    ? "settings.hotkey_double_tap_success".localized
                    : "settings.hotkey_double_tap_try".localized
            )
            .font(.caption)
            .foregroundStyle(doubleTapFeedbackPhase >= 2 ? Color.sapoGreen : .secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: HotkeyManager.doubleTapFirstTapNotification)) { _ in
            registerDoubleTapFeedback(phase: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: HotkeyManager.doubleTapTriggeredNotification)) { _ in
            registerDoubleTapFeedback(phase: 2)
        }
    }

    private func doubleTapDot(filled: Bool) -> some View {
        Circle()
            .fill(filled ? Color.sapoGreen : Color.secondary.opacity(0.25))
            .frame(width: 9, height: 9)
            .scaleEffect(filled ? 1.0 : 0.85)
    }

    private func registerDoubleTapFeedback(phase: Int) {
        withAnimation(.spring(duration: 0.25)) {
            doubleTapFeedbackPhase = phase
        }
        doubleTapFeedbackResetTask?.cancel()
        doubleTapFeedbackResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.3)) {
                doubleTapFeedbackPhase = 0
            }
        }
    }

    // MARK: - Presets Card

    private var presetsCard: some View {
        SettingsCard(icon: "sparkles", title: "settings.presets".localized) {
            VStack(alignment: .leading, spacing: 12) {
                Text("settings.presets_desc".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("settings.hotkey_presets_combinations".localized)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    LazyVGrid(columns: presetColumns, alignment: .leading, spacing: 10) {
                        HotkeyPresetButton("⌥ Space", isSelected: isHotkeySelected(keyCode: kVK_Space, modifiers: optionKey)) {
                            updateHotkey(keyCode: kVK_Space, modifiers: optionKey)
                        }

                        HotkeyPresetButton("⌘ Space", isSelected: isHotkeySelected(keyCode: kVK_Space, modifiers: cmdKey)) {
                            updateHotkey(keyCode: kVK_Space, modifiers: cmdKey)
                        }

                        HotkeyPresetButton("⌘⇧ Space", isSelected: isHotkeySelected(keyCode: kVK_Space, modifiers: cmdKey | shiftKey)) {
                            updateHotkey(keyCode: kVK_Space, modifiers: cmdKey | shiftKey)
                        }

                        HotkeyPresetButton(
                            "⌃⌥ Space",
                            isSelected: isHotkeySelected(keyCode: kVK_Space, modifiers: controlKey | optionKey)
                        ) {
                            updateHotkey(keyCode: kVK_Space, modifiers: controlKey | optionKey)
                        }

                        HotkeyPresetButton(
                            "⌃⌥⌘ Space",
                            isSelected: isHotkeySelected(keyCode: kVK_Space, modifiers: controlKey | optionKey | cmdKey)
                        ) {
                            updateHotkey(keyCode: kVK_Space, modifiers: controlKey | optionKey | cmdKey)
                        }
                    }

                    Divider()

                    Text("settings.hotkey_presets_double_tap".localized)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    LazyVGrid(columns: presetColumns, alignment: .leading, spacing: 10) {
                        ForEach(HotkeyDoubleTapModifier.allCases) { modifier in
                            HotkeyPresetButton(doubleTapLabel(for: modifier), isSelected: isDoubleTapSelected(modifier)) {
                                updateDoubleTapModifier(modifier)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Permissions Card

    private var permissionsCard: some View {
        SettingsCard(icon: "hand.raised", title: "settings.permissions".localized) {
            VStack(alignment: .leading, spacing: 12) {
                Text("settings.permissions_guided_desc".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)

                PermissionStatusRow(permission: .accessibility)

                Button("permissions.review".localized) {
                    PermissionRequirementsWindowController.shared.showWindow(force: true)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Helpers

    private func isHotkeySelected(keyCode: Int, modifiers: Int) -> Bool {
        triggerKind == .keyCombination && hotkeyKeyCode == keyCode && hotkeyModifiers == modifiers
    }

    private func isDoubleTapSelected(_ modifier: HotkeyDoubleTapModifier) -> Bool {
        triggerKind == .doubleModifier && hotkeyDoubleTapModifier == Int(modifier.carbonValue)
    }

    private var currentDoubleTapModifier: HotkeyDoubleTapModifier {
        HotkeyDoubleTapModifier.option(for: UInt32(hotkeyDoubleTapModifier))
    }

    private func doubleTapLabel(for modifier: HotkeyDoubleTapModifier) -> String {
        "\(modifier.symbol)\(modifier.symbol)"
    }

    private func updateTriggerKind(_ triggerKind: HotkeyTriggerKind) {
        hotkeyTriggerKindRaw = triggerKind.rawValue
        HotkeyManager.shared.updateTriggerKind(triggerKind)
    }

    private func updateHotkey(keyCode: Int, modifiers: Int) {
        hotkeyTriggerKindRaw = HotkeyTriggerKind.keyCombination.rawValue
        hotkeyKeyCode = keyCode
        hotkeyModifiers = modifiers
        HotkeyManager.shared.updateHotkey(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))

        keycapPressBounce += 1
        if systemConflictName(keyCode: keyCode, modifiers: modifiers) != nil {
            withAnimation(.spring(duration: 0.4)) {
                conflictShake += 1
            }
        }
    }

    private func updateDoubleTapModifier(_ modifier: HotkeyDoubleTapModifier) {
        hotkeyTriggerKindRaw = HotkeyTriggerKind.doubleModifier.rawValue
        hotkeyDoubleTapModifier = Int(modifier.carbonValue)
        HotkeyManager.shared.updateDoubleTapModifier(modifier.carbonValue)
    }
}

// MARK: - Double-tap demo

/// The chosen modifier keycap pressing itself twice in a loop, illustrating
/// the gesture without words.
private struct DoubleTapKeycapDemo: View {
    let symbol: String

    var body: some View {
        KeycapView(label: symbol, width: 56)
            .phaseAnimator([0, 1, 2, 3]) { content, phase in
                content.scaleEffect(phase == 1 || phase == 3 ? 0.92 : 1.0)
            } animation: { phase in
                switch phase {
                case 1, 3:
                    return .spring(duration: 0.14)
                case 2:
                    return .easeOut(duration: 0.16)
                default:
                    return .easeOut(duration: 1.5)
                }
            }
    }
}

// MARK: - Hotkey Preset Button

struct HotkeyPresetButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    init(_ label: String, isSelected: Bool, action: @escaping () -> Void) {
        self.label = label
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Color.sapoGreen : Color(NSColor.controlBackgroundColor))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

#Preview("Hotkey Settings") {
    HotkeySettingsTab()
        .frame(width: 480, height: 500)
}

#Preview("Hotkey Presets") {
    HStack(spacing: 10) {
        HotkeyPresetButton("⌥ Space", isSelected: true) {}
        HotkeyPresetButton("⌘⇧ Space", isSelected: false) {}
        HotkeyPresetButton("⌥⌥", isSelected: false) {}
    }
    .padding()
}

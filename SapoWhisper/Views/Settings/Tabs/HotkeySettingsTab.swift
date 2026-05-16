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

                if triggerKind == .keyCombination {
                    HotkeyRecorderView(
                        keyCode: $hotkeyKeyCode,
                        modifiers: $hotkeyModifiers,
                        isRecording: $isRecordingHotkey,
                        onHotkeyChanged: { keyCode, modifiers in
                            updateHotkey(keyCode: keyCode, modifiers: modifiers)
                        }
                    )
                    .frame(height: 36)

                    Text("config.hotkey_instruction".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    doubleTapCurrentSelection
                }
            }
        }
    }

    private var doubleTapCurrentSelection: some View {
        HStack(spacing: 10) {
            Text(doubleTapLabel(for: currentDoubleTapModifier))
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
                .frame(width: 68, height: 36)
                .background(Color.sapoGreen)
                .foregroundColor(.white)
                .cornerRadius(6)

            Text("settings.hotkey_double_modifier_desc".localized)
                .font(.caption)
                .foregroundColor(.secondary)
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
    }

    private func updateDoubleTapModifier(_ modifier: HotkeyDoubleTapModifier) {
        hotkeyTriggerKindRaw = HotkeyTriggerKind.doubleModifier.rawValue
        hotkeyDoubleTapModifier = Int(modifier.carbonValue)
        HotkeyManager.shared.updateDoubleTapModifier(modifier.carbonValue)
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

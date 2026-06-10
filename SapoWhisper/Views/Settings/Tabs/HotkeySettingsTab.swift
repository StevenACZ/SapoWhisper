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
    @Namespace private var doubleTapSelection

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
        // GeometryReader (not containerRelativeFrame — resolves to 0 inside
        // the always-alive settings tabs) so short content centers vertically
        // while taller content still scrolls.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    hotkeyCard
                    AccessibilityPermissionFooter()
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(16)
                .frame(minHeight: proxy.size.height)
            }
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

    /// All four modifiers as clickable keycaps: the active one plays the
    /// double-press animation so there is no doubt about which key is live.
    private var doubleTapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(HotkeyDoubleTapModifier.allCases) { modifier in
                    DoubleTapModifierOption(
                        modifier: modifier,
                        isSelected: currentDoubleTapModifier == modifier,
                        namespace: doubleTapSelection
                    ) {
                        updateDoubleTapModifier(modifier)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.spring(duration: 0.35), value: hotkeyDoubleTapModifier)

            HStack(spacing: 10) {
                Text("settings.hotkey_double_pick_hint".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer(minLength: 0)

                doubleTapLiveFeedback
            }
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

    // MARK: - Helpers

    private var currentDoubleTapModifier: HotkeyDoubleTapModifier {
        HotkeyDoubleTapModifier.option(for: UInt32(hotkeyDoubleTapModifier))
    }

    private func updateTriggerKind(_ triggerKind: HotkeyTriggerKind) {
        hotkeyTriggerKindRaw = triggerKind.rawValue
        HotkeyManager.shared.updateTriggerKind(triggerKind)
        requestInputMonitoringIfNeeded(for: triggerKind)
    }

    /// The double-tap trigger listens through a tap that needs Input
    /// Monitoring. Kick off the guided permission flow right when the user
    /// picks it, instead of leaving a silently dead hotkey.
    private func requestInputMonitoringIfNeeded(for triggerKind: HotkeyTriggerKind) {
        guard triggerKind == .doubleModifier, !AppPermission.inputMonitoring.isGranted() else { return }
        PermissionService.shared.requestInteractively(.inputMonitoring)
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
        requestInputMonitoringIfNeeded(for: .doubleModifier)
    }
}

// MARK: - Double-tap modifier option

/// One selectable modifier keycap. The selected one keeps pressing itself
/// twice in a loop — the gesture demo doubles as the "this key is active"
/// signal; the rest sit dimmed until hovered.
private struct DoubleTapModifierOption: View {
    let modifier: HotkeyDoubleTapModifier
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Group {
                    if isSelected {
                        DoubleTapKeycapDemo(symbol: modifier.symbol)
                    } else {
                        KeycapView(label: modifier.symbol, width: 56)
                            .opacity(isHovered ? 0.9 : 0.55)
                    }
                }
                .frame(height: 48)

                Text(displayName)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.sapoGreen : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.sapoGreen.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.sapoGreen.opacity(0.35), lineWidth: 1)
                        )
                        .matchedGeometryEffect(id: "double-tap-active", in: namespace)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered && !isSelected ? 1.04 : 1.0)
        .animation(.smooth(duration: 0.18), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var displayName: String {
        switch modifier {
        case .option: return "settings.hotkey_modifier_option".localized
        case .command: return "settings.hotkey_modifier_command".localized
        case .control: return "settings.hotkey_modifier_control".localized
        case .shift: return "settings.hotkey_modifier_shift".localized
        }
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

// MARK: - Accessibility footer

/// Once accessibility is granted this collapses into a slim confirmation row;
/// the full guidance card only shows while the permission is missing.
private struct AccessibilityPermissionFooter: View {
    @State private var isGranted = PermissionService.shared.isGranted(.accessibility)

    var body: some View {
        Group {
            if isGranted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.sapoGreen)
                    Text("settings.permissions_accessibility_active".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Button("permissions.review".localized) {
                        PermissionRequirementsWindowController.shared.showWindow(force: true)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.sapoGreen)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
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
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        let granted = PermissionService.shared.isGranted(.accessibility)
        guard granted != isGranted else { return }
        withAnimation(.smooth(duration: 0.3)) {
            isGranted = granted
        }
    }
}

#Preview("Hotkey Settings") {
    HotkeySettingsTab()
        .frame(width: 480, height: 500)
}

//
//  HotkeyManager.swift
//  SapoWhisper
//
//

import Carbon
import Cocoa
import Combine
import OSLog
import os

enum HotkeyTriggerKind: String, CaseIterable, Identifiable {
    case keyCombination
    case doubleModifier

    var id: String { rawValue }
}

enum HotkeyDoubleTapModifier: Int, CaseIterable, Identifiable {
    case option = 2048
    case command = 256
    case control = 4096
    case shift = 512

    var id: Int { rawValue }
    var carbonValue: UInt32 { UInt32(rawValue) }

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .shift: return "⇧"
        case .option: return "⌥"
        case .control: return "⌃"
        }
    }

    var cgFlag: CGEventFlags {
        switch self {
        case .command: return .maskCommand
        case .shift: return .maskShift
        case .option: return .maskAlternate
        case .control: return .maskControl
        }
    }

    var keyCodes: Set<Int64> {
        switch self {
        case .command:
            return [Int64(kVK_Command), Int64(kVK_RightCommand)]
        case .shift:
            return [Int64(kVK_Shift), Int64(kVK_RightShift)]
        case .option:
            return [Int64(kVK_Option), Int64(kVK_RightOption)]
        case .control:
            return [Int64(kVK_Control), Int64(kVK_RightControl)]
        }
    }

    static func option(for carbonValue: UInt32) -> HotkeyDoubleTapModifier {
        HotkeyDoubleTapModifier(rawValue: Int(carbonValue)) ?? .option
    }
}

/// Maneja los hotkeys globales de la aplicación
class HotkeyManager: ObservableObject {

    static let shared = HotkeyManager()

    /// Live double-tap feedback for the Hotkey settings tab: a valid first tap
    /// landed, or the second tap triggered the hotkey.
    static let doubleTapFirstTapNotification = Notification.Name("HotkeyManager.doubleTapFirstTap")
    static let doubleTapTriggeredNotification = Notification.Name("HotkeyManager.doubleTapTriggered")

    private var eventHandler: EventHandlerRef?
    private var hotkeyRef: EventHotKeyRef?
    private var cancelHotkeyRef: EventHotKeyRef?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var hotkeyCallback: (() -> Void)?
    private var cancelCallback: (() -> Void)?
    private var accessibilityRetryTimer: Timer?
    private static let hotkeySignature = OSType(0x5357_5049)  // "SWPI"
    private static let mainHotkeyID: UInt32 = 1
    private static let cancelHotkeyID: UInt32 = 2
    private var watchdogTimer: Timer?
    private static let watchdogInterval: TimeInterval = 600
    private var hotkeyPressCount: UInt64 = 0
    private var isDoubleTapModifierPressed = false
    private var isSuppressingCurrentDoubleTapPress = false
    private var currentDoubleTapPressStartedAt: CFAbsoluteTime?
    private var lastDoubleTapReleaseAt: CFAbsoluteTime?
    private static let doubleTapInterval: CFTimeInterval = 0.45
    private static let doubleTapMaxHoldDuration: CFTimeInterval = 0.40
    private static let relevantModifierFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    // Hotkey por defecto: Option + Space
    @Published var currentTriggerKind: HotkeyTriggerKind
    @Published var currentKeyCode: UInt32
    @Published var currentModifiers: UInt32
    @Published var currentDoubleTapModifier: UInt32

    private init() {
        // Cargar valores guardados o usar defaults
        let savedTriggerKind = UserDefaults.standard.string(forKey: Constants.StorageKeys.hotkeyTriggerKind)
        let savedKeyCode = UserDefaults.standard.integer(forKey: Constants.StorageKeys.hotkeyKeyCode)
        let savedModifiers = UserDefaults.standard.integer(forKey: Constants.StorageKeys.hotkeyModifiers)
        let savedDoubleTapModifier = UserDefaults.standard.integer(forKey: Constants.StorageKeys.hotkeyDoubleTapModifier)

        self.currentTriggerKind =
            HotkeyTriggerKind(rawValue: savedTriggerKind ?? Constants.Hotkey.defaultTriggerKind) ?? .keyCombination
        self.currentKeyCode = savedKeyCode > 0 ? UInt32(savedKeyCode) : UInt32(kVK_Space)
        self.currentModifiers = savedModifiers > 0 ? UInt32(savedModifiers) : UInt32(optionKey)
        self.currentDoubleTapModifier =
            savedDoubleTapModifier > 0 ? UInt32(savedDoubleTapModifier) : UInt32(optionKey)
    }

    /// Registra el hotkey global
    func registerHotkey(callback: @escaping () -> Void) {
        // UI preview and test launches skip the event tap: each ad-hoc
        // rebuild would re-trigger the Accessibility consent prompt.
        guard !UIPreviewMode.skipsConsentPrompts else { return }

        self.hotkeyCallback = callback

        // Desregistrar hotkey anterior si existe
        unregisterHotkey()

        switch currentTriggerKind {
        case .keyCombination:
            registerKeyCombinationHotkey()
        case .doubleModifier:
            registerDoubleModifierHotkey()
        }

        startWatchdogIfNeeded()
    }

    // MARK: - Watchdog (R2)

    /// R2: macOS can silently kill the CGEventTap (wake, login, Secure Input
    /// churn) and the app would look fine with a dead hotkey. Re-validate on
    /// wake and on a cheap periodic tick; re-create when the tap is gone.
    func assertHotkeyAlive(reason: String) {
        guard let callback = hotkeyCallback else { return }

        switch currentTriggerKind {
        case .keyCombination:
            if hotkeyRef == nil {
                SapoLog.hotkey.warning(
                    "Hotkey check reason=\(reason, privacy: .public) result=missing-registration action=re-register"
                )
                registerHotkey(callback: callback)
            } else {
                SapoLog.hotkey.info("Hotkey check reason=\(reason, privacy: .public) result=alive")
            }
        case .doubleModifier:
            guard let eventTap else {
                SapoLog.hotkey.warning(
                    "Hotkey check reason=\(reason, privacy: .public) result=missing-tap action=re-register"
                )
                registerHotkey(callback: callback)
                return
            }
            if CGEvent.tapIsEnabled(tap: eventTap) {
                SapoLog.hotkey.info("Hotkey check reason=\(reason, privacy: .public) result=alive")
            } else {
                SapoLog.hotkey.warning(
                    "Hotkey check reason=\(reason, privacy: .public) result=disabled-tap action=re-enable"
                )
                enableEventTap()
                if !CGEvent.tapIsEnabled(tap: eventTap) {
                    SapoLog.hotkey.warning("Hotkey tap stayed disabled; re-creating it")
                    registerHotkey(callback: callback)
                }
            }
        }
    }

    private func startWatchdogIfNeeded() {
        guard watchdogTimer == nil else { return }

        let timer = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            // Scheduled on RunLoop.main, so the timer always fires on main.
            MainActor.assumeIsolated {
                self?.assertHotkeyAlive(reason: "watchdog")
            }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    /// One Carbon handler dispatches every hotkey this app registers (main
    /// trigger and the transient Esc cancel key) by its EventHotKeyID.
    private func installCarbonHandlerIfNeeded() -> Bool {
        guard eventHandler == nil else { return true }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return noErr }
                var hotkeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotkeyID
                )
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                if hotkeyID.id == HotkeyManager.cancelHotkeyID {
                    manager.handleCancelKeyPressed()
                } else {
                    manager.handleHotkeyPressed(source: "key-combination")
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        if status != noErr {
            SapoLog.hotkey.error("Failed to install event handler status=\(status, privacy: .public)")
            return false
        }
        return true
    }

    private func registerKeyCombinationHotkey() {
        guard installCarbonHandlerIfNeeded() else { return }

        let hotkeyID = EventHotKeyID(signature: Self.hotkeySignature, id: Self.mainHotkeyID)

        let registerStatus = RegisterEventHotKey(
            currentKeyCode,
            currentModifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        if registerStatus != noErr {
            SapoLog.hotkey.error("Failed to register hotkey status=\(registerStatus, privacy: .public)")
        } else {
            SapoLog.hotkey.info("Global hotkey registered \(self.hotkeyDescription, privacy: .public)")
        }
    }

    // MARK: - Esc cancel key (active only while dictating)

    /// Registers/unregisters Esc as a global hotkey for the duration of a
    /// dictation session. Registered, the key is consumed system-wide, so it
    /// cancels the recording without reaching the frontmost app.
    func setCancelKeyActive(_ active: Bool, callback: (() -> Void)? = nil) {
        guard !UIPreviewMode.skipsConsentPrompts else { return }

        if let callback {
            cancelCallback = callback
        }

        if active {
            guard cancelHotkeyRef == nil, installCarbonHandlerIfNeeded() else { return }
            let hotkeyID = EventHotKeyID(signature: Self.hotkeySignature, id: Self.cancelHotkeyID)
            let status = RegisterEventHotKey(
                UInt32(kVK_Escape),
                0,
                hotkeyID,
                GetApplicationEventTarget(),
                0,
                &cancelHotkeyRef
            )
            if status != noErr {
                SapoLog.hotkey.error("Failed to register Esc cancel key status=\(status, privacy: .public)")
            }
        } else {
            unregisterCancelKey()
        }
    }

    private func unregisterCancelKey() {
        if let cancelHotkeyRef {
            UnregisterEventHotKey(cancelHotkeyRef)
            self.cancelHotkeyRef = nil
        }
    }

    private func handleCancelKeyPressed() {
        SapoLog.hotkey.info("Esc cancel key pressed")
        cancelCallback?()
    }

    private func registerDoubleModifierHotkey() {
        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: eventMask,
                callback: { _, type, event, userData in
                    guard let userData = userData else {
                        return Unmanaged.passUnretained(event)
                    }

                    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        manager.enableEventTap()
                        return Unmanaged.passUnretained(event)
                    }

                    guard type == .flagsChanged else {
                        return Unmanaged.passUnretained(event)
                    }

                    manager.handleFlagsChanged(event)
                    return Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            SapoLog.hotkey.error("Failed to register double modifier hotkey")
            scheduleAccessibilityRetry()
            return
        }

        eventTap = tap
        eventTapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let eventTapRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
        }
        enableEventTap()
        resetDoubleTapState()
        SapoLog.hotkey.info("Double modifier hotkey registered \(self.hotkeyDescription, privacy: .public)")
    }

    /// On a fresh install the event tap is created before the user grants
    /// Accessibility, so creation fails and the double-tap trigger stays dead
    /// until something re-registers it (changing the hotkey, relaunching).
    /// Poll until the process becomes trusted, then re-register on the spot.
    private func scheduleAccessibilityRetry() {
        guard accessibilityRetryTimer == nil else { return }

        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            // Scheduled on RunLoop.main, so the timer always fires on main.
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.accessibilityRetryTimer?.invalidate()
                self.accessibilityRetryTimer = nil
                SapoLog.hotkey.info("Accessibility granted; re-registering double modifier hotkey")
                if let callback = self.hotkeyCallback {
                    self.registerHotkey(callback: callback)
                }
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        accessibilityRetryTimer = timer
    }

    /// Desregistra el hotkey actual
    func unregisterHotkey() {
        accessibilityRetryTimer?.invalidate()
        accessibilityRetryTimer = nil

        if let hotkeyRef = hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
        }

        // The Esc ref must never outlive the shared Carbon handler: a
        // registered hotkey without a handler would swallow Esc system-wide.
        unregisterCancelKey()

        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }

        if let eventTapRunLoopSource = eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }

        if let eventTap = eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        resetDoubleTapState()
    }

    /// Cambia el hotkey manteniendo el callback existente
    func updateHotkey(keyCode: UInt32, modifiers: UInt32) {
        updateConfiguration(
            triggerKind: .keyCombination,
            keyCode: keyCode,
            modifiers: modifiers,
            doubleTapModifier: currentDoubleTapModifier
        )
    }

    /// Cambia el hotkey con un nuevo callback
    func updateHotkey(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        hotkeyCallback = callback
        updateHotkey(keyCode: keyCode, modifiers: modifiers)
    }

    func updateTriggerKind(_ triggerKind: HotkeyTriggerKind) {
        updateConfiguration(
            triggerKind: triggerKind,
            keyCode: currentKeyCode,
            modifiers: currentModifiers,
            doubleTapModifier: currentDoubleTapModifier
        )
    }

    func updateDoubleTapModifier(_ modifier: UInt32) {
        updateConfiguration(
            triggerKind: .doubleModifier,
            keyCode: currentKeyCode,
            modifiers: currentModifiers,
            doubleTapModifier: modifier
        )
    }

    func updateConfiguration(
        triggerKind: HotkeyTriggerKind,
        keyCode: UInt32,
        modifiers: UInt32,
        doubleTapModifier: UInt32
    ) {
        currentTriggerKind = triggerKind
        currentKeyCode = keyCode
        currentModifiers = modifiers
        currentDoubleTapModifier = HotkeyDoubleTapModifier.option(for: doubleTapModifier).carbonValue

        UserDefaults.standard.set(triggerKind.rawValue, forKey: Constants.StorageKeys.hotkeyTriggerKind)
        UserDefaults.standard.set(Int(keyCode), forKey: Constants.StorageKeys.hotkeyKeyCode)
        UserDefaults.standard.set(Int(modifiers), forKey: Constants.StorageKeys.hotkeyModifiers)
        UserDefaults.standard.set(Int(currentDoubleTapModifier), forKey: Constants.StorageKeys.hotkeyDoubleTapModifier)

        if let callback = hotkeyCallback {
            registerHotkey(callback: callback)
        }
    }

    /// Texto descriptivo del hotkey actual
    var hotkeyDescription: String {
        if currentTriggerKind == .doubleModifier {
            let option = HotkeyDoubleTapModifier.option(for: currentDoubleTapModifier)
            return "\(option.symbol) \(option.symbol)"
        }

        var parts: [String] = []

        if currentModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if currentModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if currentModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if currentModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }

        parts.append(keyName(for: Int(currentKeyCode)))

        return parts.joined(separator: " + ")
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let option = HotkeyDoubleTapModifier.option(for: currentDoubleTapModifier)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard option.keyCodes.contains(keyCode) else { return }

        let modifierFlags = event.flags.intersection(Self.relevantModifierFlags)
        let isTargetOnlyDown = modifierFlags == option.cgFlag
        let isTargetUp = !modifierFlags.contains(option.cgFlag)
        let now = CFAbsoluteTimeGetCurrent()

        if isTargetOnlyDown && !isDoubleTapModifierPressed {
            isDoubleTapModifierPressed = true
            currentDoubleTapPressStartedAt = now

            if let lastDoubleTapReleaseAt, now - lastDoubleTapReleaseAt <= Self.doubleTapInterval {
                isSuppressingCurrentDoubleTapPress = true
                self.lastDoubleTapReleaseAt = nil
                SapoLog.hotkey.info(
                    "Double modifier hotkey accepted modifier=\(option.symbol, privacy: .public)"
                )
                DispatchQueue.main.async { [weak self] in
                    NotificationCenter.default.post(name: Self.doubleTapTriggeredNotification, object: nil)
                    self?.handleHotkeyPressed(source: "double-modifier")
                }
            }
        } else if isTargetUp && isDoubleTapModifierPressed {
            let pressDuration = now - (currentDoubleTapPressStartedAt ?? now)
            isDoubleTapModifierPressed = false
            currentDoubleTapPressStartedAt = nil

            if isSuppressingCurrentDoubleTapPress {
                isSuppressingCurrentDoubleTapPress = false
                lastDoubleTapReleaseAt = nil
            } else {
                lastDoubleTapReleaseAt = pressDuration <= Self.doubleTapMaxHoldDuration ? now : nil
                if lastDoubleTapReleaseAt != nil {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: Self.doubleTapFirstTapNotification, object: nil)
                    }
                }
            }
        } else if modifierFlags != option.cgFlag {
            resetDoubleTapState()
        }
    }

    private func handleHotkeyPressed(source: String) {
        hotkeyPressCount &+= 1
        let pressCount = hotkeyPressCount
        let description = hotkeyDescription
        SapoLog.hotkey.info(
            "Global hotkey pressed source=\(source, privacy: .public) count=\(pressCount, privacy: .public) hotkey=\(description, privacy: .public)"
        )
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: "hotkey-pressed",
            context: "source=\(source) count=\(pressCount) hotkey=\(description)",
            force: true
        )
        hotkeyCallback?()
    }

    private func enableEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    private func resetDoubleTapState() {
        isDoubleTapModifierPressed = false
        isSuppressingCurrentDoubleTapPress = false
        currentDoubleTapPressStartedAt = nil
        lastDoubleTapReleaseAt = nil
    }

    private func keyName(for keyCode: Int) -> String {
        HotkeyKeyName.name(for: keyCode)
    }

}

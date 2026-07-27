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
    private var permissionRetryTimer: Timer?
    private static let hotkeySignature = OSType(0x5357_5049)  // "SWPI"
    private static let mainHotkeyID: UInt32 = 1
    private static let cancelHotkeyID: UInt32 = 2
    private var watchdogTimer: Timer?
    private static let watchdogInterval: TimeInterval = 600
    private var hotkeyPressCount: UInt64 = 0
    private var doubleTapRecognizer = DoubleTapRecognizer()
    private static let relevantModifierFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    // Hotkey por defecto: Option + Space
    @Published var currentTriggerKind: HotkeyTriggerKind
    @Published var currentKeyCode: UInt32
    @Published var currentModifiers: UInt32
    @Published var currentDoubleTapModifier: UInt32

    /// `UInt32(_:)` TRAPS on the negative or oversized `Int` a hand-edited or
    /// truncated settings file can store.
    static func sanitizedKeyCode(_ value: Int, fallback: UInt32) -> UInt32 {
        UInt32(exactly: value) ?? fallback
    }

    /// A modifier mask has no valid zero — the recorder refuses a bare key —
    /// so an empty mask is as unusable as a corrupted one.
    static func sanitizedModifiers(_ value: Int, fallback: UInt32) -> UInt32 {
        value > 0 ? sanitizedKeyCode(value, fallback: fallback) : fallback
    }

    /// Absent means "never configured"; 0 is `kVK_ANSI_A`, a real key the user
    /// can pick, so presence — not the value — decides the default.
    static func storedKeyCode(in defaults: UserDefaults) -> UInt32 {
        guard defaults.object(forKey: Constants.StorageKeys.hotkeyKeyCode) != nil else {
            return Constants.Hotkey.defaultKeyCode
        }
        return sanitizedKeyCode(
            defaults.integer(forKey: Constants.StorageKeys.hotkeyKeyCode),
            fallback: Constants.Hotkey.defaultKeyCode
        )
    }

    private init() {
        // Cargar valores guardados o usar defaults
        let defaults = UserDefaults.standard
        let savedTriggerKind = defaults.string(forKey: Constants.StorageKeys.hotkeyTriggerKind)
        let savedModifiers = defaults.integer(forKey: Constants.StorageKeys.hotkeyModifiers)
        let savedDoubleTapModifier = defaults.integer(forKey: Constants.StorageKeys.hotkeyDoubleTapModifier)

        self.currentTriggerKind =
            HotkeyTriggerKind(rawValue: savedTriggerKind ?? Constants.Hotkey.defaultTriggerKind) ?? .keyCombination
        self.currentKeyCode = Self.storedKeyCode(in: defaults)
        self.currentModifiers = Self.sanitizedModifiers(
            savedModifiers, fallback: Constants.Hotkey.defaultModifiers)
        self.currentDoubleTapModifier = Self.sanitizedModifiers(
            savedDoubleTapModifier, fallback: Constants.Hotkey.defaultDoubleTapModifier)
    }

    /// Registra el hotkey global
    func registerHotkey(callback: @escaping () -> Void) {
        // UI preview and test launches skip the event tap: each ad-hoc
        // rebuild would re-trigger the Accessibility consent prompt.
        guard !UIPreviewMode.skipsConsentPrompts else { return }

        self.hotkeyCallback = callback

        // One-line state snapshot per registration attempt: enough to read a
        // user log and know which trigger ran with which permissions.
        SapoLog.hotkey.info(
            "Hotkey register trigger=\(self.currentTriggerKind.rawValue, privacy: .public) hotkey=\(self.hotkeyDescription, privacy: .public) inputMonitoring=\(CGPreflightListenEventAccess(), privacy: .public) accessibility=\(AXIsProcessTrusted(), privacy: .public)"
        )

        // Desregistrar hotkey anterior si existe
        unregisterHotkey()

        switch currentTriggerKind {
        case .keyCombination:
            registerKeyCombinationHotkey()
        case .doubleModifier:
            registerDoubleModifierHotkey()
        }

        startWatchdogIfNeeded()

        // Re-arm Esc if a dictation is active: unregisterHotkey() above dropped
        // the cancel-key ref together with the shared Carbon handler, and the
        // appState sink that normally arms it is edge-triggered, so it will not
        // re-fire while the state stays .recording.
        if cancelKeyActive {
            registerCancelKey()
        }

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
                // Carbon delivers on the main run loop (GetApplicationEventTarget);
                // make the C→MainActor hop explicit so a Swift 6 language-mode
                // flip gets a check instead of silent UB.
                MainActor.assumeIsolated {
                    if hotkeyID.id == HotkeyManager.cancelHotkeyID {
                        manager.handleCancelKeyPressed()
                    } else {
                        manager.handleHotkeyPressed(source: "key-combination")
                    }
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

        if registerStatus != noErr || hotkeyRef == nil {
            // A bad combo (e.g. from an unvalidated settings import) makes
            // RegisterEventHotKey fail and would leave the user with a dead
            // hotkey. Fall back to the default (Option+Space) and persist it so
            // the bad combo does not reload at launch.
            SapoLog.hotkey.error(
                "Failed to register hotkey status=\(registerStatus, privacy: .public); falling back to default"
            )
            hotkeyRef = nil
            currentKeyCode = UInt32(kVK_Space)
            currentModifiers = UInt32(optionKey)
            UserDefaults.standard.set(Int(currentKeyCode), forKey: Constants.StorageKeys.hotkeyKeyCode)
            UserDefaults.standard.set(Int(currentModifiers), forKey: Constants.StorageKeys.hotkeyModifiers)
            let retryStatus = RegisterEventHotKey(
                currentKeyCode, currentModifiers, hotkeyID, GetApplicationEventTarget(), 0, &hotkeyRef)
            if retryStatus == noErr {
                SapoLog.hotkey.info(
                    "Global hotkey registered with default \(self.hotkeyDescription, privacy: .public)")
            } else {
                SapoLog.hotkey.error(
                    "Default hotkey registration also failed status=\(retryStatus, privacy: .public)")
            }
        } else {
            SapoLog.hotkey.info("Global hotkey registered \(self.hotkeyDescription, privacy: .public)")
        }
    }

    // MARK: - Esc cancel key (active only while dictating)

    /// Whether Esc should currently be armed. Persists across a hotkey
    /// re-registration so the cancel key can be restored mid-session.
    private var cancelKeyActive = false

    /// Registers/unregisters Esc as a global hotkey for the duration of a
    /// dictation session. Registered, the key is consumed system-wide, so it
    /// cancels the recording without reaching the frontmost app.
    func setCancelKeyActive(_ active: Bool, callback: (() -> Void)? = nil) {
        guard !UIPreviewMode.skipsConsentPrompts else { return }

        if let callback {
            cancelCallback = callback
        }

        cancelKeyActive = active
        if active {
            registerCancelKey()
        } else {
            unregisterCancelKey()
        }
    }

    private func registerCancelKey() {
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
        // The listen-only tap below needs Input Monitoring, not Accessibility.
        // Creating it without the permission both fails AND makes macOS throw
        // its own "Keystroke Receiving" dialog at the user mid-launch, so
        // preflight first and let the guided permission flow request access.
        guard CGPreflightListenEventAccess() else {
            SapoLog.hotkey.warning(
                "Double modifier registration blocked permission=input-monitoring granted=false accessibility=\(AXIsProcessTrusted(), privacy: .public) action=wait-for-grant"
            )
            scheduleInputMonitoringRetry()
            return
        }

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
                    // The tap runs on CFRunLoopGetMain; make the C→MainActor
                    // hop explicit (same rationale as the Carbon handler).
                    return MainActor.assumeIsolated {
                        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                            manager.enableEventTap()
                            return Unmanaged.passUnretained(event)
                        }

                        guard type == .flagsChanged else {
                            return Unmanaged.passUnretained(event)
                        }

                        manager.handleFlagsChanged(event)
                        return Unmanaged.passUnretained(event)
                    }
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            // Permission preflight passed but the tap still failed: macOS can
            // require a relaunch right after the grant. Surface that clearly.
            SapoLog.hotkey.error(
                "Double modifier tap creation failed permission=input-monitoring granted=true hint=may-need-relaunch"
            )
            scheduleInputMonitoringRetry()
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

    /// On a fresh install the double-tap trigger stays dead until the user
    /// grants Input Monitoring (the listen-only tap's actual requirement —
    /// Accessibility alone is not enough). Poll until access is granted, then
    /// re-register on the spot so no relaunch or hotkey change is needed.
    private func scheduleInputMonitoringRetry() {
        guard permissionRetryTimer == nil else { return }

        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            // Scheduled on RunLoop.main, so the timer always fires on main.
            MainActor.assumeIsolated {
                guard let self, CGPreflightListenEventAccess() else { return }
                self.permissionRetryTimer?.invalidate()
                self.permissionRetryTimer = nil
                SapoLog.hotkey.info("Input Monitoring granted; re-registering double modifier hotkey")
                if let callback = self.hotkeyCallback {
                    self.registerHotkey(callback: callback)
                }
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        permissionRetryTimer = timer
    }

    /// Desregistra el hotkey actual
    func unregisterHotkey() {
        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil

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

        switch doubleTapRecognizer.handle(
            targetOnlyDown: isTargetOnlyDown,
            targetUp: isTargetUp,
            otherFlagsActive: modifierFlags != option.cgFlag,
            now: now
        ) {
        case .trigger:
            SapoLog.hotkey.info(
                "Double modifier hotkey accepted modifier=\(option.symbol, privacy: .public)"
            )
            DispatchQueue.main.async { [weak self] in
                NotificationCenter.default.post(name: Self.doubleTapTriggeredNotification, object: nil)
                self?.handleHotkeyPressed(source: "double-modifier")
            }
        case .firstTap:
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.doubleTapFirstTapNotification, object: nil)
            }
        case .none:
            break
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
        doubleTapRecognizer.reset()
    }

    private func keyName(for keyCode: Int) -> String {
        HotkeyKeyName.name(for: keyCode)
    }

}

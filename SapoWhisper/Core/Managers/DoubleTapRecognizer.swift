//
//  DoubleTapRecognizer.swift
//  SapoWhisper
//

import Foundation

/// Pure decision core of the double-modifier trigger: two short target-only
/// taps within the window fire the hotkey. No CGEvent, Dispatch, or
/// NotificationCenter — `HotkeyManager` parses the event into the three
/// booleans and reacts to the returned event.
struct DoubleTapRecognizer {

    enum Event: Equatable {
        case none
        /// A valid first tap landed; the second-tap window is open.
        case firstTap
        /// The second tap landed inside the window — fire the hotkey.
        case trigger
    }

    private var isModifierPressed = false
    private var isSuppressingCurrentPress = false
    private var currentPressStartedAt: CFAbsoluteTime?
    private var lastReleaseAt: CFAbsoluteTime?
    private static let doubleTapInterval: CFTimeInterval = 0.45
    private static let doubleTapMaxHoldDuration: CFTimeInterval = 0.40

    mutating func handle(targetOnlyDown: Bool, targetUp: Bool, otherFlagsActive: Bool, now: CFAbsoluteTime) -> Event {
        if targetOnlyDown && !isModifierPressed {
            isModifierPressed = true
            currentPressStartedAt = now

            if let lastReleaseAt, now - lastReleaseAt <= Self.doubleTapInterval {
                isSuppressingCurrentPress = true
                self.lastReleaseAt = nil
                return .trigger
            }
        } else if targetUp && isModifierPressed {
            let pressDuration = now - (currentPressStartedAt ?? now)
            isModifierPressed = false
            currentPressStartedAt = nil

            if isSuppressingCurrentPress {
                // The suppressed (triggering) press's release must not re-arm
                // the window.
                isSuppressingCurrentPress = false
                lastReleaseAt = nil
            } else {
                lastReleaseAt = pressDuration <= Self.doubleTapMaxHoldDuration ? now : nil
                if lastReleaseAt != nil {
                    return .firstTap
                }
            }
        } else if otherFlagsActive {
            reset()
        }
        return .none
    }

    mutating func reset() {
        isModifierPressed = false
        isSuppressingCurrentPress = false
        currentPressStartedAt = nil
        lastReleaseAt = nil
    }
}

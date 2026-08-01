//
//  EscapeCancelGate.swift
//  SapoWhisper
//

import Foundation

/// Two-press Esc cancel: the first press only arms (the pill warns with a
/// heartbeat + hint), a second press within the window confirms. A single
/// stray Esc can no longer kill an active take.
struct EscapeCancelGate {

    enum Outcome: Equatable {
        case armed
        case confirmed
    }

    /// How long the warning stays armed; a press after this arms again.
    static let confirmWindow: TimeInterval = 2.5

    private var armedAt: Date?
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    mutating func registerPress() -> Outcome {
        if let armedAt, now().timeIntervalSince(armedAt) < Self.confirmWindow {
            self.armedAt = nil
            return .confirmed
        }
        armedAt = now()
        return .armed
    }

    /// Session boundaries (start, stop, pause, state change) drop the armed
    /// press so it can never confirm a cancel on a different dictation phase.
    mutating func reset() {
        armedAt = nil
    }
}

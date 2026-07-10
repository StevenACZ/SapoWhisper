//
//  SessionAudioLevelTracker.swift
//  SapoWhisper
//

import Foundation

/// No-speech fast path: tracks the session peak from the overlay level
/// stream and answers the silence questions. The threshold is deliberately
/// conservative (~−55 dBFS in the normalized 0...1 scale) so quiet speakers
/// are never misclassified.
struct SessionAudioLevelTracker {

    private var peakLevel: Float = 0
    private var trackingStartedAt: CFAbsoluteTime = 0
    private static let noSpeechPeakLevelThreshold: Float = 0.085
    private static let noSpeechHintDelay: TimeInterval = 3.0
    /// First real signal (above digital silence) collapses the "connecting"
    /// label; genuinely quiet rooms still read above this because the level
    /// floor maps ambient noise well over zero.
    private static let micConnectedLevelThreshold: Float = 0.02

    var peak: Float { peakLevel }

    var looksSilent: Bool {
        peakLevel < Self.noSpeechPeakLevelThreshold
    }

    /// Session start: forget the previous peak and anchor the hint delay.
    mutating func beginSession(at now: CFAbsoluteTime) {
        peakLevel = 0
        trackingStartedAt = now
    }

    mutating func register(level: Float, now: CFAbsoluteTime) {
        peakLevel = max(peakLevel, level)
    }

    /// Whether this level is the first real signal that should collapse the
    /// "connecting" label.
    func micConnectedCollapse(level: Float) -> Bool {
        level > Self.micConnectedLevelThreshold
    }

    /// Drives the live "no voice?" overlay hint. While the mic is still
    /// handshaking, "no voice?" would be misleading — the connecting label
    /// owns that window.
    func noSpeechHintActive(connectingLabelVisible: Bool, now: CFAbsoluteTime) -> Bool {
        let elapsed = now - trackingStartedAt
        return !connectingLabelVisible && looksSilent && elapsed >= Self.noSpeechHintDelay
    }
}

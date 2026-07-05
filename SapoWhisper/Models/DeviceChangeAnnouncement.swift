//
//  DeviceChangeAnnouncement.swift
//  SapoWhisper
//

import Foundation

/// A device-route event worth showing in the overlay HUD: what changed, over
/// which transport, and where in its lifecycle it is. The HUD morphs through
/// phases (connecting → ready) instead of flashing a single static pill.
nonisolated struct DeviceChangeAnnouncement: Equatable {
    enum Phase: Equatable {
        /// The route changed and the new input is still settling (Bluetooth
        /// handshake, HAL renegotiation).
        case connecting
        /// The input is bound and warmed — dictation will start instantly.
        case ready
        /// The preferred microphone disappeared; capture fell back to this
        /// device so recordings don't go silent.
        case fallback
    }

    let deviceName: String
    let transport: AudioDeviceTransport
    let phase: Phase

    /// SF Symbol matching the device family — AirPods get their real glyph,
    /// generic Bluetooth reads as headphones, USB/built-in as microphones.
    var symbolName: String {
        let lowered = deviceName.lowercased()
        if lowered.contains("airpods pro") { return "airpodspro" }
        if lowered.contains("airpods max") { return "airpodsmax" }
        if lowered.contains("airpods") { return "airpods" }
        switch transport {
        case .bluetooth: return "headphones"
        case .usb: return "mic.fill"
        case .builtIn: return "laptopcomputer"
        case .other: return "mic"
        }
    }
}
